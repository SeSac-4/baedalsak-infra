#!/usr/bin/env bash
# =============================================================================
# 공통 환경 변수 — scripts/aws/*.sh 가 source 함
#   값: 로컬은 .env (set -a; source .env; set +a), GitHub Actions 는 레포 Variables → 워크플로 env
#   이름 규칙은 Terraform 과 같음: <PROJECT>-<ENV_NAME>, <PROJECT>/<ENV_NAME>, /<PROJECT>/<ENV_NAME>
# =============================================================================
: "${AWS_REGION:?AWS_REGION 이 필요합니다 (AWS 리전, 예: ap-northeast-2)}"
: "${PROJECT:?PROJECT 가 필요합니다 (프로젝트 이름, 예: baedalsak)}"
: "${ENV_NAME:?ENV_NAME 이 필요합니다 (환경 이름, 예: prod)}"

# 선택 값 — 비우면 Terraform 과 같은 규칙으로 만듦 (Terraform 에도 같은 값을 TF_VAR_* 로 넘길 것)
NAME="${PROJECT}-${ENV_NAME}"
CLUSTER_NAME="${CLUSTER_NAME:-$NAME}"
SECRET_PREFIX="${SECRET_PREFIX:-${PROJECT}/${ENV_NAME}}"
SSM_PREFIX="${SSM_PREFIX:-/${PROJECT}/${ENV_NAME}}"
LOG_GROUP="${LOG_GROUP:-/${PROJECT}/${ENV_NAME}/containers}"
NS="$ENV_NAME" # 앱 namespace = 환경 이름 (Terraform local.namespace)

export AWS_REGION PROJECT ENV_NAME NAME CLUSTER_NAME SECRET_PREFIX SSM_PREFIX LOG_GROUP NS

# Terraform ephemeral 이 SSM_PREFIX 아래에 쓴 값 읽기
ssm() { aws ssm get-parameter --region "$AWS_REGION" --name "${SSM_PREFIX}/$1" --query Parameter.Value --output text; }
