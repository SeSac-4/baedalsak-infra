#!/usr/bin/env bash
# =============================================================================
# prod 풀 가입 사용자 정리 — username(= member_id) 1000 이상 삭제, seed(1~999)는 유지
#   DB 는 매일 새로 떠서 member id 가 다시 1000 부터 시작 → 남은 Cognito 사용자와 겹치면 가입 실패
#   AWS 켜기(up)에서 앱 배포 전에 실행
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
POOL="$(ssm cognito_user_pool_id)"

aws cognito-idp list-users --region "$AWS_REGION" --user-pool-id "$POOL" \
  --query 'Users[].Username' --output text | tr '\t' '\n' |
  awk '/^[0-9]+$/ && $1 + 0 >= 1000' |
  while read -r u; do
    aws cognito-idp admin-delete-user --region "$AWS_REGION" --user-pool-id "$POOL" --username "$u"
    echo "삭제 $u"
  done
echo "Cognito 정리 완료 ($POOL)"
