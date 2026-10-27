# AWS 배포 런북 (Terraform + GitHub Actions)

설계 기준: `배달싹_시스템설계서_v3` · `배달싹-인프라-결정-및-백엔드-협의_v14.md`

## 구성

```
terraform/
├── bootstrap/   처음 한 번, WSL2 에서 관리자 자격 증명으로 apply (state 버킷 · GitHub OIDC · Actions 역할)
├── persistent/  매일 지우지 않음 (AWS 전체 구성 v1)
│     main.tf     ECR 6(최신 7개 보관) · Secrets Manager · 로그 그룹 · RDS 파라미터 그룹
│     dns.tf      Route 53 존(구매 시 자동 생성, 참조만) · ACM ①(us-east-1, CloudFront) · ACM ②(서울, ALB) · DNS 검증
│     frontend.tf S3 프론트 · OAC · CF Function(SPA 경로)
│     cognito.tf  사용자 풀 2개(prod · 로컬 개발) · 그룹 3개 · member 앱 클라이언트
│     ses.tf      도메인 자격 · DKIM
│     audit.tf    로그 버킷(CloudTrail · ALB 액세스 30일) · CloudTrail(전체 리전)
│     ops.tf      SNS(메일 구독) · Lambda ①②③ · Step Functions · EventBridge Scheduler(평일 09:30·19:00) · Budgets
└── ephemeral/   매일 apply·destroy: VPC · NAT · EKS · 노드그룹 · internal ALB(HTTPS) · 대상 그룹 · RDS · MQ · Valkey · Bastion · Pod Identity · SSM
      edge.tf     CloudFront 배포 · VPC origin · Route 53 alias (ALB 에 묶여 있어 함께 생성·삭제)
      alarms.tf   CloudWatch 알람 → SNS → 메일
scripts/aws/     env.sh(공통 변수) · addons.sh · db-init.sh · deploy.sh · smoke-test.sh · down.sh  (워크플로가 호출)
.github/workflows/
├── aws-up.yml          AWS 켜기 (Scheduler 평일 09:30 + 수동)
├── aws-down.yml        AWS 끄기 (Scheduler 평일 19:00 · 예산 초과 + 수동)
├── aws-plan.yml        AWS 변경 미리보기 (plan)
├── aws-persistent.yml  AWS 상시 리소스 적용 (ECR·Secrets)
├── aws-stack.yml       (공통) 위 4개가 호출하는 본체 — 직접 실행 안 함
├── images.yml          앱 이미지 빌드 (서버 레포 SERVER_REPO → ECR) → 켜져 있으면 배포
└── frontend.yml        프론트 배포 (클라이언트 레포 CLIENT_REPO → npm build → S3 → CloudFront 무효화)
```

## 0. 환경변수

환경마다 달라지는 값(리전·프로젝트·환경 이름·버킷·ARN 등)은 코드에 없고 **전부 환경변수**로 받습니다.
전체 목록·설명·예시는 [`.env.example`](../.env.example) 에 있습니다.

| 쓰는 곳 | 받는 방법 |
|---|---|
| `terraform/*` | `variable` → `TF_VAR_*` (backend 의 bucket·region 은 `terraform init -backend-config=...`) |
| `scripts/aws/*.sh` | `scripts/aws/env.sh` 가 필수 값 검사(`: "${VAR:?}"`) 후 이름을 만듦 |
| `.github/workflows/*.yml` | 레포 Variables `vars.*` → `env` |
| `helm/values/aws.yaml` | 비워 두고 `deploy.sh` 가 `--set` |

이름 규칙 (Terraform·스크립트·워크플로 공통): 리소스 `<PROJECT>-<ENV_NAME>` · Secrets Manager `<PROJECT>/<ENV_NAME>/*` ·
SSM `/<PROJECT>/<ENV_NAME>/*` · 로그 그룹 `/<PROJECT>/<ENV_NAME>/containers` · ECR `<PROJECT>-<ENV_NAME>/<서비스>` · 앱 namespace `<ENV_NAME>`.
`CLUSTER_NAME`·`SECRET_PREFIX`·`SSM_PREFIX`·`LOG_GROUP` 을 넣으면 그 값이 규칙보다 우선합니다 (로컬·GitHub 에 같은 값을 넣을 것).

## 1. 처음 한 번 — bootstrap (WSL2, 로컬)

```bash
# 도구 설치 (Ubuntu)
sudo apt-get update && sudo apt-get install -y unzip gnupg software-properties-common curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip -q awscliv2.zip && sudo ./aws/install
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# 관리자 권한 IAM 사용자 액세스 키로 로그인 (bootstrap 에만 사용, 키는 .env 에 넣지 않음)
aws configure
aws sts get-caller-identity          # 계정 ID 확인 → TF_STATE_BUCKET 이름에 사용

# 환경변수 준비 (레포 루트)
cp .env.example .env                 # 값 수정: GITHUB_REPO · TF_STATE_BUCKET · AZS 등
set -a; source .env; set +a

# bootstrap — state 버킷 · GitHub OIDC · Actions 역할
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
terraform -chdir=terraform/bootstrap output   # state_bucket, github_actions_role_arn
```

`terraform/bootstrap/terraform.tfstate` 는 로컬에 남습니다(커밋 금지, .gitignore 대상). 잃어버리면 `terraform import` 로 복구합니다.
GitHub OIDC provider 는 계정당 하나라서, 같은 계정에 이미 있으면 `terraform import aws_iam_openid_connect_provider.github <ARN>` 후 apply 합니다.

(선택) 로컬에서 persistent·ephemeral 을 직접 다룰 때:

```bash
set -a; source .env; set +a
for s in persistent ephemeral; do
  terraform -chdir=terraform/$s init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION"
done
terraform -chdir=terraform/persistent plan
```

### GitHub 레포 Variables

레포 → Settings → Secrets and variables → Actions → **Variables** 에 추가 (`.env` 와 같은 이름, `TF_VAR_*` 는 넣지 않음 — 워크플로가 만듦). 표에서 **Secret** 표시는 **Secrets** 에 — 공개 레포라 계정 번호·메일이 로그에 안 남게:

| 이름 | 필수 | 값 (예시) |
|---|---|---|
| `AWS_REGION` | ✅ | `ap-northeast-2` |
| `PROJECT` | ✅ | `baedalsak` |
| `ENV_NAME` | ✅ | `prod` |
| `AZS` | ✅ | `["ap-northeast-2a","ap-northeast-2c"]` |
| `KUBERNETES_VERSION` | ✅ | `1.35` |
| `TF_STATE_BUCKET` | ✅ **Secret** | bootstrap output `state_bucket` (계정 번호 포함 → 공개 로그 노출 방지로 Secret) |
| `AWS_ROLE_ARN` | ✅ **Secret** | bootstrap output `github_actions_role_arn` (계정 번호 포함 → Secret) |
| `SERVER_REPO` | ✅ (images) | `SeSac-4/baedalsak-server` |
| `SERVER_REF` | ✅ (images) | `develop` — 실행 시 입력 `server_ref` 가 우선 |
| `TEAM_MEMBER_ARNS` | 선택 **Secret** | `["arn:aws:iam::<계정>:user/<이름>"]` (없으면 `[]`) |
| `TEAM_MEMBER_POLICY` | 선택 | `AmazonEKSAdminViewPolicy`(기본, 조회) / `AmazonEKSClusterAdminPolicy` |
| `DOMAIN_NAME` | ✅ | `baedalsak.click` (Route 53 에서 구매) |
| `CLIENT_REPO` / `CLIENT_REF` | ✅ (frontend) | `SeSac-4/baedalsak-client` / `develop` |
| `BUDGET_DAILY_USD` | 선택 | 일일 예산 USD (기본 10) — 넘으면 끄기 |
| `BUDGET_WARN_USD` | 선택 | 일일 비용 경고 USD (기본 5) — 넘으면 메일만 |
| `COST_REPORT_SENDER` | 선택 | 일일 비용 메일 발신 주소 (기본 `cost-report@<DOMAIN_NAME>`) |
| `COST_TAG_KEY` | 선택 | 일일 비용 메일 ② 표 태그 키 (기본 `Stack`) |
| `CLUSTER_NAME` · `SECRET_PREFIX` · `SSM_PREFIX` · `LOG_GROUP` | 선택 | 비우면 이름 규칙 |

**Secrets** (선택): `ALERT_EMAILS` — 알림 메일 JSON 배열 `["<메일>@example.com"]` (알람·켜기/끄기 결과·예산). 공개 레포라 Variables 가 아닌 Secret (로그에 `***`). 처음 apply 후 "AWS Notification - Subscription Confirmation" 메일의 링크를 1회 클릭 / `SERVER_REPO_TOKEN` — 서버 레포가 private 일 때만. 서버 레포 `Contents: Read` 권한의 fine-grained PAT. 없으면 기본 `github.token` 으로 체크아웃합니다.

워크플로 버튼(workflow_dispatch)은 **기본 브랜치에 있는 워크플로만** 보입니다. 기본 브랜치(main)에 push 한 뒤 실행하세요.

## 2. 실행 순서 (Actions 탭)

처음 한 번:

1. **AWS 변경 미리보기 (plan)** → 오류 없는지 확인 (변수 누락 시 `check variables` 단계에서 멈춤)
2. **AWS 상시 리소스 적용 (ECR·Secrets)** → ECR·Secrets Manager 생성
3. **앱 이미지 빌드 (서버 → ECR)** · server_ref 비움(=`SERVER_REF`) → Summary 에 `image_tag` (서버 커밋 7자리)

매일 (자동, 월~금 · EventBridge Scheduler → Step Functions → Lambda ① → 기본 브랜치 워크플로):

| 시각 (KST) | 워크플로 | 하는 일 |
|---|---|---|
| 09:30 | **AWS 켜기** | 약 25분 → 10:00 전 사용 가능. image_tag 를 비우면 ECR 에 마지막으로 빌드된 이미지를 배포. 마지막 단계 `smoke test` 가 `SMOKE TEST PASSED` 면 성공 |
| 19:00 | **AWS 끄기** | 앱·애드온 삭제 → ephemeral destroy (개발 기간: RDS 스냅샷 없음 — 데이터 사라짐) |

- 개발 기간에는 RDS 를 **매일 빈 DB 로 생성**합니다 (db.t4g.micro · Single-AZ · 자동 백업·최종 스냅샷 없음) → db-init 이 DB·계정, 각 서비스 Flyway 가 테이블 생성. 운영 방식(Multi-AZ · 스냅샷 복원)은 `data.tf`·`aws-stack.yml` 에 주석으로 남겨 둠.
- 새 서버 코드는 아래 "서버 커밋 자동 배포" 로 반영됩니다 (켜기 자체는 이미지를 빌드하지 않음). 수동으로는 **앱 이미지 빌드** 실행.
- 예약은 Scheduler 가 정시에 시작합니다 (공휴일은 막지 않음). 끝나면(성공·실패·2시간 초과) Lambda ② 가 결과를 확인해 `ALERT_EMAILS` 로 메일을 보냅니다.
  - 제목 `[baedalsak-prod] AWS up|down OK|FAILED`
  - 본문: AWS 상태 확인(켜기: EKS·노드그룹·RDS·`https://<DOMAIN>/api/v1/stores` 응답 / 끄기: 남은 EKS·RDS·MQ·ElastiCache·ALB·NAT·EC2·CloudFront) + GitHub 실행 링크 · 막힌 job·step · 오류 줄 · 로그 마지막 40줄
  - 워크플로가 성공해도 AWS 상태 확인에서 걸리면 FAILED (예: 끄기 후 NAT 가 남음)
- 일일 비용이 `BUDGET_WARN_USD`(5) 를 넘으면 경고 메일, `BUDGET_DAILY_USD`(10) 를 넘으면 Budgets → Lambda ③ 가 끄기를 실행합니다.
- **일일 비용 메일**: 매일 09:00 KST Lambda ④ `cost_report` 가 전날 하루 비용(Cost Explorer, 크레딧·환불 차감 전)을 SES 로 보냅니다. 제목 `[배달싹] YYYY-MM-DD 일일 비용 $X.XX`, 표 ① 서비스별 ② 스택 태그별(`Stack` = persistent / ephemeral).
  - 발신 `cost-report@<DOMAIN_NAME>`(레포 변수 `COST_REPORT_SENDER` 로 변경 가능), 수신 Secret `ALERT_EMAILS` — SES 샌드박스라 수신 주소마다 "Amazon Web Services – Email Address Verification Request" 메일 링크 1회 클릭
  - 처음 한 번 콘솔: Billing and Cost Management → **Cost Explorer 시작** · **비용 할당 태그** → `Stack` 활성화 (활성화 후 하루 지나야 ② 표가 채워짐, 그 전엔 "집계 전")

### 예약·알림 준비 (한 번, persistent apply 후 콘솔에서 값 넣기)

| Secrets Manager | 값 | 없으면 |
|---|---|---|
| `<SECRET_PREFIX>/github-dispatch` | GitHub fine-grained PAT — 레포 baedalsak-infra, **Actions: Read and write** | 예약 켜기·끄기가 실행 안 됨 (Step Functions 실패 → 알림) |
| `<SECRET_PREFIX>/seed` | `{"SEED_PASSWORD":"..."}` — prod 풀 seed 사용자 비밀번호 (seed 스크립트만 읽음, 파드에 안 들어감) | prod 풀 seed 실행 불가 |

```bash
aws secretsmanager put-secret-value --secret-id baedalsak/prod/github-dispatch --secret-string '<PAT>'
# seed 비밀번호 — 화면·기록에 안 남게 입력
read -rsp 'SEED_PASSWORD: ' SP; echo
aws secretsmanager put-secret-value --region ap-northeast-2 --secret-id baedalsak/prod/seed \
  --secret-string "$(jq -cn --arg p "$SP" '{SEED_PASSWORD:$p}')" --query VersionId --output text; unset SP
```

### 프론트 배포 (baedalsak-client develop → S3)

- **프론트 배포** 워크플로: 클라이언트 레포 체크아웃 → `npm ci && npm run build` → `dist/` 를 S3 에 2회 업로드(assets 1년 캐시 → `index.html` no-cache) → 켜져 있으면 `/index.html` 무효화
- 자동 실행: 클라이언트 레포에 서버와 같은 `notify-infra.yml` 을 두고 `event_type=client-updated` 로 보내면 됨 (Secret `INFRA_DISPATCH_TOKEN` 도 클라이언트 레포에). 그 전까지는 수동 실행
- 접속: `https://<DOMAIN_NAME>` (켜져 있는 평일 10:00~19:00)
- 켜기·끄기는 같은 동시 실행 그룹(`aws-stack`)이라 겹치면 앞의 실행이 끝날 때까지 기다립니다.

### 서버 커밋 자동 배포 (baedalsak-server develop → AWS)

```
baedalsak-server develop push(머지)
  └ notify-infra.yml ── repository_dispatch(server-updated, sha) ──▶ baedalsak-infra
       └ 앱 이미지 빌드 (images.yml): sha 검증(develop 에 있는 커밋인지) → 6개 빌드 → ECR <PROJECT>-<ENV_NAME>/<서비스>:<sha 7자리>
            └ deploy (aws-stack action=deploy): 클러스터 켜져 있음 → deploy.sh + smoke test
                                                  꺼져 있음   → 건너뜀, 다음 AWS 켜기(09:30)가 이 이미지를 배포
```

- 6개 중 하나라도 빌드가 실패하면 배포하지 않습니다.
- 연속 머지는 순서대로 처리하고(`images` 그룹), 배포는 켜기·끄기와 겹치지 않습니다(`aws-stack` 그룹).
- 문서(`**.md`, `docs/**`)만 바뀐 push 는 알리지 않습니다.

준비 (한 번):

1. fine-grained PAT 발급 — Resource owner `SeSac-4`, Repository `baedalsak-infra` 만, 권한 **Contents: Read and write** (repository_dispatch 에 필요)
2. baedalsak-server → Settings → Secrets → Actions → **`INFRA_DISPATCH_TOKEN`** 에 1번 토큰
3. baedalsak-server 담당자가 아래 파일을 `.github/workflows/notify-infra.yml` 로 추가 (develop PR)
4. baedalsak-infra 의 이 변경(images.yml·aws-stack.yml)이 기본 브랜치(develop)에 있어야 함 — repository_dispatch 는 기본 브랜치 워크플로만 실행

```yaml
# =============================================================================
# 인프라 레포에 배포 알림 (baedalsak-server)
#
#   develop push(머지) → <owner>/baedalsak-infra 에 repository_dispatch(server-updated, sha)
#   → 인프라 레포 "앱 이미지 빌드" 가 이 커밋을 ECR 로 빌드
#   → AWS 가 켜져 있으면 바로 배포 + smoke test / 꺼져 있으면 다음 켜기(평일 09:00) 때 배포
#
#   필요: 레포 Secret INFRA_DISPATCH_TOKEN
#         fine-grained PAT, 대상 레포 baedalsak-infra, 권한 Contents: Read and write
# =============================================================================
name: notify-infra

on:
  push:
    branches: [develop]
    paths-ignore: ["**.md", "docs/**"]   # 문서만 바뀌면 다시 빌드할 필요 없음

permissions: {}

jobs:
  notify:
    name: 인프라 레포에 알림
    runs-on: ubuntu-24.04
    steps:
      - env:
          GH_TOKEN: ${{ secrets.INFRA_DISPATCH_TOKEN }}
          SHA: ${{ github.sha }}
        run: |
          if [ -z "$GH_TOKEN" ]; then echo "::error::레포 Secret INFRA_DISPATCH_TOKEN 이 없습니다"; exit 1; fi
          gh api "repos/${GITHUB_REPOSITORY_OWNER}/baedalsak-infra/dispatches" \
            -f event_type=server-updated -f "client_payload[sha]=$SHA"
          echo "### 인프라 레포에 알림: \`$SHA\` → 이미지 빌드·배포는 baedalsak-infra Actions 에서 확인" >> "$GITHUB_STEP_SUMMARY"
```

## 3. smoke test 가 보는 것

| 단계 | 통과 기준 |
|---|---|
| 파드 6종 | rollout 완료 |
| 대상 그룹 | gateway healthy 2개 이상 (헬스체크 `/actuator/health/readiness` 8081) |
| 각 파드 readiness | `UP` |
| internal ALB → gateway → 서비스 | `/api/v1/stores` 등이 502·503·504 가 아님 (서비스에 컨트롤러가 없으면 404 가 정상) |
| `/actuator/health` 전체 | 출력만 (DB·MQ·Redis 연결 상태 참고) |
| 공개 경로 `https://<DOMAIN_NAME>/api/...` | CloudFront → VPC origin → ALB 443 → gateway 가 502·503·504 가 아님 (`/` 화면은 참고 출력) |

1~5 는 internal ALB 가 VPC 안에서만 닿으므로(ALB 80 은 노드·Bastion SG 만 허용) 클러스터 안의 curl 파드로, 공개 경로는 러너에서 확인합니다.

### 팀원 접속 (평일 10:00~19:00, 켜져 있을 때)
준비: aws cli + [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), 본인 IAM 키로 `aws configure` (리전 `ap-northeast-2`). EKS 는 레포 Secret `TEAM_MEMBER_ARNS` 에 본인 ARN 이 있어야 함.
```bash
./scripts/aws/tunnel.sh api     # localhost:8080 → internal ALB → gateway (예: curl localhost:8080/api/v1/stores)
./scripts/aws/tunnel.sh db      # localhost:15432 → RDS (계정은 Secrets Manager <SECRET_PREFIX>/<서비스>)
./scripts/aws/tunnel.sh redis   # localhost:16379 → ElastiCache (TLS + AUTH)
./scripts/aws/tunnel.sh mq      # https://localhost:15671 → Amazon MQ 콘솔
aws eks update-kubeconfig --name baedalsak-prod --region ap-northeast-2
kubectl -n prod get pods; kubectl -n prod logs deploy/order
```

### Cognito 인증 (2026-10-27 적용, 이슈 #13 · server #82)

```
가입:   member ─ AdminCreateUser(username=member_id, MessageAction=SUPPRESS, email_verified=true)
                → AdminSetUserPassword(Permanent=true) → AdminAddUserToGroup(CUSTOMER|OWNER|RIDER)
                  실패 시 AdminDeleteUser
로그인: member ─ AdminInitiateAuth(ADMIN_USER_PASSWORD_AUTH / REFRESH_TOKEN_AUTH) · 로그아웃 RevokeToken
검증:   gateway ─ JWKS(COGNITO_ISSUER_URI) 로 access 토큰 검증 → username → X-Member-Id, cognito:groups → X-Member-Role
```

| 항목 | 값 |
|---|---|
| 사용자 풀 (`terraform/persistent/cognito.tf`) | `<NAME>`(prod, 삭제 보호) · `<PROJECT>-local`(로컬 개발) — **Lite** 요금제, 이메일은 별칭(alias), self sign-up 끔, 그룹 CUSTOMER·OWNER·RIDER |
| 앱 클라이언트 | `ALLOW_ADMIN_USER_PASSWORD_AUTH` + `ALLOW_REFRESH_TOKEN_AUTH`, 토큰 폐기 켬, 시크릿 없음, access 30분 · refresh 14일 |
| 앱 환경 변수 | `deploy.sh` 가 SSM `<SSM_PREFIX>/cognito_*` 를 읽어 주입 — member `COGNITO_USER_POOL_ID`·`COGNITO_CLIENT_ID`, gateway `COGNITO_ISSUER_URI` (`AWS_REGION` 은 차트가 공통 주입) |
| member 권한 | Pod Identity `prod/member` → 역할 `<NAME>-member-cognito` — prod 풀 Admin 5개(Create·SetPassword·AddToGroup·Delete·InitiateAuth). RevokeToken 은 IAM 불필요 |
| 매일 정리 | 켜기(up) DB 초기화 직후 `scripts/aws/cognito-cleanup.sh` — prod 풀 **username 1000 이상 삭제** (DB 가 매일 새로 떠 member id 가 1000 부터 재사용) |
| seed 사용자 | username 1~999 (고객 1·2 · 사장님 101·102 · 라이더 201·202) — prod 풀에 1회 생성 후 유지, 비밀번호 `<SECRET_PREFIX>/seed` |
| 로컬 풀 | IAM 사용자 `sesac-d1`(member) · `sesac-d5`(인프라) 에 Admin API 권한 — 풀 ID·클라이언트 ID 는 `terraform -chdir=terraform/persistent output` 또는 콘솔 |
| `JWT_SECRET` | member 는 제거(helm `secretKeys`), gateway 는 #23(JWKS 검증) 머지 전까지 유지 |

## 4. 오늘 버전에서 설계와 다른 점 (임시)

| 항목 | 설계 | 지금 | 바꿀 때 |
|---|---|---|---|
| 진입 | CloudFront 는 persistent | CloudFront 배포·VPC origin 은 **ephemeral** (ALB 와 함께 매일 생성·삭제) → 꺼져 있는 시간엔 도메인도 응답 없음 | 상시 접속이 필요해지면 재검토 |
| ALB 80 | 443 만 | 80 은 VPC 안 전용으로 남김 (smoke test · Bastion 터널) | 터널을 HTTPS 로 바꾸면 제거 |
| 인증 | Cognito | member 는 Cognito Admin API 사용(3번 아래 "Cognito 인증" 절), **gateway 는 아직 `JWT_SECRET` 검증** | server #23(JWKS 검증) 머지 후 gateway `JWT_SECRET` 제거 |
| 메일 | SES | 도메인 자격·DKIM 생성, **샌드박스**(검증된 주소만) · Cognito 메일은 기본 발송(일 50통) | 콘솔에서 프로덕션 액세스 요청 → Cognito 를 SES 발송으로 |
| MQ 계정 | (결정 없음) | 앱이 브로커 관리자 계정 사용 | 서비스별 계정 필요 시 mq-init 에 추가 |
| 토스 키 | Secrets Manager | `<SECRET_PREFIX>/payment` 의 `TOSS_SECRET_KEY` 가 자리표시자 | 콘솔에서 값 교체 (Terraform 이 덮어쓰지 않음) |
| Redis TLS | 앱 설정 | `SPRING_DATA_REDIS_SSL_ENABLED=true` 환경 변수로 켬 | 협의 6번 (`REDIS_SESSION_SSL_ENABLED`) 반영 시 교체 |

## 5. 도메인 (baedalsak.click — 구매 완료 2026-10-22)

- Route 53 에서 `baedalsak.click` 구매 (자동 갱신 OFF, 만료 2027-10-21). 호스티드 존은 Route 53 이 자동 생성
- Terraform 은 존을 **참조만** 함 (`data "aws_route53_zone"`) — 존을 지우면 네임서버가 바뀌므로 소유하지 않음
- 이 존에 Terraform 이 만드는 레코드: ACM 검증 CNAME(persistent) · SES DKIM CNAME 3개(persistent) · `baedalsak.click` A/AAAA → CloudFront(ephemeral, 켜져 있을 때만)
- 레포 변수 `DOMAIN_NAME=baedalsak.click`

## 6. 문제 해결

| 증상 | 확인 |
|---|---|
| `AssumeRoleWithWebIdentity` 실패 | 레포 Secret `AWS_ROLE_ARN`, bootstrap 때 `GITHUB_REPO` 가 이 레포(owner/repo)였는지 |
| ESO Secret 이 안 생김 | `kubectl -n <ENV_NAME> describe externalsecret <서비스>` — Pod Identity 연결(namespace external-secrets, SA external-secrets) |
| 서버 머지 후 빌드가 안 돎 | 서버 레포 `notify-infra` 실행 결과 — `INFRA_DISPATCH_TOKEN` 없음/만료/권한(Contents: Read and write) |
| 파드 CrashLoop | Actions 로그 `debug on failure` 단계 — Flyway(DB 계정) · RabbitMQ vhost(`/<ENV_NAME>`) · Redis TLS |
| 대상 그룹 unhealthy | 노드 SG 에 ALB SG → 8080·8081 허용, readiness 가 UP 인지 |
| ACM 검증이 안 끝남 | Route 53 존의 `_xxxx.baedalsak.click` CNAME 확인 — 도메인 등록 직후엔 네임서버 전파에 수십 분 |
| CloudFront 502 | ALB SG 에 CloudFront-VPCOrigins-Service-SG → 443 규칙, ALB 443 리스너 인증서가 도메인과 같은지 |
| destroy 가 VPC 에서 멈춤 | VPC origin 이 남긴 ENI·`CloudFront-VPCOrigins-Service-SG` — VPC origin 삭제 완료(수 분) 후 다시 destroy |
| 예약 켜기·끄기가 안 돎 | 결과 메일의 "GitHub Actions" 부분 (dispatch 오류 코드: 401 토큰 · 404 권한/파일 · 422 입력) · Step Functions `<NAME>-power` 실행 기록 · Lambda `<NAME>-dispatch`·`<NAME>-report` 로그 |
| member 기동 실패 (Cognito 설정 없음) | member ConfigMap 에 `COGNITO_USER_POOL_ID`·`COGNITO_CLIENT_ID` 가 있는지 (`kubectl -n <ENV_NAME> get cm member -o yaml`), SSM `<SSM_PREFIX>/cognito_*` 존재 |
| 가입·로그인 503 | member Pod Identity 연결(`aws eks list-pod-identity-associations --cluster-name <NAME>`) · 연결 후 생성된 파드인지(재시작 필요) |
| 가입이 "이미 존재" 로 실패 | 켜기 로그의 `Cognito 정리` 단계 — username 1000 이상이 지워졌는지 |
| ephemeral 을 로컬에서 apply 함 | **금지** — EKS `cluster_creator` 가 로컬 IAM 사용자로 바뀌며 Actions 역할의 클러스터 권한이 지워짐(2026-10-27 발생). 적용은 Actions(켜기·plan)로만. 지워졌으면 `aws eks create-access-entry` + `associate-access-policy`(AmazonEKSClusterAdminPolicy) 로 Actions 역할 복구 |
| destroy 가 TGB 에서 멈춤 | LBC 를 먼저 지운 경우 — `kubectl patch targetgroupbinding <이름> -n <ENV_NAME> -p '{"metadata":{"finalizers":[]}}' --type=merge` |
