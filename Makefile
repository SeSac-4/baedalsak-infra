# =============================================================================
# 배달싹 로컬 K8s (minikube 1노드)                          [백엔드 B · 4단계]
#
#   Windows: WSL2 또는 Git Bash(+ make) 에서 실행
#   전제   : baedalsak-server 의 docker compose 의존성이 실행 중 (docker compose up -d)
#
#   make up                         minikube + metrics-server + Traefik + namespace + Secret
#   make tunnel                     (별도 터미널) http://localhost → Traefik
#   make infra-check                파드 → compose 의존성 연결 확인
#   make dep-host                   파드에서 되는 의존성 주소 찾기 → export DEP_HOST=<주소>
#   make dev SVC=store              compose 로 빌드 → minikube 에 load → 배포
#   make dev SVC=store PLATFORM=linux/arm64   이미지 아키텍처 지정 (기본: PC 와 같음)
#   make dev-all                    6개 전체
#   make hpa-test SVC=store LOAD_PATH=v1/stores   부하 → HPA 확장 확인
# =============================================================================
SHELL := /bin/bash

SERVICES   := gateway store order payment delivery member
PROFILE    := baedalsak                 # minikube 프로필 = kube context 이름
NS         := baedalsak
CHART      := helm/charts/baedalsak-service
SECRET     := baedalsak-local

# baedalsak-server 저장소 위치 (compose.yaml, .env)
SERVER_DIR ?= ../baedalsak-server
ENV_FILE   ?= $(SERVER_DIR)/.env

# minikube 자원 — 6개 서비스(512Mi) + Traefik + 시스템 기준
CPUS       ?= 4
MEMORY     ?= 6g
# 쿠버네티스 버전: EKS 버전이 정해지면 여기에 고정 (예: v1.33.5). 비우면 minikube 기본값
K8S_VERSION ?=

# 파드 → compose 의존성(postgres·rabbitmq·redis-session) 주소  (DynamoDB 주석 처리)
#   비우면 helm/values/local.yaml 의 host.minikube.internal 사용 (팀 기본값)
#   PC 환경에 따라 연결이 안 되면: make dep-host 로 되는 주소 확인 → export DEP_HOST=<주소>
DEP_HOST   ?=

SVC        ?=
# 이미지 아키텍처 (linux/amd64 | linux/arm64). 비우면 PC 와 같은 아키텍처
#   minikube(docker 드라이버) 노드는 PC 와 같은 아키텍처라 보통 비워 둠. load 할 때 노드와 다르면 멈춤
PLATFORM   ?=
DEFAULT_TAG := local-$(shell date +%Y%m%d%H%M%S)
TAG        ?= $(DEFAULT_TAG)

PROFILE  := $(strip $(PROFILE))
NS       := $(strip $(NS))
DEP_HOST := $(strip $(DEP_HOST))
K    := kubectl --context $(PROFILE) -n $(NS)
HELM := helm --kube-context $(PROFILE) -n $(NS)
VALUES_LOCAL = -f helm/values/services/$(SVC).yaml -f helm/values/local.yaml \
  $(if $(DEP_HOST),--set global.db.host=$(DEP_HOST) --set global.rabbitmq.host=$(DEP_HOST) \
    --set global.redisSession.host=$(DEP_HOST))
  # DynamoDB 주석 처리: --set global.dynamodb.endpoint=http://$(DEP_HOST):8000

.PHONY: need-svc up down delete tunnel secret infra-check dep-host build load deploy dev dev-all \
        restart uninstall status logs hpa-test lint template-aws

need-svc:
	@test -n "$(SVC)" || { echo "SVC=<서비스> 를 지정하세요 ($(SERVICES))"; exit 1; }

# -----------------------------------------------------------------------------
# 클러스터
# -----------------------------------------------------------------------------
up:
	minikube start -p $(PROFILE) --driver=docker --cpus=$(CPUS) --memory=$(MEMORY) \
	  $(if $(K8S_VERSION),--kubernetes-version=$(K8S_VERSION))
	minikube -p $(PROFILE) addons enable metrics-server
	helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
	helm repo update traefik >/dev/null
	helm --kube-context $(PROFILE) upgrade --install traefik traefik/traefik --version 41.7.1 \
	  -n traefik --create-namespace -f local/traefik-values.yaml
	@# helm --wait 은 LoadBalancer 의 EXTERNAL-IP 까지 기다리는데, 이 IP 는 make tunnel 을 켠 뒤에야 생김 → 파드만 확인
	kubectl --context $(PROFILE) -n traefik rollout status deployment/traefik --timeout=5m
	kubectl --context $(PROFILE) create namespace $(NS) --dry-run=client -o yaml | kubectl --context $(PROFILE) apply -f -
	$(MAKE) secret
	@echo "✔ 준비 완료. 다른 터미널에서 'make tunnel' 을 켜 두면 http://localhost/api/... 로 접속됩니다."

down:
	minikube stop -p $(PROFILE)

delete:
	minikube delete -p $(PROFILE)

# Traefik(LoadBalancer) 를 localhost:80 으로 연결 — 켜 둔 상태로 사용 (관리자 암호를 물을 수 있음)
tunnel:
	minikube tunnel -p $(PROFILE)

# 각자의 .env 에서 필요한 키만 골라 Secret 생성 (compose 와 항상 같은 값)
SECRET_KEYS := DB_PASSWORD RABBITMQ_USER RABBITMQ_PASSWORD REDIS_SESSION_PASSWORD JWT_SECRET TOSS_SECRET_KEY
SPACE := $(subst ,, )
secret:
	@test -f "$(ENV_FILE)" || { echo "$(ENV_FILE) 가 없습니다. baedalsak-server 에서 cp .env.example .env"; exit 1; }
	@tmp=$$(mktemp); \
	  tr -d '\r' < "$(ENV_FILE)" | grep -E '^($(subst $(SPACE),|,$(SECRET_KEYS)))=' > "$$tmp"; \
	  n=$$(wc -l < "$$tmp"); \
	  if [ "$$n" -ne $(words $(SECRET_KEYS)) ]; then echo ".env 에 $(SECRET_KEYS) 가 모두 있어야 합니다 (JWT_SECRET·TOSS_SECRET_KEY 는 .env.example 참고)"; rm -f "$$tmp"; exit 1; fi; \
	  kubectl --context $(PROFILE) -n $(NS) create secret generic $(SECRET) --from-env-file="$$tmp" \
	    --dry-run=client -o yaml | kubectl --context $(PROFILE) -n $(NS) apply -f -; \
	  rm -f "$$tmp"
	@echo "※ 이미 떠 있는 파드에 반영하려면: make restart"

# 파드 → DEP_HOST(기본 host.minikube.internal) → compose 포트
infra-check:
	@echo "▶ 의존성 주소: $(or $(DEP_HOST),host.minikube.internal)"
	$(K) run infra-check --rm -i --restart=Never --image=busybox:1.36 -- sh -c '\
	  h=$(or $(DEP_HOST),host.minikube.internal); \
	  for t in 5432:postgres 5672:rabbitmq 6379:redis-session; do \
	    p=$${t%%:*}; n=$${t#*:}; \
	    if nc -z -w 3 $$h $$p; then echo "OK    $$n ($$p)"; else echo "FAIL  $$n ($$p)"; fi; \
	  done'

# 파드에서 접속 가능한 의존성 주소 후보를 확인 → 3개 모두 OK 인 주소를 DEP_HOST 로 사용
dep-host:
	@gw=$$(docker network inspect $(PROFILE) --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null); \
	  $(K) run dep-host --rm -i --restart=Never --image=busybox:1.36 -- sh -c "\
	    for h in host.minikube.internal host.docker.internal $$gw; do \
	      ip=\$$(nslookup \$$h 2>/dev/null | awk '/^Name:/ {f=1} f && /^Address/ {print \$$2; exit}'); \
	      ok=0; for p in 5432 5672 6379; do nc -z -w 3 \$$h \$$p 2>/dev/null && ok=\$$((ok+1)); done; \
	      printf '%-24s %-16s %s/3 OK\n' \$$h \"\$${ip:--}\" \$$ok; \
	    done"
	@echo "※ 3/3 인 주소를 쓰세요. host.minikube.internal 이 3/3 이면 DEP_HOST 는 비워 둡니다."
	@echo "  예) export DEP_HOST=host.docker.internal   (터미널 시작 시 경로 변수와 함께)"

# -----------------------------------------------------------------------------
# 배포 — 로컬 빌드 이미지 (compose 가 만드는 baedalsak/<서비스>:local)
#   같은 태그를 재사용하면 파드가 교체되지 않으므로 local-<시각> 태그를 새로 붙여 load
# -----------------------------------------------------------------------------
build: need-svc
	$(if $(PLATFORM),DOCKER_DEFAULT_PLATFORM=$(PLATFORM)) docker compose -f $(SERVER_DIR)/compose.yaml --project-directory $(SERVER_DIR) --profile apps build $(SVC)

load: need-svc
	@img=$$(docker image inspect baedalsak/$(SVC):local --format '{{.Architecture}}'); \
	  node=$$(kubectl --context $(PROFILE) get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'); \
	  [ "$$img" = "$$node" ] || { echo "이미지($$img)와 minikube 노드($$node) 아키텍처가 다릅니다. PLATFORM=linux/$$node 로 다시 빌드하세요"; exit 1; }
	docker tag baedalsak/$(SVC):local baedalsak/$(SVC):$(TAG)
	minikube -p $(PROFILE) image load baedalsak/$(SVC):$(TAG)

deploy: need-svc
	@test "$(origin TAG)" = "command line" || { echo "TAG 를 지정하세요 (로컬 빌드는 make dev)"; exit 1; }
	$(HELM) upgrade --install $(SVC) $(CHART) $(VALUES_LOCAL) --set image.tag=$(TAG) --wait --timeout 10m

dev: build load
	$(MAKE) deploy SVC=$(SVC) TAG=$(TAG)

dev-all:
	@for s in $(SERVICES); do $(MAKE) dev SVC=$$s TAG=$(TAG) || exit 1; done

# -----------------------------------------------------------------------------
# 확인·정리
# -----------------------------------------------------------------------------
restart:
	$(K) rollout restart deployment

uninstall: need-svc
	$(HELM) uninstall $(SVC)

status:
	$(K) get pods -o wide
	$(K) get hpa,ingress,svc

logs: need-svc
	$(K) logs -l app.kubernetes.io/name=$(SVC) -f --max-log-requests 10

hpa-test: need-svc
	@test -n "$(LOAD_PATH)" || { echo "LOAD_PATH=<API 경로> 를 지정하세요 (예: v1/stores). actuator 는 8081 이라 부하 대상이 아님"; exit 1; }
	CTX=$(PROFILE) NS=$(NS) ./scripts/hpa-load.sh $(SVC) $(LOAD_PATH)

lint:
	@for s in $(SERVICES); do \
	  helm lint $(CHART) -f helm/values/services/$$s.yaml -f helm/values/local.yaml --set image.tag=lint >/dev/null \
	    && echo "ok   $$s (local)" || { echo "FAIL $$s (local)"; exit 1; }; \
	done

# AWS 빈칸 템플릿이 렌더링되는지만 확인 (배포하지 않음)
template-aws: need-svc
	helm template $(SVC) $(CHART) -n $(NS) -f helm/values/services/$(SVC).yaml -f helm/values/aws.yaml --set image.tag=sha-example
