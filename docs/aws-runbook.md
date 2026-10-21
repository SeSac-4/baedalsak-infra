# AWS 배포 런북 (Terraform + GitHub Actions)

설계 기준: `배달싹_시스템설계서_v3` · `배달싹-인프라-결정-및-백엔드-협의_v14.md`

## 구성

```
terraform/
├── bootstrap/   처음 한 번, WSL2 에서 관리자 자격 증명으로 apply (state 버킷 · GitHub OIDC · Actions 역할)
├── persistent/  매일 지우지 않음: ECR 6 · Secrets Manager · 로그 그룹 · RDS 파라미터 그룹
└── ephemeral/   매일 apply·destroy: VPC · NAT · EKS · 노드그룹 · internal ALB · 대상 그룹 · RDS · MQ · Valkey · Bastion · Pod Identity · SSM
scripts/aws/     env.sh(공통 변수) · addons.sh · db-init.sh · deploy.sh · smoke-test.sh · down.sh  (워크플로가 호출)
.github/workflows/
├── aws-up.yml          AWS 켜기 (평일 09:00 자동 + 수동)
├── aws-down.yml        AWS 끄기 (평일 19:00 자동 + 수동, 최종 스냅샷 7개 보관)
├── aws-plan.yml        AWS 변경 미리보기 (plan)
├── aws-persistent.yml  AWS 상시 리소스 적용 (ECR·Secrets)
├── aws-stack.yml       (공통) 위 4개가 호출하는 본체 — 직접 실행 안 함
└── images.yml          앱 이미지 빌드 (서버 레포 SERVER_REPO → ECR)
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

레포 → Settings → Secrets and variables → Actions → **Variables** 에 추가 (`.env` 와 같은 이름, `TF_VAR_*` 는 넣지 않음 — 워크플로가 만듦):

| 이름 | 필수 | 값 (예시) |
|---|---|---|
| `AWS_REGION` | ✅ | `ap-northeast-2` |
| `PROJECT` | ✅ | `baedalsak` |
| `ENV_NAME` | ✅ | `prod` |
| `AZS` | ✅ | `["ap-northeast-2a","ap-northeast-2c"]` |
| `KUBERNETES_VERSION` | ✅ | `1.35` |
| `TF_STATE_BUCKET` | ✅ | bootstrap output `state_bucket` |
| `AWS_ROLE_ARN` | ✅ | bootstrap output `github_actions_role_arn` |
| `SERVER_REPO` | ✅ (images) | `SeSac-4/baedalsak-server` |
| `SERVER_REF` | ✅ (images) | `develop` — 실행 시 입력 `server_ref` 가 우선 |
| `TEAM_MEMBER_ARNS` | 선택 | `["arn:aws:iam::<계정>:user/<이름>"]` (없으면 `[]`) |
| `TEAM_MEMBER_POLICY` | 선택 | `AmazonEKSAdminViewPolicy`(기본, 조회) / `AmazonEKSClusterAdminPolicy` |
| `ALB_CERTIFICATE_ARN` | 선택 | ACM 인증서 ARN (없으면 HTTP 80) |
| `CLUSTER_NAME` · `SECRET_PREFIX` · `SSM_PREFIX` · `LOG_GROUP` | 선택 | 비우면 이름 규칙 |

**Secrets** (선택): `SERVER_REPO_TOKEN` — 서버 레포가 private 일 때만. 서버 레포 `Contents: Read` 권한의 fine-grained PAT. 없으면 기본 `github.token` 으로 체크아웃합니다.

워크플로 버튼(workflow_dispatch)은 **기본 브랜치에 있는 워크플로만** 보입니다. 기본 브랜치(main)에 push 한 뒤 실행하세요.

## 2. 실행 순서 (Actions 탭)

처음 한 번:

1. **AWS 변경 미리보기 (plan)** → 오류 없는지 확인 (변수 누락 시 `check variables` 단계에서 멈춤)
2. **AWS 상시 리소스 적용 (ECR·Secrets)** → ECR·Secrets Manager 생성
3. **앱 이미지 빌드 (서버 → ECR)** · server_ref 비움(=`SERVER_REF`) → Summary 에 `image_tag` (서버 커밋 7자리)

매일 (자동, 월~금 · 기본 브랜치의 워크플로 기준):

| 시각 (KST) | 워크플로 | 하는 일 |
|---|---|---|
| 09:00 | **AWS 켜기** | 약 25~30분. image_tag 를 비우면 ECR 에 마지막으로 빌드된 이미지를 배포. 마지막 단계 `smoke test` 가 `SMOKE TEST PASSED` 면 성공 |
| 19:00 | **AWS 끄기** | 앱·애드온 삭제 → ephemeral destroy (RDS 최종 스냅샷 생성) → 최종 스냅샷 최신 7개만 보관 |

- 켜기는 가장 최근 최종 스냅샷(`<PROJECT>-<ENV_NAME>-final-*`)에서 RDS 를 복원합니다 (스냅샷이 없으면 빈 DB 로 생성 → Flyway 가 테이블 생성).
- 새 서버 코드를 반영하려면 **앱 이미지 빌드** 를 먼저 실행하세요 (켜기는 이미지를 빌드하지 않음).
- 예약 실행은 GitHub 사정으로 수 분~수십 분 늦게 시작될 수 있고, 공휴일은 따로 막지 않습니다.
- 켜기·끄기는 같은 동시 실행 그룹(`aws-stack`)이라 겹치면 앞의 실행이 끝날 때까지 기다립니다.

## 3. smoke test 가 보는 것

| 단계 | 통과 기준 |
|---|---|
| 파드 6종 | rollout 완료 |
| 대상 그룹 | gateway healthy 2개 이상 (헬스체크 `/actuator/health/readiness` 8081) |
| 각 파드 readiness | `UP` |
| internal ALB → gateway → 서비스 | `/v1/stores` 등이 502·503·504 가 아님 (서비스에 컨트롤러가 없으면 404 가 정상) |
| `/actuator/health` 전체 | 출력만 (DB·MQ·Redis 연결 상태 참고) |

internal ALB 는 VPC 안에서만 닿으므로 클러스터 안의 curl 파드로 확인합니다.

### 팀원 접속 (평일 09:00~19:00, 켜져 있을 때)
준비: aws cli + [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), 본인 IAM 키로 `aws configure` (리전 `ap-northeast-2`). EKS 는 레포 변수 `TEAM_MEMBER_ARNS` 에 본인 ARN 이 있어야 함.
```bash
./scripts/aws/tunnel.sh api     # localhost:8080 → internal ALB → gateway (예: curl localhost:8080/v1/stores)
./scripts/aws/tunnel.sh db      # localhost:15432 → RDS (계정은 Secrets Manager <SECRET_PREFIX>/<서비스>)
./scripts/aws/tunnel.sh redis   # localhost:16379 → ElastiCache (TLS + AUTH)
./scripts/aws/tunnel.sh mq      # https://localhost:15671 → Amazon MQ 콘솔
aws eks update-kubeconfig --name baedalsak-prod --region ap-northeast-2
kubectl -n prod get pods; kubectl -n prod logs deploy/order
```

## 4. 오늘 버전에서 설계와 다른 점 (임시)

| 항목 | 설계 | 지금 | 바꿀 때 |
|---|---|---|---|
| 진입 | CloudFront VPC origin → internal ALB HTTPS | internal ALB **HTTP 80** 만, 외부 진입 없음 | 도메인·ACM ② 발급 후 `alb_certificate_arn` 지정, CloudFront 스택 추가 |
| `/api` 제거 | gateway StripPrefix | 현재 gateway 코드는 `/v1/...` 를 받음 (협의 9번) | 백엔드 StripPrefix 반영 후 `/api/v1/...` 로 smoke test 경로 변경 |
| 인증 | Cognito | 앱이 아직 `JWT_SECRET` 사용 → Secrets Manager 에 임의 값 | 협의 1·2번 반영 후 Cognito 스택 추가 |
| MQ 계정 | (결정 없음) | 앱이 브로커 관리자 계정 사용 | 서비스별 계정 필요 시 mq-init 에 추가 |
| 토스 키 | Secrets Manager | `<SECRET_PREFIX>/payment` 의 `TOSS_SECRET_KEY` 가 자리표시자 | 콘솔에서 값 교체 (Terraform 이 덮어쓰지 않음) |
| 운영 자동화 | Scheduler → Step Functions → Lambda | 수동 (Actions 버튼) | 다음 단계 |
| Redis TLS | 앱 설정 | `SPRING_DATA_REDIS_SSL_ENABLED=true` 환경 변수로 켬 | 협의 6번 (`REDIS_SESSION_SSL_ENABLED`) 반영 시 교체 |

## 5. 도메인 구매 (baedalsak.com)

1. AWS 콘솔 → **Route 53** → 왼쪽 **Registered domains** → **Register domains**
2. `baedalsak.com` 검색 → 장바구니 → 기간 1년
3. 연락처 입력 → **Auto-renew 끄기** (결정: 자동 갱신 OFF) → 개인정보 보호(Privacy protection) 켜기
4. 결제 후 등록 메일의 확인 링크 클릭 (15분~수 시간 걸릴 수 있음)
5. 등록이 끝나면 Route 53 이 **호스티드 존을 자동 생성** → 다음 단계에서 Terraform 으로 import 해서 persistent 스택이 관리 (ACM ①② DNS 검증, CloudFront, SES DKIM)

Route 53 Domains 결제는 신용카드가 계정에 등록돼 있어야 하고, 크레딧(교육용 등)으로는 결제되지 않을 수 있습니다.

## 6. 문제 해결

| 증상 | 확인 |
|---|---|
| `AssumeRoleWithWebIdentity` 실패 | 레포 변수 `AWS_ROLE_ARN`, bootstrap 때 `GITHUB_REPO` 가 이 레포(owner/repo)였는지 |
| ESO Secret 이 안 생김 | `kubectl -n <ENV_NAME> describe externalsecret <서비스>` — Pod Identity 연결(namespace external-secrets, SA external-secrets) |
| 파드 CrashLoop | Actions 로그 `debug on failure` 단계 — Flyway(DB 계정) · RabbitMQ vhost(`/<ENV_NAME>`) · Redis TLS |
| 대상 그룹 unhealthy | 노드 SG 에 ALB SG → 8080·8081 허용, readiness 가 UP 인지 |
| destroy 가 TGB 에서 멈춤 | LBC 를 먼저 지운 경우 — `kubectl patch targetgroupbinding <이름> -n <ENV_NAME> -p '{"metadata":{"finalizers":[]}}' --type=merge` |
