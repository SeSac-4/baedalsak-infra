#!/usr/bin/env bash
# =============================================================================
# 배포 실패 시 되돌리기 — deploy.sh 가 기록한 서비스별 직전 정상 리비전으로 helm rollback
#   처음 설치(이전 리비전 없음)는 되돌릴 대상이 없어 그대로 둠
# =============================================================================
set -uo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
PREV="${TMPDIR:-/tmp}/${NAME}-deploy-prev"
[ -s "$PREV" ] || { echo "되돌릴 기록이 없습니다 ($PREV)"; exit 0; }

fail=0
while read -r svc rev; do
  if [ -z "$rev" ]; then echo "skip $svc (이전 배포 없음)"; continue; fi
  echo "== rollback $svc → revision $rev"
  helm rollback "$svc" "$rev" -n "$NS" --wait --timeout 10m || fail=1
done < "$PREV"

kubectl -n "$NS" get pods -o wide
if [ "$fail" -eq 0 ]; then echo "ROLLBACK DONE"; else echo "ROLLBACK FAILED"; fi
exit "$fail"
