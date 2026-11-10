#!/usr/bin/env bash
# =============================================================================
# 캐시 Valkey 이미지 → ECR (<NAME>/valkey:<태그>) — 이미 있으면 아무것도 안 함
#   태그 = helm/charts/valkey/values.yaml 의 image.tag (파드가 쓰는 태그와 한 곳에서 관리)
#   Docker Hub 공식 이미지 valkey/valkey 를 linux/amd64 로 받아 그대로 올림 (빌드 없음)
#   실행: aws-stack.yml 의 persistent apply 직후(상시 리소스 적용 · AWS 켜기) + images-valkey.yml(태그를 바꿨을 때)
#   필요: docker · aws CLI, ECR 저장소 <NAME>/valkey (persistent)
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_IMAGE="docker.io/valkey/valkey"

TAG="$(sed -n 's/^  tag: *\([^ #]*\).*/\1/p' "$ROOT/helm/charts/valkey/values.yaml" | head -1)"
[[ "$TAG" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "helm/charts/valkey/values.yaml 의 image.tag 를 읽지 못했습니다: '$TAG'"; exit 1; }

REPO="$NAME/valkey"
if aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPO" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "valkey:$TAG 는 이미 ECR 에 있음 — 건너뜀"; exit 0
fi

REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
# 노드가 amd64 라 그 플랫폼 하나만 (태그 1개 = 매니페스트 1개 — ECR "최신 7개" 수명 주기가 이미지 단위로 세도록)
docker pull --quiet --platform linux/amd64 "$SOURCE_IMAGE:$TAG"
docker tag "$SOURCE_IMAGE:$TAG" "$REGISTRY/$REPO:$TAG"
docker push --quiet "$REGISTRY/$REPO:$TAG"
echo "valkey:$TAG → ECR 올림 ($(docker inspect --format '{{index .RepoDigests 0}}' "$SOURCE_IMAGE:$TAG"))"
