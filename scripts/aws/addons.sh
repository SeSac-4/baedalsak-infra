#!/usr/bin/env bash
# =============================================================================
# EKS 애드온 설치 (helm) — terraform ephemeral apply 직후, 앱 배포 전에 실행
#   LBC(replica 1) · Cluster Autoscaler · ESO(controller만) · metrics-server · Fluent Bit
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
EOF

echo "== metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait --timeout 10m

echo "== Fluent Bit → CloudWatch Logs ${LOG_GROUP}"
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  -n kube-system \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-for-fluent-bit \
  --set cloudWatch.enabled=false \
  --set firehose.enabled=false \
  --set kinesis.enabled=false \
  --set elasticsearch.enabled=false \
  --set cloudWatchLogs.enabled=true \
  --set cloudWatchLogs.region="$REGION" \
  --set cloudWatchLogs.logGroupName="$LOG_GROUP" \
  --set cloudWatchLogs.autoCreateGroup=false \
  --wait --timeout 10m

kubectl get pods -n kube-system
kubectl get pods -n external-secrets
