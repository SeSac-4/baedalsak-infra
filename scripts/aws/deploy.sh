#!/usr/bin/env bash
# =============================================================================
# 앱 6개 배포 (namespace = ENV_NAME) — 사용: deploy.sh <이미지 태그>
#   values: 차트 기본값 → services/<서비스>.yaml → aws.yaml → 아래 --set
#   gateway: replica 2 · HPA 2~4(CPU 70%, 확장은 3분 지속 시) · PDB · TargetGroupBinding
#   order·payment: 1 (HPA 1~3 은 부하 테스트 시점) / member·store·delivery: 1
#   DB 쓰는 5개: Hikari 연결 풀 5 (RDS 연결 수 한도)
# =============================================================================
set -euo pipefail

TAG="${1:?이미지 태그가 필요합니다 (images 워크플로가 출력한 태그)}"
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
REGION="$AWS_REGION"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/helm/charts/baedalsak-service"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
RDS_HOST="$(ssm rds_host)"
MQ_HOST="$(ssm mq_host)"
REDIS_HOST="$(ssm redis_host)"
TG_ARN="$(ssm target_group_arn)"
# 추적 전송 주소 (helm/addons/tempo.yaml) — 앱이 OTel 로 바뀌기 전에는 쓰이지 않음
OTLP_TRACES="http://tempo.monitoring.svc.cluster.local:4318/v1/traces"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# 새 파드가 ALB 에서 healthy 가 된 뒤 이전 파드 종료 (롤링 배포 중 502 방지)
kubectl label namespace "$NS" elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

# 실패 시 rollback.sh 가 되돌릴 리비전 (서비스별 마지막 정상 배포, 처음 설치면 빈 값)
PREV="${TMPDIR:-/tmp}/${NAME}-deploy-prev"
: > "$PREV"
for svc in member store order payment delivery gateway; do
  echo "$svc $(helm history "$svc" -n "$NS" -o json 2>/dev/null | jq -r '[.[] | select(.status=="deployed")][-1].revision // empty')" >> "$PREV"
done

for svc in member store order payment delivery gateway; do
  extra=()
  case "$svc" in
    gateway)
      extra+=(--set autoscaling.enabled=true --set autoscaling.minReplicas=2 --set autoscaling.maxReplicas=4
              --set autoscaling.targetCPUUtilizationPercentage=70
              --set autoscaling.behavior.scaleUp.stabilizationWindowSeconds=180  # JVM 기동 직후 CPU 급증(1~2분)으로 늘리지 않게 — 3분 넘게 높을 때만 확장
              --set pdb.enabled=true --set pdb.minAvailable=1
              --set targetGroupBinding.enabled=true --set-string targetGroupBinding.targetGroupARN="$TG_ARN") ;;
    *)
      # DB 쓰는 5개: 연결 풀 5 (기본 10) — 배포 중 이전·새 파드가 겹쳐도 Σ(파드 × 풀) × 2 = 50 < RDS max_connections(t4g.micro 약 80)
      #   필요량 ≈ 최고 TPS × 쿼리 평균 시간(초) + 여유 = 50 × 0.05 ≈ 3 → 5 (AWS 만 적용, 로컬은 앱 기본값)
      extra+=(--set autoscaling.enabled=false --set autoscaling.minReplicas=1
              --set-string extraEnv.SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=5) ;;
  esac

  echo "== $svc"
  helm upgrade --install "$svc" "$CHART" -n "$NS" \
    -f "$ROOT/helm/values/services/$svc.yaml" \
    -f "$ROOT/helm/values/aws.yaml" \
    --set-string global.imageRegistry="$REGISTRY" \
    --set-string global.imageNamespace="$NAME" \
    --set-string global.awsRegion="$REGION" \
    --set-string global.externalSecret.keyPrefix="$SECRET_PREFIX" \
    --set-string global.externalSecret.ssmStore=aws-parameter-store \
    --set-string global.externalSecret.ssmPrefix="$SSM_PREFIX" \
    --set-string global.rabbitmq.vhost="/$ENV_NAME" \
    --set-string global.db.host="$RDS_HOST" \
    --set-string global.rabbitmq.host="$MQ_HOST" \
    --set-string global.redisSession.host="$REDIS_HOST" \
    --set-string extraEnv.MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT="$OTLP_TRACES" \
    --set-string image.tag="$TAG" \
    "${extra[@]}"
done

# ESO 가 Secret 을 만들 때까지 대기 후 롤아웃 확인
for svc in member store order payment delivery gateway; do
  kubectl -n "$NS" wait --for=condition=Ready "externalsecret/$svc" --timeout=3m || true
done
for svc in member store order payment delivery gateway; do
  kubectl -n "$NS" rollout status "deploy/$svc" --timeout=10m
done
kubectl -n "$NS" get pods -o wide
