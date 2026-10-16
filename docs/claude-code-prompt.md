# Claude Code 작업 프롬프트

## 0. 준비 (사람이 직접)

Claude Code 의 보호 설정(`.claude/settings.json`, 훅, `CLAUDE.md`)은 **세션을 시작할 때** 읽힙니다.
그래서 zip 은 **사람이 먼저 풀고**, 그 다음에 Claude Code 를 실행합니다.
(Claude Code 에게 zip 을 풀게 하면, 푸는 동안에는 보호 설정이 아직 적용되지 않습니다.)

```
작업폴더/
├── baedalsak-server/     # 백엔드 A 저장소 (compose.yaml, .env 가 있는 곳)
└── baedalsak-infra/      # ← baedalsak-infra.zip 을 여기에 풀기
```

1. `baedalsak-infra.zip` 을 `baedalsak-server` 와 **같은 폴더**에 풉니다.
2. `baedalsak-infra` 폴더에서 옆 저장소를 함께 열어 Claude Code 를 시작합니다.
   ```bash
   cd baedalsak-infra
   claude --add-dir ../baedalsak-server
   ```
   처음에는 계획 모드(Shift+Tab 으로 전환)로 시작해 계획을 먼저 확인하는 것을 권장합니다.
   - Claude Code 실행 후 `/permissions` 로 deny·ask 규칙이 보이는지, `/hooks` 로 훅이 등록됐는지 확인합니다.
3. Windows 는 WSL2 또는 Git Bash 에서 실행합니다 (Makefile·훅이 bash 기준).

---

## 1. 붙여 넣을 프롬프트

아래 블록을 그대로 붙여 넣습니다. 한 번에 끝까지 가지 않고 **단계마다 멈춰 보고**하도록 되어 있습니다.

```text
너는 배달싹 프로젝트의 로컬 K8s(minikube) 배포 설정을 검증하는 역할이야.
먼저 CLAUDE.md 와 README.md 를 읽고, 작업 원칙과 "절대 바꾸지 않는 것" 표를 지켜.
옆 저장소 ../baedalsak-server 의 compose.yaml, Dockerfile, .env.example, docs/backend-infra-rules.md 는 읽기만 해.

목표: 이 저장소(helm 차트, values, Makefile)가 내 PC 의 minikube 에서 실제로 동작하는지 단계별로 확인하고, 문제를 보고하는 것.
결정값을 바꾸는 것은 목표가 아니야. 정해지지 않은 것은 추측하지 말고 물어봐.

단계마다 CLAUDE.md 의 "보고 형식"으로 보고하고, 내가 승인하기 전에는 다음 단계로 가지 마.

[단계 1 — 사전 점검 (읽기만)]
- docker, minikube, kubectl, helm, make 설치 여부와 버전 확인
- ../baedalsak-server 존재 여부, compose.yaml 과 .env.example 의 환경 변수 이름이
  helm/charts/baedalsak-service/templates/configmap.yaml·deployment.yaml 이 주입하는 이름과 일치하는지 대조
  (.env 파일 자체는 읽지 마. .env.example 로만 대조해)
- ../baedalsak-server 에 서비스 모듈(gateway, store, ...)과 각 build.gradle 이 있는지 확인
  → 없으면 단계 4·5 는 진행할 수 없다고 보고

[단계 2 — 정적 검증 (클러스터 없이)]
- make lint
- 7개 서비스 각각 helm template (local) 렌더링, make template-aws SVC=<서비스> 렌더링
- 렌더링 결과에서 확인: 환경 변수 이름·값, DB 계정·schema, 세션 Redis 주입 대상(gateway·user 만),
  probe 경로·주기, HPA min/max/목표, UID 1001, Service 포트 8080, Ingress + Traefik Middleware(/api 제거)
- CLAUDE.md 결정값 표와 하나라도 다르면 ❌ 로 표시

[단계 3 — 클러스터 준비 (내 승인 후)]
- ../baedalsak-server 에서 compose 의존성이 떠 있는지 확인 (docker compose ps). 안 떠 있으면 나에게 띄워 달라고 요청
- make up → kubectl top nodes 로 metrics-server 동작 확인 → make infra-check
- make tunnel 은 별도 터미널이 필요하니 나에게 실행을 요청

[단계 4 — 배포 (서비스 모듈이 있을 때만, 내 승인 후)]
- make dev SVC=gateway 와 서비스 1개(store 등)부터 배포, 나머지는 내가 승인하면 진행
- 파드 상태, 이벤트(kubectl describe), 로그로 probe 통과 여부 확인

[단계 5 — 동작 검증]
- Ingress: curl -i http://localhost/api/<경로> 로 gateway 응답, /actuator 가 외부에서 안 보이는지
- /api 제거: gateway 로그에서 요청 경로가 /api 없이 들어오는지
- probe: 재시작 없이 Ready 되는지, readiness 실패 시 endpoints 에서 빠지는지
- HPA: make hpa-test SVC=store 실행 중 kubectl get hpa 로 확장·축소 관찰
- 무중단: 부하 중 재배포(make dev SVC=store) 시 실패 응답 여부

수정이 필요해 보이면:
- helm/values/**, local/traefik-values.yaml, CLAUDE.md, .claude/**, ../baedalsak-server/** 는 수정 불가. 바꿀 값과 이유만 보고해.
- helm/charts/**, Makefile, scripts/** 는 버그 수정일 때만. 수정 전에 원인·바꿀 줄·결정값 영향 없음을 설명하고 내 승인을 받아.
- 막힌 파일을 다른 방법으로 바꾸려 하지 마. 훅이 막으면 그 사실을 보고해.
```

---

## 2. 상황별 짧은 프롬프트

| 상황 | 프롬프트 |
|---|---|
| 정적 검증만 | `CLAUDE.md 를 지켜서 위 프롬프트의 단계 1·2 만 진행하고 보고해. 클러스터 명령은 실행하지 마.` |
| 에러 원인 분석 | `make dev SVC=store 에서 아래 에러가 났어. 원인을 찾아 보고만 해. 파일 수정은 하지 마.` + 에러 붙여 넣기 |
| 새 서비스 모듈 추가 후 | `../baedalsak-server 에 <서비스> 모듈이 추가됐어. 단계 4·5 를 <서비스>에 대해서만 진행해.` |
| 결정 변경 반영 (사람이 values 를 고친 뒤) | `helm/values/local.yaml 의 <항목>을 내가 <값>으로 바꿨어. 단계 2 를 다시 해서 렌더링 결과를 확인해.` |

결정값을 바꿔야 할 때는 **사람이 직접** `helm/values/*` 를 수정하고, Claude Code 에게는 검증만 맡깁니다.
보호 대상을 바꾸려면 `.claude/settings.json` 의 deny/ask 와 `.claude/hooks/protect-decisions.sh` 의 `PROTECTED` 를 함께 수정합니다.
