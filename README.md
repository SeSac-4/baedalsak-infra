# baedalsak-infra

배달싹(Spring Boot MSA, 서비스 6개: gateway(Ingress) · store(메뉴·가게) · order(주문·장바구니) · payment(결제) · delivery(배달) · member(인증·인가))의 **쿠버네티스 배포 설정**입니다.
지금은 로컬 K8s(minikube)에 배포하고, 같은 Helm 차트를 운영 EKS 에도 쓸 예정입니다.

- 이미지 빌드·로컬 의존성·CI 는 [`baedalsak-server`](https://github.com/SeSac-4/baedalsak-server) 에 있습니다. 이 저장소는 그 결과물을 **어디에 어떻게 띄울지**만 담습니다.
- 백엔드 ↔ 인프라 규칙(환경 변수 이름 등): `baedalsak-server/docs/backend-infra-rules.md`

## 검증 상태 (2026-10-14, minikube — 당시 notification 포함 7개 기준. 2026-10-15 notification 제거)

| 항목 | 결과 |
|---|---|
| 7개 서비스 배포 (`make dev-all`) | 모두 Ready |
| Ingress `/api/<경로>` 6개 | 모두 200 (`/api` 가 떼어져 gateway 에 도착) |
| `/api/actuator/*` | 404 (외부 차단) |
| HPA | 부하 시 1 → 3, 부하 후 3 → 1 |
| 부하 중 재배포 | 20,041건 모두 200 |

> 실제 서비스 코드가 아직 없어 `baedalsak-server/smoke-test`(검증용 모듈, 저장소 미포함)로 검증했습니다.

## AWS (EKS) — Terraform + GitHub Actions

AWS 개발 환경은 **평일 09:00 KST 자동으로 켜지고 19:00 KST 자동으로 꺼집니다** (기본 브랜치 develop 의 워크플로 기준).
구성·처음 설정·실행 순서는 [`docs/aws-runbook.md`](docs/aws-runbook.md), 환경 변수 목록은 [`.env.example`](.env.example).

| Actions 워크플로 | 하는 일 |
|---|---|
| AWS 켜기 (평일 09:00) | VPC·EKS·RDS(최신 스냅샷 복원)·MQ·Valkey·ALB 생성 → 애드온 → DB·MQ 초기화 → 앱 배포 → smoke test |
| AWS 끄기 (평일 19:00) | 앱·애드온 삭제 → 위 리소스 삭제 (RDS 최종 스냅샷 최신 7개 보관) |
| 앱 이미지 빌드 (서버 → ECR) | baedalsak-server 를 빌드해 ECR 에 올림 — 켜기는 마지막 빌드 이미지를 배포 |
| AWS 변경 미리보기 (plan) / AWS 상시 리소스 적용 | 수동 — terraform plan / ECR·Secrets Manager 등 상시 리소스 apply |

2026-10-21 테스트 레포에서 bootstrap → 상시 리소스 → 이미지 빌드 → 켜기(smoke test 통과) → 끄기(잔여 리소스 없음) 검증.

## 구성

```
baedalsak-infra/
├── Makefile                          # 모든 작업의 입구
├── helm/
│   ├── charts/baedalsak-service/     # 공통 차트 (6개 서비스 공용)
│   │   └── templates/                # deployment(probe) · service · configmap · hpa · pdb
│   │                                 # ingress · middleware(Traefik) · serviceaccount · externalsecret(AWS)
│   └── values/
│       ├── services/<서비스>.yaml     # DB 계정·schema, 사용 의존성, HPA 범위 (환경 무관)
│       ├── local.yaml                # minikube + compose 의존성
│       └── aws.yaml                  # EKS 빈칸 템플릿 (아직 배포에 쓰지 않음)
├── local/traefik-values.yaml         # 로컬 Ingress 컨트롤러
├── scripts/hpa-load.sh               # HPA 확장 확인용 부하
├── docs/                             # 팀 공유 문서
├── CLAUDE.md, .claude/               # Claude Code 작업 규칙
└── .gitignore
```

values 적용 순서: `차트 기본값 → services/<서비스>.yaml → local.yaml(또는 aws.yaml)`

```
 PC ─(port-forward :18080 / tunnel :80)─▶ Traefik ─/api 제거·X-Forwarded-Prefix 제거─▶ gateway:8080
      gateway ─ /v*/stores/** ─▶ store:8080   ... (order · payment · delivery · member)
      각 파드 ─ host.minikube.internal ─▶ PC 의 docker compose (postgres · rabbitmq · redis-session)  ※ DynamoDB 주석 처리, Zipkin 후순위
```

## 결정 사항

| 항목 | 결정 | 이유 |
|---|---|---|
| 로컬 K8s | minikube, **1노드**, docker 드라이버 | Docker Desktop 만으로 Windows(WSL2)·Mac·Linux 동일 |
| 의존성 | baedalsak-server 의 **compose 재사용**, 파드에서 `host.minikube.internal` 로 접속 | 평소 개발과 같은 DB·MQ, 설정이 두 벌로 갈라지지 않음 |
| 이미지 | compose 빌드 `baedalsak/<서비스>:local` → `local-<시각>` 태그로 minikube 에 load (AWS 는 ECR) | 새 태그여야 파드가 교체됨 |
| 차트 | 공통 차트 1개 + 서비스별 values 6개 | 배포 모양은 같고 DB 계정·HPA 범위만 다름 |
| Ingress | Traefik(Helm). `/api` 를 **떼고** gateway 에 전달 (`/api/v1/orders` → `/v1/orders`), `X-Forwarded-Prefix` 헤더 삭제 | 헤더가 남으면 Spring 이 경로를 `/api/...` 로 되돌려 404 |
| actuator | **8081** (`MANAGEMENT_SERVER_PORT`). Service·Ingress 에 열지 않음 | `/api/actuator` 외부 노출 차단. probe 는 파드에 직접 접속 |
| Secret | 각자의 `.env` 에서 키 6개만 골라 `baedalsak-local` 생성 (서비스는 필요한 키만 주입) | compose 와 같은 비밀번호, 비밀번호를 Git 에 두지 않음 |
| 실행 | Makefile (Windows 는 WSL2) | 팀원 모두 같은 명령 |
| K8s 버전 | 자리만 둠 (`K8S_VERSION`) | EKS 버전 결정 후 고정 |
| namespace / Service 포트 | `baedalsak` / 8080 | compose 와 같은 주소 `http://store:8080` |

## 환경 변수 주입 (`backend-infra-rules.md` 3번 이름 그대로)

| 변수 | 대상 | 출처 |
|---|---|---|
| `SPRING_PROFILES_ACTIVE`, `SERVER_PORT`, `MANAGEMENT_SERVER_PORT` | 전체 | ConfigMap |
| `DB_HOST/PORT/NAME/USER/SCHEMA` | gateway 제외 5개 | ConfigMap |
| `DB_PASSWORD` | gateway 제외 5개 | Secret |
| `RABBITMQ_HOST/PORT` | 6개 (compose 와 동일) | ConfigMap |
| `RABBITMQ_USER/PASSWORD` | 6개 | Secret |
| `REDIS_SESSION_HOST/PORT` | gateway, member | ConfigMap |
| `REDIS_SESSION_PASSWORD` | gateway, member | Secret |
| `JWT_SECRET` | gateway, member (`secretKeys`) | Secret |
| `TOSS_SECRET_KEY` | payment (`secretKeys`) | Secret |
| `RABBITMQ_VHOST`, `RABBITMQ_SSL_ENABLED` | RabbitMQ 사용 서비스 (로컬 `/`·false, AWS `/prod`·true) | ConfigMap |
| ~~`ZIPKIN_ENDPOINT`~~ | 후순위 (관측성) — 차트에서 주석 처리 | ConfigMap |
| `DYNAMODB_ENDPOINT`, `AWS_REGION` (+로컬 더미 키) | `dynamodb.enabled: true` 인 서비스 (**주석 처리 — 현재 없음**) | ConfigMap |
| `STORE_SERVICE_URL` … `MEMBER_SERVICE_URL` | gateway | ConfigMap |

DB: RDS 인스턴스 1개 + 서비스별 DB 5개 (`DB_NAME` = 서비스 `db.name`, 없으면 schema 이름)
DB 계정·schema: member `member_svc/member`, store `store_svc/store`, order `order_svc/orders`, payment `payment_svc/payment`, delivery `delivery_svc/delivery`

## Probe · 종료 · 보안

| 항목 | 값 |
|---|---|
| startup | `/actuator/health/liveness`, 5초 × 30회 = 최대 150초 (로컬 × 60 = 300초) |
| liveness | `/actuator/health/liveness`, 10초 간격, 3회 실패 시 재시작 |
| readiness | `/actuator/health/readiness`, 5초 간격, 3회 실패 시 트래픽 제외 (DB 미포함) |
| probe 포트 | 8081 (`management`) |
| 롤링 업데이트 | `maxUnavailable: 0` (새 파드 Ready 후 기존 파드 종료) |
| 종료 | preStop 10초 → SIGTERM → 앱 graceful 20초, 종료 유예 45초 |
| 보안 | UID/GID 1001 (Dockerfile `spring`), root 실행 금지, 읽기 전용 루트 파일시스템 + `/tmp` 만 쓰기 |

## HPA · 리소스

| 서비스 | 로컬 min~max | AWS min~max | CPU 목표 |
|---|---|---|---|
| gateway | 1~3 | 2~8 | 60% |
| order | 1~3 | 2~10 | 65% |
| payment | 1~3 | 2~6 | 60% |
| store · delivery · member | 1~3 | 2~6 | 70% |

- 확장은 즉시(30초마다 최대 2배), 축소는 5분 안정화 후 분당 50%씩
- requests/limits — 로컬: CPU 100m / 1, 메모리 512Mi / 512Mi · AWS: CPU 250m / 1, 메모리 768Mi / 768Mi
- PDB — 로컬 끔, AWS 켬 (최소 1개 유지)

## 사용

필요 도구: Docker(Desktop 메모리 8GB 이상), minikube, kubectl, helm, make. minikube 기본 자원은 CPU 4, 메모리 6GB (`CPUS=`, `MEMORY=` 로 변경).

```bash
# 0) baedalsak-server 위치 (실제 서비스 코드가 생기기 전까지는 smoke-test)
export SRV=../baedalsak-server            # 또는 ../baedalsak-server/smoke-test

# 1) 의존성 (baedalsak-server)
(cd $SRV && cp -n .env.example .env; docker compose up -d)

# 2) 클러스터 (baedalsak-infra)
make up SERVER_DIR=$SRV          # minikube + metrics-server + Traefik + namespace + Secret
make infra-check                 # 파드 → compose 의존성 연결 확인 (4줄 모두 OK)

# 3) 배포
make dev SVC=store SERVER_DIR=$SRV          # compose 로 빌드 → minikube 에 load → 배포
make dev-all SERVER_DIR=$SRV                # 6개 전체

# 4) 확인
make status
kubectl --context baedalsak -n traefik port-forward svc/traefik 18080:80   # 별도 터미널, 켜 둔 채로
curl -i http://localhost:18080/api/v1/stores
```

| 명령 | 설명 |
|---|---|
| `make tunnel` | (Linux·Mac) Traefik 을 `http://localhost` 로 연결. WSL2 + Docker Desktop 에서는 동작하지 않으므로 위 port-forward 사용 |
| `make logs SVC=store` | 로그 |
| `make secret SERVER_DIR=$SRV && make restart` | `.env` 변경 반영 |
| `make hpa-test SVC=store LOAD_PATH=stores` | HPA 부하 (다른 터미널: `kubectl --context baedalsak -n baedalsak get hpa -w`) |
| `make lint` / `make template-aws SVC=store` | 차트 검사 / 운영 템플릿 렌더링 확인 |
| `make uninstall SVC=store` | 서비스 제거 |
| `make down` / `make delete` | 클러스터 정지 / 삭제 |

- 프론트 개발 서버의 `/api` 프록시 대상: `http://localhost:18080` (tunnel 사용 시 `http://localhost`)
- 배포 직후 1~2분 HPA 의 `FailedGetResourceMetric` 경고는 정상 (metrics 수집 대기)

## GitHub 에 올리지 않는 것

`.gitignore` 참고: `.env`·키·kubeconfig, Helm 패키지(`*.tgz`), Terraform state·tfvars(예정), `*.zip`, IDE·OS 파일, 개인 Claude Code 설정(`.claude/settings.local.json`). `.claude/settings.json` 과 hooks 는 팀 공용이라 커밋합니다.

## 미정 · 확인 필요

| 항목 | 상태 |
|---|---|
| 운영에서 `/api` 를 떼는 위치 | ALB 는 경로를 바꿀 수 없음 → CloudFront Function / gateway 설정 등. 떼는 곳이 `X-Forwarded-Prefix` 를 붙이면 404 가 나므로 함께 확인 |
| ALB 헬스체크 | `aws.yaml` 에 `healthcheck-port: "8081"` 반영. ALB 보안그룹 → 파드 8081 인바운드 허용 필요 (Terraform) |
| DynamoDB 사용 서비스 | 현재 주석 처리 (목록: `baedalsak-server/docs/backend-infra-rules.md` 9번). 정해지면 `services/*.yaml` 에 `dynamodb.enabled: true` (운영은 `serviceAccount.irsa: true` 도) |
| EKS(=minikube) 쿠버네티스 버전 | Terraform 결정 후 `K8S_VERSION` 고정 |
| 운영 값 | RDS·MQ·ElastiCache 주소, Amazon MQ TLS(5671), ElastiCache TLS, 운영 프로필, Secrets Manager 키 규칙, IRSA 역할 |
| gateway 의 RabbitMQ 사용 여부 | 쓰지 않으면 `services/gateway.yaml` 에 `rabbitmq.enabled: false` |
| 모니터링 (후순위) | Prometheus · Grafana · Fluent Bit · Zipkin — 앱 설정은 주석 처리 (`baedalsak-server/docs/backend-infra-rules.md` 9번). 수집 주소 예정 `<파드IP>:8081/actuator/prometheus` |

## Claude Code 로 작업할 때

| 파일 | 역할 |
|---|---|
| `CLAUDE.md` | 결정값 표, 작업 원칙, 미정 목록, 보고 형식 (세션 시작 때 읽음) |
| `.claude/settings.json` | 결정값 파일 수정 금지(deny), 템플릿·Makefile 수정과 클러스터 변경 명령은 매번 승인(ask), bypass 모드 금지 |
| `.claude/hooks/protect-decisions.sh` | deny 규칙이 못 잡는 간접 수정(스크립트·cp·git restore 등) 차단 |
| `docs/claude-code-prompt.md` | 붙여 넣을 작업 프롬프트와 사용 순서 |

> 이 규칙은 Claude Code 를 **이 폴더에서** 실행할 때만 적용됩니다. 결정값을 바꿀 때는 사람이 직접 `helm/values/*` 를 수정하고, Claude Code 에게는 검증만 맡깁니다.

## 문서

| 문서 | 내용 |
|---|---|
| `docs/share-2026-10-14-ingress-actuator.md` | Ingress 404 수정 · actuator 8081 분리 |
| `baedalsak-server/docs/backend-infra-rules.md` | 백엔드 ↔ 인프라 연동 규칙 |
| `baedalsak-server/docs/backend-ci.md` | CI (GitHub Actions — 테스트 · 빌드 · Trivy) |
