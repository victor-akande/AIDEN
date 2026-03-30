#!/bin/bash
set -e

echo "=========================================================="
echo "⚙️  Phase 2: Provisioning KubeVirt & Image Tooling..."
echo "=========================================================="

# We will use v1.4.0 as it aligns perfectly with your previous environment logs
export KUBEVIRT_VERSION="v1.4.0"

echo "[1/4] Deploying KubeVirt Operator..."
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

echo "[2/4] Deploying KubeVirt Custom Resources..."
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

echo "[3/4] Installing virtctl CLI tool..."
curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
chmod +x virtctl
sudo mv virtctl /usr/local/bin/

echo "[4/4] Pulling the custom Windows image directly into Containerd..."
# KubeVirt running on modern K8s uses containerd. 
# We must pull into the 'k8s.io' namespace so KubeVirt can see the disk image.
sudo ctr -n k8s.io images pull docker.io/victhedev/aiden:latest

echo "----------------------------------------------------------"
echo "⏳ Waiting for KubeVirt components to become ready..."
echo "----------------------------------------------------------"
kubectl wait -n kubevirt deployment virt-operator --for=condition=Available --timeout=300s
kubectl wait -n kubevirt deployment virt-api --for=condition=Available --timeout=300s
kubectl wait -n kubevirt deployment virt-controller --for=condition=Available --timeout=300s

echo "=========================================================="
echo "✅ Phase 2 Complete!"
echo "KubeVirt is active, virtctl is installed, and your custom image is cached."
echo "=========================================================="
