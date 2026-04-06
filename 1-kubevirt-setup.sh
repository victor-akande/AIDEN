#!/bin/bash
set -e

echo "=========================================================="
echo "⚙️  Phase 2: Provisioning KubeVirt & Image Tooling..."
echo "=========================================================="

# Resolve the latest KubeVirt release tag if not already provided.
if [ -z "${KUBEVIRT_VERSION}" ]; then
  echo "[1/5] Resolving latest KubeVirt release tag..."
  KUBEVIRT_VERSION=$(curl -fsSL https://api.github.com/repos/kubevirt/kubevirt/releases/latest \
    | grep -Eo '"tag_name":\s*"[^"]+"' \
    | head -n1 \
    | cut -d'"' -f4)
  if [ -z "${KUBEVIRT_VERSION}" ]; then
    echo "Failed to determine the latest KubeVirt release tag." >&2
    exit 1
  fi
  export KUBEVIRT_VERSION
fi

echo "[2/5] Deploying KubeVirt Operator..."
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

echo "[3/5] Deploying KubeVirt Custom Resources..."
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

echo "[4/5] Installing virtctl CLI tool..."
curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
chmod +x virtctl
sudo mv virtctl /usr/local/bin/

echo "[5/5] Pulling the custom Windows image directly into Containerd..."
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
