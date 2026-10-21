#!/usr/bin/env bash
# =============================================================================
# 데이터 초기화 (멱등) — 앱 배포 전에 실행
#   1) RDS: 서비스별 DB · schema · 계정 5개 (테이블은 각 서비스 Flyway)
#   2) Amazon MQ: vhost /<ENV_NAME> + 권한
# 클러스터 안의 Job 으로 실행 (RDS·MQ 는 private)
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
REGION="$AWS_REGION"

RDS_HOST="$(ssm rds_host)"
MQ_HOST="$(ssm mq_host)"
SECRET_JSON="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "${SECRET_PREFIX}/infra" --query SecretString --output text)"
j() { echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['$1'])"; }

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic data-init \
  --from-literal=PGHOST="$RDS_HOST" \
  --from-literal=PGUSER="$(j DB_MASTER_USER)" \
  --from-literal=PGPASSWORD="$(j DB_MASTER_PASSWORD)" \
  --from-literal=PW_MEMBER="$(j DB_PASSWORD_MEMBER)" \
  --from-literal=PW_STORE="$(j DB_PASSWORD_STORE)" \
  --from-literal=PW_ORDER="$(j DB_PASSWORD_ORDER)" \
  --from-literal=PW_PAYMENT="$(j DB_PASSWORD_PAYMENT)" \
  --from-literal=PW_DELIVERY="$(j DB_PASSWORD_DELIVERY)" \
  --from-literal=MQ_HOST="$MQ_HOST" \
  --from-literal=MQ_USER="$(j MQ_USER)" \
  --from-literal=MQ_PASSWORD="$(j MQ_PASSWORD)" \
  --from-literal=MQ_VHOST="$ENV_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" delete job db-init mq-init --ignore-not-found

# DB 이름 = schema 이름 (helm/values/services/*.yaml): member store orders payment delivery
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
spec:
  backoffLimit: 6
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: psql
          image: postgres:16
          envFrom:
            - secretRef: { name: data-init }
          env:
            - { name: PGDATABASE, value: postgres }
            - { name: PGSSLMODE, value: require }
          command: ["/bin/bash", "-ec"]
          args:
            - |
              until pg_isready -h "$PGHOST" -t 5; do echo "waiting RDS"; sleep 5; done
              mk() {  # $1=db/schema  $2=user  $3=password
                psql -v ON_ERROR_STOP=1 -v db="$1" -v usr="$2" -v pw="$3" <<'SQL'
              SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'usr', :'pw')
                WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'usr') \gexec
              SELECT format('ALTER ROLE %I PASSWORD %L', :'usr', :'pw') \gexec
              SELECT format('GRANT %I TO CURRENT_USER', :'usr') \gexec
              SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'usr')
                WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
              SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
              SQL
                psql -v ON_ERROR_STOP=1 -d "$1" -v sch="$1" -v usr="$2" <<'SQL'
              SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'sch', :'usr') \gexec
              SQL
                echo "ok: $1 / $2"
              }
              mk member   member_svc   "$PW_MEMBER"
              mk store    store_svc    "$PW_STORE"
              mk orders   order_svc    "$PW_ORDER"
              mk payment  payment_svc  "$PW_PAYMENT"
              mk delivery delivery_svc "$PW_DELIVERY"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: mq-init
spec:
  backoffLimit: 6
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: curl
          image: curlimages/curl:8.11.1
          envFrom:
            - secretRef: { name: data-init }
          command: ["/bin/sh", "-ec"]
          args:
            - |
              API="https://${MQ_HOST}/api"
              curl -fsS -u "$MQ_USER:$MQ_PASSWORD" -X PUT "$API/vhosts/%2F${MQ_VHOST}" -H 'content-type: application/json' -d '{}'
              curl -fsS -u "$MQ_USER:$MQ_PASSWORD" -X PUT "$API/permissions/%2F${MQ_VHOST}/$MQ_USER" \
                -H 'content-type: application/json' -d '{"configure":".*","write":".*","read":".*"}'
              echo "ok: vhost /${MQ_VHOST}"
EOF

kubectl -n "$NS" wait --for=condition=complete job/db-init --timeout=10m
kubectl -n "$NS" wait --for=condition=complete job/mq-init --timeout=5m
kubectl -n "$NS" logs job/db-init
kubectl -n "$NS" logs job/mq-init
