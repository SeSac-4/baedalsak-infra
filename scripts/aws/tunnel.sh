#!/usr/bin/env bash
# =============================================================================
# 팀원 PC → AWS 개발 환경 터널 (Bastion 을 거친 SSM 포트포워딩, 열린 인바운드 포트 없음)
#   사용: tunnel.sh <대상> [로컬 포트]
#     api   → internal ALB:80     (기본 localhost:8080 — gateway, 예: curl localhost:8080/v1/stores)
#     db    → RDS:5432            (기본 localhost:15432 — 계정·비밀번호는 Secrets Manager <SECRET_PREFIX>/<서비스>)
#     redis → ElastiCache:6379    (기본 localhost:16379 — TLS + AUTH)
#     mq    → Amazon MQ 콘솔:443  (기본 localhost:15671 — 브라우저 https://localhost:15671, 인증서 경고는 정상)
#   Ctrl+C 로 종료. 환경이 꺼져 있으면(평일 19:00~09:00) 대상이 없어서 실패
# 필요: aws cli + Session Manager plugin, 본인 IAM 자격 증명 (aws configure)
#   plugin 설치: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
# =============================================================================
set -euo pipefail

# 로컬은 .env 없이도 기본값으로 동작 (값이 다르면 환경변수로 덮어씀)
export AWS_REGION="${AWS_REGION:-ap-northeast-2}" PROJECT="${PROJECT:-baedalsak}" ENV_NAME="${ENV_NAME:-prod}"
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"

case "${1:-}" in
  api)   HOST="$(ssm alb_dns)";    PORT=80;   LOCAL="${2:-8080}" ;;
  db)    HOST="$(ssm rds_host)";   PORT=5432; LOCAL="${2:-15432}" ;;
  redis) HOST="$(ssm redis_host)"; PORT=6379; LOCAL="${2:-16379}" ;;
  mq)    HOST="$(ssm mq_console_url | sed -E 's#^https?://([^/:]+).*#\1#')"; PORT=443; LOCAL="${2:-15671}" ;;
  *) sed -n '3,9p' "$0"; exit 1 ;;
esac

BASTION="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${NAME}-bastion" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [ -z "$BASTION" ] || [ "$BASTION" = "None" ]; then
  echo "Bastion 이 없습니다 — AWS 개발 환경이 꺼져 있습니다 (평일 09:00~19:00 에만 켜짐)" >&2; exit 1
fi

echo "localhost:$LOCAL → $HOST:$PORT (bastion $BASTION). Ctrl+C 로 종료"
exec aws ssm start-session --region "$AWS_REGION" --target "$BASTION" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$HOST,portNumber=$PORT,localPortNumber=$LOCAL"
