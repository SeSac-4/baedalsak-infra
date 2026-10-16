# [공유] Ingress 404 수정 · actuator 포트 분리 (2026-10-14)

작성: 백엔드 B (baedalsak-infra) · 대상: 백엔드 A, C(Terraform), 프론트

## 한 줄 요약
- 로컬 K8s 에서 `/api/...` 요청이 **404** 나던 문제를 고쳤습니다.
- actuator 가 외부에 보이던 문제를 막으려고, K8s 에서는 **actuator 를 8081 포트로 분리**했습니다.
- 앱 코드는 고치지 않아도 됩니다. 아래 "담당별 할 일" 만 확인해 주세요.

## 1. 무엇이 문제였나

### 문제 1. `http://localhost/api/stores` → 404
| 단계 | 일어난 일 |
|---|---|
| ① Traefik | `/api` 를 떼고(`/api/stores` → `/stores`) gateway 에 전달하면서 `X-Forwarded-Prefix: /api` 헤더를 붙임 |
| ② Spring Boot | 쿠버네티스 안에서 실행되면 forwarded 헤더를 **자동으로** 반영함 → 요청 경로를 `/api/stores` 로 되돌림 |
| ③ gateway | 라우트가 `Path=/stores/**` 라서 매칭 실패 → 404 |

- 재현: gateway 에 직접 `/stores` 를 보내면 200, `-H "X-Forwarded-Prefix: /api"` 를 붙이면 404
- compose·VSCode 로 띄울 때는 ② 가 일어나지 않아 보이지 않던 문제입니다.

### 문제 2. `/api/actuator/health` 가 외부에서 200
- Ingress 는 `/api/*` 를 전부 gateway 로 넘기는데, actuator 가 서비스와 같은 8080 포트에 있었습니다.

## 2. 어떻게 고쳤나 (infra 차트만 수정)
| 문제 | 수정 |
|---|---|
| 1 | Traefik 미들웨어 `gateway-drop-prefix-header` 추가: `/api` 를 뗀 **다음** `X-Forwarded-Prefix` 헤더를 지움. "`/api` 를 떼고 gateway 로 전달" 결정은 그대로 |
| 2 | 차트가 모든 서비스에 `MANAGEMENT_SERVER_PORT=8081` 을 주입 → actuator 만 8081 로 이동. 컨테이너 포트 `management` 추가, startup·liveness·readiness probe 를 8081 로 변경. Service 는 8080 만 열어 둠 → Ingress 로 actuator 접근 불가 |
| 운영 | `helm/values/aws.yaml` 에 `alb.ingress.kubernetes.io/healthcheck-port: "8081"` 추가 (ALB 헬스체크도 8081 로) |

바뀌지 않은 것: probe 경로·주기, Service 포트 8080(`http://<서비스>:8080`), 환경 변수 3번 표의 기존 이름, `/api` 를 떼는 위치(로컬 Traefik)

## 3. 검증 결과 (minikube, gateway + store)
| 항목 | 결과 |
|---|---|
| `curl -i /api/stores` | 200, gateway 로그에 `GET /stores` (`/api` 없이 도착) |
| `/api/actuator`, `/api/actuator/health`, `/api/actuator/prometheus` | 모두 404 |
| 파드 안 `localhost:8081/actuator/health` | UP |
| 재시작 없이 Ready / readiness 실패 시 트래픽 제외 | 통과 |
| HPA | 부하 시 1 → 3, 부하 후 약 8분 뒤 3 → 1 |
| 부하 중 재배포 | 응답 20,041건 모두 200 (실패 0) |

## 4. 담당별 할 일

### 백엔드 A (서비스 코드)
- **필수 작업 없음.** `MANAGEMENT_SERVER_PORT` 는 Spring Boot 표준 변수(`management.server.port`)라 코드·`application.yml` 수정 없이 적용됩니다.
- 새 변수 `MANAGEMENT_SERVER_PORT` 는 `backend-infra-rules.md` 3번 표에 없습니다. 표에 추가할지 검토해 주세요. (K8s 에서만 주입. 값 8081)
- `application.yml` 에 `management.server.port` 를 직접 쓰지 말아 주세요. 쓰더라도 환경 변수가 우선하지만, 헷갈리는 원인이 됩니다.
- compose·VSCode 실행에는 이 변수가 없으므로 actuator 는 지금처럼 `SERVER_PORT` 에서 열립니다. (VSCode store 포트 8081 과도 충돌 없음)
- gateway 에서 forwarded 헤더 설정(`server.forward-headers-strategy`) 은 건드리지 않아도 됩니다. 헤더는 Traefik 에서 지웁니다.

### C (Terraform / AWS)
- ALB 보안그룹 → EKS 파드(노드) 보안그룹에 **TCP 8081 인바운드 허용**이 필요합니다. 없으면 헬스체크가 실패해 모든 대상이 unhealthy 가 됩니다.
- Prometheus 등으로 지표를 수집할 때 주소는 `<파드IP>:8081/actuator/prometheus` 입니다. (Service 8080 으로는 안 됨)

### 운영 `/api` 제거 위치를 정할 때 (팀 미정 항목)
- `/api` 를 떼는 곳(CloudFront Function, gateway 설정 등)이 `X-Forwarded-Prefix` 를 붙이면 **같은 404** 가 납니다. 결정할 때 함께 확인이 필요합니다.

### 프론트
- 변경 없음. `/api/...` 그대로 사용합니다.

## 5. 로컬 사용법 변경
- HPA 부하 테스트에 API 경로가 필수가 됐습니다 (actuator 는 Service 로 접근 불가):
  ```bash
  make hpa-test SVC=store LOAD_PATH=stores
  ```
- Docker Desktop(WSL) 환경에서는 `make tunnel` 대신 아래로 Ingress 를 확인할 수 있습니다 (sudo 불필요):
  ```bash
  kubectl --context baedalsak -n traefik port-forward svc/traefik 18080:80
  curl -i http://localhost:18080/api/stores
  ```

## 6. 참고: 배포 직후 HPA 경고
- 새 파드가 뜬 직후 1~2분 동안 `FailedGetResourceMetric` (`did not receive metrics for targeted pods`) 경고가 보일 수 있습니다.
- metrics-server 가 새 파드의 CPU 를 아직 수집하지 못한 상태라 정상입니다. 그동안 HPA 는 개수를 바꾸지 않고 유지합니다. (로컬 측정: Ready 후 약 90초 만에 해소)

## 바뀐 파일 (baedalsak-infra)
- `helm/charts/baedalsak-service/templates/middleware.yaml`, `ingress.yaml`, `_helpers.tpl` — 문제 1
- `helm/charts/baedalsak-service/values.yaml`, `templates/deployment.yaml`, `templates/configmap.yaml` — 문제 2
- `helm/values/aws.yaml` — ALB 헬스체크 포트
- `scripts/hpa-load.sh`, `Makefile`, `README.md` — 부하 경로 필수화, 문서
