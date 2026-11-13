#!/usr/bin/env bash
# =============================================================================
# Argo CD UI 비상 접속 (port-forward) — 평소에는 https://<도메인>/argocd (운영자 Cognito 계정)
#   사용: argocd-ui.sh [로컬 포트, 기본 8090] → http://127.0.0.1:8090/argocd , 사용자 admin(인프라) · dev(개발팀, 읽기 전용)
#   admin 비밀번호는 클러스터를 새로 만들 때마다(평일 09:30) 바뀜 → 실행할 때마다 출력
#   Ctrl+C 로 종료. 환경이 꺼져 있으면(평일 18:00~10:00) 실패
# 필요: aws cli, kubectl, jq, 본인 IAM 자격 증명 + EKS 접근 등록 (TEAM_MEMBER_ARNS)
# =============================================================================
set -euo pipefail

export AWS_REGION="${AWS_REGION:-ap-northeast-2}" PROJECT="${PROJECT:-baedalsak}" ENV_NAME="${ENV_NAME:-prod}"
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
LOCAL="${1:-8090}"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
# 인프라 관리자 = admin (매일 바뀜) · 개발팀 = 읽기 전용 dev (Secrets Manager <SECRET_PREFIX>/argocd-dev, 고정)
#   개발팀은 argocd 네임스페이스 Secret 을 읽을 권한이 없음 (terraform/ephemeral/eks.tf · addons.sh Role)
if kubectl -n argocd auth can-i get secret/argocd-initial-admin-secret >/dev/null 2>&1; then
  USER_NAME="admin"
  PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
else
  USER_NAME=dev
  PW="$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "${SECRET_PREFIX}/argocd-dev" --query SecretString --output text | jq -r .password)"
fi
echo "http://127.0.0.1:$LOCAL/argocd  사용자 $USER_NAME  비밀번호 $PW"
echo "Ctrl+C 로 종료"
kubectl -n argocd port-forward svc/argocd-server "$LOCAL:80"
