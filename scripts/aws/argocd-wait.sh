#!/usr/bin/env bash
# =============================================================================
# Argo CD 배포 대기 — 앱 6개가 <이미지 태그> 로 Synced · Healthy 가 되고 롤아웃이 끝날 때까지 (서비스당 최대 10분)
#   사용: argocd-wait.sh <이미지 태그>
#   먼저 refresh 를 요청해 Git 확인 주기(약 3분)를 기다리지 않게 함. argocd CLI 로그인 없이 kubectl 로 상태를 읽음
# =============================================================================
set -euo pipefail

TAG="${1:?기다릴 이미지 태그가 필요합니다}"
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
SVCS="member store order payment delivery gateway"

for svc in $SVCS; do
  kubectl -n argocd annotate application "$svc" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
done

for svc in $SVCS; do
  deadline=$((SECONDS + 600))
  while true; do
    st="$(kubectl -n argocd get application "$svc" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true)"
    img="$(kubectl -n "$NS" get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [ "$st" = "Synced Healthy" ] && [ "${img##*:}" = "$TAG" ]; then break; fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "FAIL $svc (상태: ${st:-없음}, 이미지: ${img:-없음}, 기대 태그: $TAG)"
      echo "sync 메시지: $(kubectl -n argocd get application "$svc" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
      kubectl -n argocd get application "$svc" -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null || true
      exit 1
    fi
    sleep 10
  done
  # 상태 갱신 직전의 Healthy 를 잘못 읽지 않게 롤아웃 완료까지 한 번 더 확인
  kubectl -n "$NS" rollout status "deploy/$svc" --timeout=10m >/dev/null
  echo "OK $svc ($TAG)"
done
kubectl -n argocd get applications
