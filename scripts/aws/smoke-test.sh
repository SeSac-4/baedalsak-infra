#!/usr/bin/env bash
# =============================================================================
# smoke test — 배포 직후 실행. 하나라도 실패하면 exit 1
#   1) 파드 6종 Ready
#   2) 대상 그룹(gateway) healthy 2개 이상
#   3) 각 파드 readiness = UP (8081)
#   4) internal ALB → gateway → 각 서비스 라우팅 (/v1/stores 등이 502·503·504 가 아니면 통과)
#   5) (참고) 각 서비스 /actuator/health 전체 — DB·MQ·Redis 연결 상태 출력만
# internal ALB·파드 IP 는 VPC 안에서만 닿으므로 클러스터 안의 curl 파드로 확인
# =============================================================================
set -uo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
REGION="$AWS_REGION"
SVCS="gateway member store order payment delivery"
fail=0

echo "== 1) 파드 Ready"
for s in $SVCS; do
  if kubectl -n "$NS" rollout status "deploy/$s" --timeout=2m >/dev/null; then echo "PASS $s"; else echo "FAIL $s"; fail=1; fi
done

echo "== 2) 대상 그룹 healthy"
TG_ARN="$(ssm target_group_arn)"
ALB="$(ssm alb_dns)"
healthy=0
for _ in $(seq 1 30); do
  healthy="$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  [ "$healthy" -ge 2 ] && break
  sleep 10
done
aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
if [ "$healthy" -ge 2 ]; then echo "PASS healthy=$healthy"; else echo "FAIL healthy=$healthy"; fail=1; fi

echo "== 3~5) 클러스터 안에서 확인"
POD_IPS=""
for s in $SVCS; do
  ip="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$s" -o jsonpath='{.items[0].status.podIP}')"
  POD_IPS="$POD_IPS $s=$ip"
done

kubectl -n "$NS" delete pod smoke-test --ignore-not-found >/dev/null
# shellcheck disable=SC2016 # 작은따옴표 안의 변수는 curl 파드 안에서 펼침
kubectl -n "$NS" run smoke-test --image=curlimages/curl:8.11.1 --restart=Never --rm -i \
  --env="POD_IPS=$POD_IPS" --env="ALB=$ALB" --command -- sh -c '
f=0
echo "-- 3) readiness (pod:8081)"
for kv in $POD_IPS; do
  s=${kv%%=*}; ip=${kv#*=}
  body=$(curl -s -m 5 "http://$ip:8081/actuator/health/readiness")
  case "$body" in *"\"UP\""*) echo "PASS $s $body";; *) echo "FAIL $s $body"; f=1;; esac
done
echo "-- 4) ALB → gateway → 서비스 라우팅"
for p in /v1/stores /v1/categories /v1/orders /v1/cart /v1/payments /v1/deliveries/waiting /v1/members/me; do
  code=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "http://$ALB$p")
  case "$code" in 502|503|504|000) echo "FAIL $p -> $code"; f=1;; *) echo "PASS $p -> $code";; esac
done
echo "-- 5) (참고) /actuator/health 전체"
for kv in $POD_IPS; do
  s=${kv%%=*}; ip=${kv#*=}
  echo "$s: $(curl -s -m 5 "http://$ip:8081/actuator/health")"
done
exit $f
' || fail=1

if [ "$fail" -eq 0 ]; then echo "SMOKE TEST PASSED"; else echo "SMOKE TEST FAILED"; fi
exit "$fail"
