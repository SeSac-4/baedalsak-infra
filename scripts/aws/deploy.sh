#!/usr/bin/env bash
# =============================================================================
# 앱 6개 배포 (namespace = ENV_NAME) — 사용: deploy.sh <이미지 태그>
#   values: 차트 기본값 → services/<서비스>.yaml → aws.yaml → 아래 --set
#   gateway: replica 2 · HPA 2~4(CPU 70%) · PDB · TargetGroupBinding
#   order·payment: 1 (HPA 1~3 은 부하 테스트 시점) / member·store·delivery: 1
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

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# 새 파드가 ALB 에서 healthy 가 된 뒤 이전 파드 종료 (롤링 배포 중 502 방지)
kubectl label namespace "$NS" elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

for svc in member store order payment delivery gateway; do
  extra=()
  case "$svc" in
    gateway)
      extra+=(--set autoscaling.enabled=true --set autoscaling.minReplicas=2 --set autoscaling.maxReplicas=4
              --set autoscaling.targetCPUUtilizationPercentage=70
              --set pdb.enabled=true --set pdb.minAvailable=1
              --set targetGroupBinding.enabled=true --set-string targetGroupBinding.targetGroupARN="$TG_ARN") ;;
    *)
      extra+=(--set autoscaling.enabled=false --set autoscaling.minReplicas=1) ;;
  esac

  echo "== $svc"
  helm upgrade --install "$svc" "$CHART" -n "$NS" \
    -f "$ROOT/helm/values/services/$svc.yaml" \
    -f "$ROOT/helm/values/aws.yaml" \
    --set-string global.imageRegistry="$REGISTRY" \
    --set-string global.imageNamespace="$NAME" \
    --set-string global.awsRegion="$REGION" \
    --set-string global.externalSecret.keyPrefix="$SECRET_PREFIX" \
    --set-string global.rabbitmq.vhost="/$ENV_NAME" \
    --set-string global.db.host="$RDS_HOST" \
    --set-string global.rabbitmq.host="$MQ_HOST" \
    --set-string global.redisSession.host="$REDIS_HOST" \
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
