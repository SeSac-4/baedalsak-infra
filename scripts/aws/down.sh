#!/usr/bin/env bash
# =============================================================================
# 끄기 준비 — terraform destroy 전에 실행
#   앱(helm uninstall) → TargetGroupBinding 0개 확인 → 애드온 삭제
#   LBC 가 TGB 에 finalizer 를 붙이므로 LBC 를 먼저 지우면 TGB 삭제가 멈춤
# =============================================================================
set -uo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"

echo "== 앱 삭제"
for svc in gateway member store order payment delivery; do
  helm uninstall "$svc" -n "$NS" --wait --timeout 5m 2>/dev/null || true
done

echo "== TargetGroupBinding 0개 대기"
for _ in $(seq 1 30); do
  n="$(kubectl get targetgroupbindings -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "0" ] && break
  echo "남은 TGB: $n"; sleep 10
done

kubectl delete namespace "$NS" --wait --timeout=5m 2>/dev/null || true
kubectl delete clustersecretstore aws-secrets-manager --ignore-not-found 2>/dev/null || true

echo "== 애드온 삭제"
helm uninstall aws-for-fluent-bit -n kube-system 2>/dev/null || true
helm uninstall metrics-server -n kube-system 2>/dev/null || true
helm uninstall external-secrets -n external-secrets 2>/dev/null || true
helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true
helm uninstall aws-load-balancer-controller -n kube-system --wait 2>/dev/null || true
echo "done"
