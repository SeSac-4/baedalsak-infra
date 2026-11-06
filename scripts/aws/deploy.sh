#!/usr/bin/env bash
# =============================================================================
# 앱 6개 배포 (Argo CD, namespace = ENV_NAME) — 사용: deploy.sh <이미지 태그>
#   <이미지 태그> = helm/values/aws-image.yaml 에 커밋된 태그 (이 스크립트는 기다릴 태그로만 씀 — 배포 기준은 Git)
#   1) 네임스페이스 · readiness gate 라벨 · NetworkPolicy (파드보다 먼저)
#   2) AppProject(helm/argocd/appproject.yaml) · ApplicationSet(applicationset.yaml) 에 Git 에 둘 수 없는 값을 채워 적용
#      → Argo CD 가 6개 sync
#   3) 6개가 그 태그로 Synced · Healthy 될 때까지 대기 (scripts/aws/argocd-wait.sh)
#   서비스별 값(gateway HPA 2~4·PDB·TGB, 연결 풀 5)은 helm/values/aws.yaml · aws-services/ 에 있음
#   Argo CD 는 addons.sh 가 설치 (없으면 실패)
# =============================================================================
set -euo pipefail

TAG="${1:?이미지 태그가 필요합니다 (helm/values/aws-image.yaml 의 태그)}"
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
REGION="$AWS_REGION"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Argo CD 가 읽을 레포·브랜치 (기본: 이 레포 develop)
REPO_URL="${GITOPS_REPO_URL:-https://github.com/${GITHUB_REPOSITORY:-SeSac-4/baedalsak-infra}.git}"
REVISION="${GITOPS_REVISION:-develop}"

kubectl -n argocd get deploy argocd-server >/dev/null 2>&1 || { echo "Argo CD 가 없습니다 — scripts/aws/addons.sh 를 먼저 실행하세요"; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ALB_CIDRS="$(ssm alb_subnet_cidrs)"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# 새 파드가 ALB 에서 healthy 가 된 뒤 이전 파드 종료 (롤링 배포 중 502 방지)
kubectl label namespace "$NS" elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

# ingress 기본 차단 + 허용 목록 (scripts/aws/networkpolicy.yaml) — 파드보다 먼저 적용 (Argo CD 관리 밖)
ALB_IP_BLOCKS="$(for cidr in ${ALB_CIDRS//,/ }; do echo "        - ipBlock: { cidr: $cidr }"; done)"
NETPOL="$(<"$ROOT/scripts/aws/networkpolicy.yaml")"
NETPOL="${NETPOL//'${NS}'/$NS}"
printf '%s\n' "${NETPOL//'${ALB_IP_BLOCKS}'/$ALB_IP_BLOCKS}" | kubectl apply -f -

# ApplicationSet 의 __이름__ 채우기 — 계정 번호가 들어가거나(ECR·TG ARN·버킷) 매일 바뀌는 값(TG ARN·MQ 주소 등)
declare -A V=(
  [REPO_URL]="$REPO_URL"
  [REVISION]="$REVISION"
  [NAMESPACE]="$NS"
  [IMAGE_REGISTRY]="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
  [IMAGE_NAMESPACE]="$NAME"
  [AWS_REGION]="$REGION"
  [SECRET_PREFIX]="$SECRET_PREFIX"
  [SSM_PREFIX]="$SSM_PREFIX"
  [RDS_HOST]="$(ssm rds_host)"
  [MQ_HOST]="$(ssm mq_host)"
  [MQ_VHOST]="/$ENV_NAME"
  [REDIS_HOST]="$(ssm redis_host)"
  [TG_ARN]="$(ssm target_group_arn)"
  [IMAGE_BUCKET]="$(ssm image_bucket)"
  [IMAGE_BASE_URL]="$(ssm image_base_url)"
)
# 프로젝트(허용 범위)를 먼저 — ApplicationSet 이 만든 Application 이 프로젝트를 찾지 못해 실패하지 않게
for f in appproject applicationset; do
  M="$(<"$ROOT/helm/argocd/$f.yaml")"
  for k in "${!V[@]}"; do M="${M//"__${k}__"/"${V[$k]}"}"; done # 따옴표: 값 안의 & 를 그대로
  if grep -q '"__[A-Z_]*__"' <<<"$M"; then echo "$f: 채우지 못한 값 $(grep -o '"__[A-Z_]*__"' <<<"$M" | sort -u | tr '\n' ' ')"; exit 1; fi
  printf '%s\n' "$M" | kubectl apply -f -
done

# Argo CD 가 sync → 6개가 이 태그로 뜰 때까지 대기 (ExternalSecret 도 Healthy 판정에 포함)
"$ROOT/scripts/aws/argocd-wait.sh" "$TAG"
kubectl -n "$NS" get pods -o wide
