#!/usr/bin/env bash
# =============================================================================
# EKS 애드온 설치 (helm) — terraform ephemeral apply 직후, 앱 배포 전에 실행
#   LBC(replica 1) · Cluster Autoscaler · ESO(controller만) · metrics-server · Loki · Fluent Bit(→ Loki) · Prometheus·Grafana(monitoring)
#   · Argo CD(argocd, 앱 6개 배포)
#   권한은 Terraform 이 만든 Pod Identity 연결을 그대로 사용 (SA 이름이 같아야 함)
# 필요: aws cli, kubectl(kubeconfig 설정 완료), helm
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/aws/env.sh
source "$(dirname "$0")/env.sh"
REGION="$AWS_REGION"
CLUSTER="$CLUSTER_NAME"
VPC_ID="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null
helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null # Tempo 차트 이전처 (grafana/tempo 는 지원 종료)
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

echo "== AWS Load Balancer Controller"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set replicaCount=1 \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 10m

echo "== Cluster Autoscaler"
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER" \
  --set awsRegion="$REGION" \
  --set rbac.serviceAccount.create=true \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set extraArgs.scale-down-unneeded-time=10m \
  --set extraArgs.scale-down-utilization-threshold=0.5 \
  --set extraArgs.expander=least-waste \
  --set extraArgs.skip-nodes-with-local-storage=false \
  --wait --timeout 10m

echo "== External Secrets Operator (controller만)"
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true \
  --set replicaCount=1 \
  --set webhook.create=false \
  --set certController.create=false \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-secrets \
  --wait --timeout 10m

# 권한은 controller 파드의 Pod Identity (auth 블록 없음 → SDK 기본 자격 증명)
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${REGION}
---
# SSM 파라미터 (앱 차트 externalSecretSsm — 예 Cognito 풀 ID). 권한은 같은 controller Pod Identity
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-parameter-store
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${REGION}
EOF

echo "== metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait --timeout 10m

# Fluent Bit 보다 먼저 — 수집기가 뜨자마자 보낼 곳이 있게
echo "== Loki (monitoring) — 앱 로그 저장소, S3 14일"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
LOKI_BUCKET="$(ssm loki_bucket)"
helm upgrade --install loki grafana/loki \
  -n monitoring --version 7.3.0 \
  -f "$(dirname "$0")/../../helm/addons/loki.yaml" \
  --set-string loki.storage.bucketNames.chunks="$LOKI_BUCKET" \
  --set-string loki.storage.bucketNames.ruler="$LOKI_BUCKET" \
  --set-string loki.storage.bucketNames.admin="$LOKI_BUCKET" \
  --set-string loki.storage.s3.region="$REGION" \
  --wait --timeout 10m

echo "== Tempo (monitoring) — 추적 저장소, S3 14일"
TEMPO_BUCKET="$(ssm tempo_bucket)"
helm upgrade --install tempo grafana-community/tempo \
  -n monitoring --version 3.2.1 \
  -f "$(dirname "$0")/../../helm/addons/tempo.yaml" \
  --set-string tempo.storage.trace.s3.bucket="$TEMPO_BUCKET" \
  --set-string tempo.storage.trace.s3.endpoint="s3.${REGION}.amazonaws.com" \
  --wait --timeout 10m

echo "== Fluent Bit → Loki"
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  -n kube-system \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-for-fluent-bit \
  -f "$(dirname "$0")/../../helm/addons/aws-for-fluent-bit.yaml" \
  --wait --timeout 10m

echo "== Prometheus·Grafana (monitoring) — 디스크 없음, /grafana 경로로 노출(ALB Cognito 인증)"
# Grafana admin: Secrets Manager <SECRET_PREFIX>/grafana → Secret grafana-admin (values 에 비밀번호 없음)
# Grafana OAuth: Secrets Manager <SECRET_PREFIX>/ops-cognito-grafana → Secret grafana-oauth (키 이름 = GF_* 환경 변수)
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: grafana-admin
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: ${SECRET_PREFIX}/grafana
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-oauth
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: grafana-oauth
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: ${SECRET_PREFIX}/ops-cognito-grafana
EOF
kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-admin externalsecret/grafana-oauth --timeout=3m
# 직접 관리하는 대시보드 (비용 추정 · Spring Boot Observability 수정본 · Argo CD 공식 대시보드 v3.5.5 examples/dashboard.json)
#   — Grafana sidecar 가 grafana_dashboard=1 ConfigMap 을 읽음
for d in baedalsak-cost spring-boot-observability argocd; do
  kubectl -n monitoring create configmap "dashboard-$d" \
    --from-file="$(dirname "$0")/../../helm/addons/dashboards/$d.json" --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
done
OPS_HOSTED_UI="$(ssm ops_cognito_hosted_ui)"
# 메이저 버전마다 값 구조가 바뀌어 버전 고정 — 올릴 땐 helm template 로 먼저 확인
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.14.0 \
  -f "$(dirname "$0")/../../helm/addons/kube-prometheus-stack.yaml" \
  --set-string grafana.env.AWS_REGION="$REGION" \
  --set-string grafana.env.ALERTS_TOPIC_ARN="$(ssm alerts_topic_arn)" \
  --set-string grafana.env.GF_SERVER_ROOT_URL="$(ssm grafana_root_url)" \
  --set-string grafana.env.GF_AUTH_GENERIC_OAUTH_AUTH_URL="$OPS_HOSTED_UI/oauth2/authorize" \
  --set-string grafana.env.GF_AUTH_GENERIC_OAUTH_TOKEN_URL="$OPS_HOSTED_UI/oauth2/token" \
  --set-string grafana.env.GF_AUTH_GENERIC_OAUTH_API_URL="$OPS_HOSTED_UI/oauth2/userInfo" \
  --set-string grafana.env.GF_AUTH_SIGNOUT_REDIRECT_URL="$(ssm grafana_signout_url)" \
  --wait --timeout 10m

# ALB → Grafana 파드 IP 등록 (대상 그룹은 terraform/ephemeral/alb.tf, gateway 는 앱 차트)
kubectl apply -f - <<EOF
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: grafana
  namespace: monitoring
spec:
  serviceRef:
    name: monitoring-grafana
    port: 80
  targetGroupARN: "$(ssm grafana_target_group_arn)"
  targetType: ip
EOF

# ALB 서브넷 → Grafana 3000. ALB 는 파드와 같은 서브넷이라 이 대역의 파드도 함께 허용됨
ALB_CIDRS="$(ssm alb_subnet_cidrs)"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: grafana-alb
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: monitoring
      app.kubernetes.io/name: grafana
  policyTypes: [Ingress]
  ingress:
    - from:
$(for cidr in ${ALB_CIDRS//,/ }; do echo "        - ipBlock: { cidr: $cidr }"; done)
      ports:
        - { port: 3000, protocol: TCP }
EOF

# 앱 6개 GitOps 배포 — ApplicationSet 은 deploy.sh 가 적용 (db-init · Cognito 정리 뒤)
#   메이저 버전마다 값 구조가 바뀌어 버전 고정 — 올릴 땐 helm show values 로 키를 먼저 확인
echo "== Argo CD (argocd) — 단일 구성, UI 는 port-forward 전용 (scripts/aws/argocd-ui.sh)"
# 앱 화면의 Grafana 링크 (딥링크) — 도메인이 들어가 Git 이 아니라 SSM grafana_root_url(https://<도메인>/grafana/)에서 채움
#   서비스 대시보드 = Spring Boot Observability(uid dLsDQIUnzb, 변수 app_name) · Argo CD 대시보드(uid LCAgc9rWz)
GRAFANA_URL="$(ssm grafana_root_url)"
ARGOCD_LINKS="$(mktemp)"
cat > "$ARGOCD_LINKS" <<LINKS
configs:
  cm:
    application.links: |
      - url: ${GRAFANA_URL}d/dLsDQIUnzb?var-app_name={{.metadata.name}}
        title: Grafana 서비스 대시보드
        description: 지표 · 로그 (운영자 로그인)
      - url: ${GRAFANA_URL}d/LCAgc9rWz
        title: Grafana Argo CD 대시보드
LINKS
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace --version 10.10.5 \
  -f "$(dirname "$0")/../../helm/argocd/values.yaml" \
  -f "$ARGOCD_LINKS" \
  --wait --timeout 10m
rm -f "$ARGOCD_LINKS"

# argocd 네임스페이스 ingress 기본 차단 + 필요한 연결만 허용 — Grafana 와 같은 수준 (차트 정책은 끔: helm/argocd/values.yaml)
#   포트는 숫자로 — EKS VPC CNI 네트워크 정책은 이름 붙은 포트를 쓰면 Service 에도 같은 이름이어야 하는데 차트 Service 이름이 다름
#   repo-server 8081 ← server · controller · applicationset / redis 6379 ← server · repo-server · controller
#   메트릭 controller 8082 · server 8083 · repo-server 8084 ← monitoring(Prometheus)
#   server 8080(UI·API)은 아무 데서도 허용 안 함 → 다른 파드가 로그인 API 에 직접 못 들어옴. UI 는 port-forward(정책 대상 아님)
#   applicationset-controller 는 들어오는 연결이 필요 없어 기본 차단만 받음
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: argocd-default-deny, namespace: argocd }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: argocd-repo-server, namespace: argocd }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: argocd-repo-server } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app.kubernetes.io/name: argocd-server } }
        - podSelector: { matchLabels: { app.kubernetes.io/name: argocd-application-controller } }
        - podSelector: { matchLabels: { app.kubernetes.io/name: argocd-applicationset-controller } }
      ports:
        - { port: 8081, protocol: TCP }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: argocd-redis, namespace: argocd }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: argocd-redis } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app.kubernetes.io/name: argocd-server } }
        - podSelector: { matchLabels: { app.kubernetes.io/name: argocd-repo-server } }
        - podSelector: { matchLabels: { app.kubernetes.io/name: argocd-application-controller } }
      ports:
        - { port: 6379, protocol: TCP }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: argocd-metrics, namespace: argocd }
spec:
  podSelector:
    matchExpressions:
      - { key: app.kubernetes.io/name, operator: In, values: [argocd-application-controller, argocd-server, argocd-repo-server] }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
      ports:
        - { port: 8082, protocol: TCP }
        - { port: 8083, protocol: TCP }
        - { port: 8084, protocol: TCP }
EOF

kubectl get pods -n kube-system
kubectl get pods -n external-secrets
kubectl get pods -n monitoring
kubectl get pods -n argocd
