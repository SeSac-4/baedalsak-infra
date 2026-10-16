#!/usr/bin/env bash
# 클러스터 안에서 서비스로 부하를 줘서 HPA 확장을 확인
#   ./scripts/hpa-load.sh <서비스> <경로> [동시수=20] [초=180]
#   경로는 서비스의 실제 API (예: store → v1/stores). actuator 는 8081 이라 Service 로 접근 불가
set -euo pipefail
SVC=${1:?서비스명}; P=${2:?API 경로 (예: v1/stores)}; C=${3:-20}; SEC=${4:-180}
CTX=${CTX:-baedalsak}; NS=${NS:-baedalsak}

echo "▶ http://$SVC:8080/$P 에 동시 $C개로 ${SEC}초 부하"
echo "  다른 터미널에서 확인: kubectl --context $CTX -n $NS get hpa $SVC -w"
kubectl --context "$CTX" -n "$NS" run "load-$SVC" --rm -i --restart=Never --image=busybox:1.36 -- sh -c "
  end=\$((\$(date +%s)+$SEC))
  for i in \$(seq $C); do
    ( while [ \$(date +%s) -lt \$end ]; do wget -q -O /dev/null http://$SVC:8080/$P || true; done ) &
  done
  wait; echo 부하 종료"
echo "▶ 축소는 5분 안정화 후 진행됩니다."
