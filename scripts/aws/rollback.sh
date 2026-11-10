#!/usr/bin/env bash
# =============================================================================
# 배포 실패 시 되돌리기 — 사용: rollback.sh <실패한 이미지 태그>
#   helm/values/aws-image.yaml 에서 그 태그를 올린 커밋을 git revert·push (scripts/aws/image-tag.sh)
#   → Argo CD 가 직전 태그로 sync → 6개가 직전 태그로 뜰 때까지 대기
#   develop 의 태그가 이미 다른 태그로 바뀌었거나 되돌릴 커밋이 없으면 그대로 둠
#   push 권한이 필요해 앱 이미지 빌드(images.yml)가 부른 배포에서만 실행
# =============================================================================
set -uo pipefail

TAG="${1:?실패한 이미지 태그가 필요합니다}"
DIR="$(dirname "$0")"

PREV="$("$DIR/image-tag.sh" revert "$TAG")" || { echo "ROLLBACK FAILED (revert·push 실패)"; exit 1; }
if [ -z "$PREV" ]; then echo "되돌릴 대상 없음"; exit 0; fi

if "$DIR/argocd-wait.sh" "$PREV"; then echo "ROLLBACK DONE ($TAG → $PREV)"; else echo "ROLLBACK FAILED ($PREV 로 뜨지 않음)"; exit 1; fi
