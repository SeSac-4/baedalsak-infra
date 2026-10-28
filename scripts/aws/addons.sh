#!/usr/bin/env bash
# =============================================================================
# EKS 애드온 설치 (helm) — terraform ephemeral apply 직후, 앱 배포 전에 실행
#   LBC(replica 1) · Cluster Autoscaler · ESO(controller만) · metrics-server · Loki · Fluent Bit(→ Loki) · Prometheus·Grafana(monitoring)
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

echo "== Fluent Bit → Loki"
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  -n kube-system \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-for-fluent-bit \
  -f "$(dirname "$0")/../../helm/addons/aws-for-fluent-bit.yaml" \
  --wait --timeout 10m

echo "== Prometheus·Grafana (monitoring) — 디스크 없음, 외부 노출 없음"
# Grafana admin: Secrets Manager <SECRET_PREFIX>/grafana → Secret grafana-admin (values 에 비밀번호 없음)
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
EOF
kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-admin --timeout=3m
# 메이저 버전마다 값 구조가 바뀌어 버전 고정 — 올릴 땐 helm template 로 먼저 확인
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.14.0 \
  -f "$(dirname "$0")/../../helm/addons/kube-prometheus-stack.yaml" \
  --wait --timeout 10m

kubectl get pods -n kube-system
kubectl get pods -n external-secrets
kubectl get pods -n monitoring
