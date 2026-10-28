# baedalsak-infra

배달싹(Spring Boot MSA, 서비스 6개: gateway(Ingress) · store(메뉴·가게) · order(주문·장바구니) · payment(결제) · delivery(배달) · member(인증·인가))의 **쿠버네티스 배포 설정**입니다.
같은 Helm 차트로 로컬 K8s(minikube)와 AWS 개발 환경(EKS)에 배포하고, AWS 리소스는 Terraform + GitHub Actions 로 만듭니다.

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

AWS 개발 환경은 **평일 09:30 KST 에 켜지고 19:00 KST 에 꺼집니다** (EventBridge Scheduler → Step Functions → Lambda → GitHub Actions, Asia/Seoul).
켜기·끄기 결과는 **실패했을 때만** 메일로 옵니다. 매일 09:00 에 전날 서비스별 비용 메일이 옵니다.
구성·처음 설정·실행 순서는 [`docs/aws-runbook.md`](docs/aws-runbook.md), 환경 변수 목록은 [`.env.example`](.env.example).

| Actions 워크플로 | 실행 | 하는 일 |
|---|---|---|
| AWS 켜기 (평일 09:30) | 예약 · 수동 | 상시 리소스 apply → VPC·EKS·RDS(빈 DB, 개발 기간)·MQ·Valkey·ALB·CloudFront 생성 → 애드온 → DB·MQ 초기화 → 앱 배포 → smoke test |
| AWS 끄기 (평일 19:00) | 예약 · 수동 | 앱·애드온 삭제 → 위 리소스 삭제 (개발 기간: RDS 스냅샷 없음 — 다음 켜기 때 Flyway 가 스키마 생성) |
| 앱 이미지 빌드 (서버 → ECR) | 서버 develop 머지 시 자동 · 수동 | baedalsak-server 6개 이미지 빌드 → ECR → 켜져 있으면 앱 배포 |
| 프론트 배포 (클라이언트 → S3) | 클라이언트 develop push 시 자동 · 수동 | `npm run build`(토스 클라이언트 키는 Parameter Store) → S3 → CloudFront 무효화 |
| AWS 상시 리소스 적용 | 수동 | persistent 스택 apply (ECR · Secrets Manager · Parameter Store · Cognito · SES · S3 · 운영 자동화) |
| AWS 변경 미리보기 (plan) | 수동 | terraform plan |

- 2026-10-21 테스트 레포에서 bootstrap → 상시 리소스 → 이미지 빌드 → 켜기(smoke test 통과) → 끄기(잔여 리소스 없음) 검증.
- 2026-10-28 켜기 성공 — 관측(Prometheus · Grafana · Loki · Tempo) 포함, 파드 29개.

## 구성

```
baedalsak-infra/
├── Makefile                          # 로컬(minikube) 작업의 입구
├── helm/
│   ├── charts/baedalsak-service/     # 공통 차트 (6개 서비스 공용)
│   │   └── templates/                # deployment(probe) · service · configmap · hpa · pdb
│   │                                 # ingress · middleware(Traefik) · serviceaccount · externalsecret · targetgroupbinding(AWS)
│   ├── values/
│   │   ├── services/<서비스>.yaml     # DB 계정·schema, 사용 의존성, HPA 범위 (환경 무관)
│   │   ├── local.yaml                # minikube + compose 의존성
│   │   └── aws.yaml                  # EKS 공통 값 (주소·리전은 scripts/aws/deploy.sh 가 --set)
│   └── addons/                       # AWS 애드온 values — kube-prometheus-stack · loki · tempo · aws-for-fluent-bit
├── terraform/
│   ├── bootstrap/                    # 처음 1회 — state S3 · GitHub OIDC 역할
│   ├── persistent/                   # 상시 — ECR · Secrets Manager · Parameter Store · Cognito · SES · S3 · CloudTrail · 운영 자동화(Lambda ①~④)
│   └── ephemeral/                    # 평일 생성·삭제 — VPC · EKS · RDS · MQ · ElastiCache · ALB · CloudFront · 알람
├── scripts/
│   ├── aws/                          # addons · deploy · db-init · smoke-test · rollback · down · tunnel …
│   └── hpa-load.sh                   # HPA 확장 확인용 부하
├── .github/workflows/                # 켜기 · 끄기 · 이미지 빌드 · 프론트 배포 · 상시 리소스 · plan
├── local/traefik-values.yaml         # 로컬 Ingress 컨트롤러
├── docs/                             # 팀 공유 문서
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
| Ingress | Traefik(Helm). `/api/...` 를 **그대로** gateway 에 전달 — `/api` 는 gateway(SCG `StripPrefix=1`)가 뗌 (server #22) | 로컬·AWS 가 같은 경로 (ALB 는 경로를 못 바꿈) |
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
| ~~`JWT_SECRET`~~ | 미사용 (Cognito 전환) — 로컬 `make secret` 은 .env 에 키가 있어야 해서 남겨 둠 | Secret |
| `TOSS_SECRET_KEY` | payment (`secretKeys`) | Secret |
| `RABBITMQ_VHOST`, `RABBITMQ_SSL_ENABLED` | RabbitMQ 사용 서비스 (로컬 `/`·false, AWS `/prod`·true) | ConfigMap |
| ~~`ZIPKIN_ENDPOINT`~~ | 사용 안 함 — 추적은 OpenTelemetry → Tempo (아래) | — |
| `DYNAMODB_ENDPOINT`, `AWS_REGION` (+로컬 더미 키) | `dynamodb.enabled: true` 인 서비스 (**주석 처리 — 현재 없음**) | ConfigMap |
| `STORE_SERVICE_URL` … `MEMBER_SERVICE_URL` | gateway | ConfigMap |
| `ORDER_SERVICE_URL` | payment (결제 요청 생성 시 주문 조회) | ConfigMap |

AWS 에서만 추가로 넣는 값

| 변수 | 대상 | 출처 |
|---|---|---|
| `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID` | member | Parameter Store → ESO → Secret |
| `COGNITO_ISSUER_URI` | gateway | Parameter Store → ESO → Secret |
| `SPRING_DATA_REDIS_SSL_ENABLED` | 6개 (ElastiCache TLS) | ConfigMap |
| `MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT` | 6개 — Tempo `http://tempo.monitoring.svc.cluster.local:4318/v1/traces` | ConfigMap (`deploy.sh`) |
| `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` | gateway 제외 5개 — `5` (RDS 연결 수 한도) | ConfigMap (`deploy.sh`) |
| `SPRING_FLYWAY_LOCATIONS` | member (seed 위치) | ConfigMap |

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

| 서비스 | 로컬 min~max | AWS values 결정값 | AWS 지금 (개발 기간, `deploy.sh` 가 덮어씀) |
|---|---|---|---|
| gateway | 1~3 | 2~8 (CPU 60%) | **2~4** (CPU 70%, 3분 넘게 높을 때 확장) · PDB 최소 1 |
| order | 1~3 | 2~10 (CPU 65%) | **1 고정** (부하 테스트 때 1~3) |
| payment | 1~3 | 2~6 (CPU 60%) | **1 고정** (부하 테스트 때 1~3) |
| store · delivery · member | 1~3 | 2~6 (CPU 70%) | **1 고정** |

- 확장은 즉시(30초마다 최대 2배), 축소는 5분 안정화 후 분당 50%씩
- requests/limits — 로컬: CPU 100m / 1, 메모리 512Mi / 512Mi · AWS: CPU 100m / 제한 없음, 메모리 768Mi / 768Mi
- PDB — 로컬 끔, AWS gateway 켬 (최소 1개 유지)

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

`.gitignore` 참고: `.env`·키·kubeconfig, Helm 패키지(`*.tgz`), Terraform state·tfvars, `*.zip`, IDE·OS 파일, 개인 작업 도구 설정.
비밀값(비밀번호·토스 시크릿 키 등)은 Secrets Manager, 계정 번호가 든 값은 GitHub Secrets 에만 둡니다.

## 미정 · 확인 필요

| 항목 | 상태 |
|---|---|
| DynamoDB 사용 서비스 | 현재 주석 처리 (목록: `baedalsak-server/docs/backend-infra-rules.md` 9번). 정해지면 `services/*.yaml` 에 `dynamodb.enabled: true` (운영은 `serviceAccount.irsa: true` 도) |
| 로컬 쿠버네티스 버전 | EKS 는 1.35 (레포 변수 `KUBERNETES_VERSION`). minikube 는 자리만 둠 (`K8S_VERSION`) |
| gateway 의 RabbitMQ 사용 여부 | 쓰지 않으면 `services/gateway.yaml` 에 `rabbitmq.enabled: false` |
| 메일 | SES 샌드박스(인증된 주소만 수신) — 프로덕션 액세스 요청 전. 메일 템플릿 관리 방식 결정 중. DMARC 레코드 없음 |
| 매일 끄기 때 MQ 잔여 메시지 | 브로커와 함께 사라짐 — 손실 허용 여부 미정 |

## 관측 (AWS)

| 항목 | 경로 | 상태 |
|---|---|---|
| 지표 | 앱 `:8081/actuator/prometheus` → Prometheus(보관 1일) → Grafana | store · order 는 서버 노출 설정 대기 |
| 로그 | 파드 stdout → Fluent Bit → Loki → S3 (14일) → Grafana | 동작 |
| 추적 | 앱(OpenTelemetry) → Tempo → S3 (14일) → Grafana | Tempo 설치됨, 서버 OpenTelemetry 전환 대기 |
| 알람 | CloudWatch 알람 5개(ALB 5xx · gateway unhealthy · RDS CPU·저장공간 · Redis 메모리) → SNS → 메일 | 동작 |

Grafana 는 외부에 열지 않습니다 — 접속 방법은 `docs/aws-runbook.md`. 백엔드 설정 요청은 `docs/관측성/배달싹_관측성_백엔드_설정요청_v1.md`.

## 문서

| 문서 | 내용 |
|---|---|
| `docs/aws-runbook.md` | AWS 구성 · 처음 설정 · 실행 순서 · 접속 · 문제 해결 |
| `docs/관측성/배달싹_관측성_백엔드_설정요청_v1.md` | 백엔드 관측(Prometheus · OpenTelemetry · Tempo) 설정 요청 |
| `docs/share-2026-10-14-ingress-actuator.md` | Ingress 404 수정 · actuator 8081 분리 |
| `baedalsak-server/docs/backend-infra-rules.md` | 백엔드 ↔ 인프라 연동 규칙 |
| `baedalsak-server/docs/backend-ci.md` | CI (GitHub Actions — 테스트 · 빌드 · Trivy) |
