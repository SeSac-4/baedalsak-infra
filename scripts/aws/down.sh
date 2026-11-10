#!/usr/bin/env bash
# =============================================================================
# 끄기 준비 — terraform destroy 전에 실행
#   앱(Argo CD ApplicationSet 삭제) · Grafana TGB 삭제 → TargetGroupBinding 0개 확인 → monitoring(Grafana·Prometheus·Loki) 삭제
#   → Argo CD 삭제 → 애드온 삭제
#   LBC 가 TGB 에 finalizer 를 붙이므로 LBC 를 먼저 지우면 TGB 삭제가 멈춤
# =============================================================================
set -uo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"

echo "== 앱 삭제 (Argo CD)"
# ApplicationSet 을 지우면 Application 6개가 지워지고, finalizer 로 앱 리소스(gateway TGB 포함)도 함께 삭제
#   Argo CD 를 먼저 지우면 finalizer 를 처리할 주체가 없어 삭제가 멈춤 → Argo CD 는 맨 뒤 애드온 단계에서 삭제
kubectl -n argocd delete applicationset baedalsak --ignore-not-found --wait --timeout=5m 2>/dev/null || true
# 캐시 Valkey 는 ApplicationSet 밖의 Application (helm/argocd/valkey-cache.yaml) — 따로 지워야 아래 0개 대기가 끝남
kubectl -n argocd delete application valkey-cache --ignore-not-found --wait --timeout=5m 2>/dev/null || true
for _ in $(seq 1 30); do
  n="$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "0" ] && break
  echo "남은 Application: $n"; sleep 10
done
# helm 으로 올라간 앱이 남아 있으면 (Argo CD 전환 전에 켠 클러스터) 함께 정리
for svc in gateway member store order payment delivery; do
  helm uninstall "$svc" -n "$NS" --wait --timeout 5m 2>/dev/null || true
done

# monitoring 은 이 대기 뒤에 지우므로 Grafana TGB 를 먼저 지움 (LBC 가 살아 있을 때)
kubectl -n monitoring delete targetgroupbinding grafana --ignore-not-found --wait --timeout=2m 2>/dev/null || true
kubectl -n argocd delete targetgroupbinding argocd --ignore-not-found --wait --timeout=2m 2>/dev/null || true

echo "== TargetGroupBinding 0개 대기"
for _ in $(seq 1 30); do
  n="$(kubectl get targetgroupbindings -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "0" ] && break
  echo "남은 TGB: $n"; sleep 10
done

kubectl delete namespace "$NS" --wait --timeout=5m 2>/dev/null || true

echo "== monitoring 삭제 (Prometheus·Grafana · Loki · Tempo)"
helm uninstall monitoring -n monitoring --wait --timeout 5m 2>/dev/null || true
# Loki 는 종료 시 메모리의 로그를 S3 로 내보냄 (앱 종료 로그까지 들어온 뒤라 유실 없음)
helm uninstall loki -n monitoring --wait --timeout 5m 2>/dev/null || true
helm uninstall tempo -n monitoring --wait --timeout 5m 2>/dev/null || true
kubectl delete namespace monitoring --wait --timeout=5m 2>/dev/null || true
kubectl delete clustersecretstore aws-secrets-manager aws-parameter-store --ignore-not-found 2>/dev/null || true

echo "== Argo CD 삭제"
helm uninstall argocd -n argocd --wait --timeout 5m 2>/dev/null || true
kubectl delete namespace argocd --wait --timeout=5m 2>/dev/null || true

echo "== 애드온 삭제"
helm uninstall aws-for-fluent-bit -n kube-system 2>/dev/null || true
helm uninstall metrics-server -n kube-system 2>/dev/null || true
helm uninstall external-secrets -n external-secrets 2>/dev/null || true
helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true
helm uninstall aws-load-balancer-controller -n kube-system --wait 2>/dev/null || true
echo "done"
