#!/usr/bin/env bash
# =============================================================================
# AWS 앱 매니페스트 렌더링 — Argo CD 와 같은 값 파일 순서로 helm template (클러스터 · AWS 접속 없음)
#   사용: scripts/ci/render-aws.sh <레포 경로> <출력 디렉터리>
#   앱 6개: helm/argocd/applicationset.yaml 의 valueFiles 순서 + valuesObject(__이름__ placeholder 그대로)
#   캐시 Valkey: helm/argocd/valkey-cache.yaml 의 valuesObject · NetworkPolicy: deploy.sh 와 같은 치환
#   store 의 helm.parameters(IMAGE_BUCKET · IMAGE_BASE_URL)도 같은 placeholder 로 넣음
#   .github/workflows/pr-check.yml 이 PR 의 base · head 를 각각 렌더링해 비교한다
# =============================================================================
set -euo pipefail

repo=$(cd "$1" && pwd)
out=$2
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Argo CD 매니페스트의 helm.valuesObject 를 values 파일(JSON)로 꺼냄
values_object() { # <매니페스트> <출력 파일>
  python3 - "$1" "$2" <<'PY'
import json, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
spec = doc["spec"]
src = (spec.get("template", {}).get("spec") or spec)["source"]
json.dump(src["helm"]["valuesObject"], open(sys.argv[2], "w"))
PY
}

values_object "$repo/helm/argocd/applicationset.yaml" "$tmp/appset.json"
values_object "$repo/helm/argocd/valkey-cache.yaml" "$tmp/valkey.json"

v="$repo/helm/values"
for svc in member store order payment delivery gateway; do
  extra=()
  if [ "$svc" = store ]; then
    extra=(--set-string extraEnv.IMAGE_BUCKET=__IMAGE_BUCKET__ --set-string extraEnv.IMAGE_BASE_URL=__IMAGE_BASE_URL__)
  fi
  helm template "$svc" "$repo/helm/charts/baedalsak-service" -n __NAMESPACE__ \
    -f "$v/services/$svc.yaml" -f "$v/aws.yaml" -f "$v/aws-services/$svc.yaml" -f "$v/aws-image.yaml" \
    -f "$tmp/appset.json" "${extra[@]}" > "$out/$svc.yaml"
done

helm template valkey-cache "$repo/helm/charts/valkey" -n __NAMESPACE__ -f "$tmp/valkey.json" > "$out/valkey-cache.yaml"

# NetworkPolicy — deploy.sh 와 같은 문자열 치환 (ALB 대역은 예시 값, 실제는 SSM alb_subnet_cidrs)
netpol="$(<"$repo/scripts/aws/networkpolicy.yaml")"
netpol="${netpol//'${NS}'/prod}"
blocks="$(printf '        - ipBlock: { cidr: %s }\n' 10.0.66.0/27 10.0.66.32/27)"
printf '%s\n' "${netpol//'${ALB_IP_BLOCKS}'/$blocks}" > "$out/networkpolicy.yaml"
