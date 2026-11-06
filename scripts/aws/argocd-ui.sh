#!/usr/bin/env bash
# =============================================================================
# Argo CD UI 접속 (port-forward 전용 — ALB·CloudFront 에 노출하지 않음)
#   사용: argocd-ui.sh [로컬 포트, 기본 8090] → http://127.0.0.1:8090 , 사용자 admin
#   admin 비밀번호는 클러스터를 새로 만들 때마다(평일 09:30) 바뀜 → 실행할 때마다 출력
#   Ctrl+C 로 종료. 환경이 꺼져 있으면(평일 18:00~10:00) 실패
# 필요: aws cli, kubectl, 본인 IAM 자격 증명 + EKS 접근 등록 (TEAM_MEMBER_ARNS)
# =============================================================================
set -euo pipefail

export AWS_REGION="${AWS_REGION:-ap-northeast-2}" PROJECT="${PROJECT:-baedalsak}" ENV_NAME="${ENV_NAME:-prod}"
# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
LOCAL="${1:-8090}"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "http://127.0.0.1:$LOCAL  사용자 admin  비밀번호 $PW"
echo "Ctrl+C 로 종료"
kubectl -n argocd port-forward svc/argocd-server "$LOCAL:80"
