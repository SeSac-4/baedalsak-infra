#!/usr/bin/env bash
# =============================================================================
# 운영자 Cognito 풀 사용자 생성 — OPS_ADMIN_EMAILS · OPS_VIEWER_EMAILS (쉼표 구분)
#   없으면 만들고(이메일 검증 완료, 임시 비밀번호는 Cognito 초대 메일) 그룹에 넣음. 여러 번 실행해도 안전
#   목록에서 빠진 사용자는 지우지 않음 — 삭제는 콘솔 · CLI 에서 직접 (실수로 지우지 않게)
#   두 목록에 다 있으면 Admin. 공개 레포 로그에 남지 않게 이메일을 출력하지 않음
# 필요: aws cli, persistent apply 완료
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
POOL="$(ssm ops_cognito_user_pool_id)"
cognito() { aws cognito-idp "$@" --region "$AWS_REGION" --user-pool-id "$POOL"; }

# sync_users <쉼표 구분 이메일> <넣을 그룹> <뺄 그룹>
sync_users() {
  local count=0 created=0 email
  for email in ${1//,/ }; do
    if ! cognito admin-get-user --username "$email" >/dev/null 2>&1; then
      cognito admin-create-user --username "$email" --desired-delivery-mediums EMAIL \
        --user-attributes Name=email,Value="$email" Name=email_verified,Value=true >/dev/null
      created=$((created + 1))
    fi
    cognito admin-add-user-to-group --username "$email" --group-name "$2"
    cognito admin-remove-user-from-group --username "$email" --group-name "$3" # 권한이 바뀐 사용자 (없어도 에러 아님)
    count=$((count + 1))
  done
  echo "$2: $count 명 (새로 생성 $created)"
}

# Admin 을 나중에 — 두 목록에 다 있으면 grafana-viewer 가 빠지고 Admin 이 남음
sync_users "${OPS_VIEWER_EMAILS:-}" grafana-viewer grafana-admin
sync_users "${OPS_ADMIN_EMAILS:-}" grafana-admin grafana-viewer
