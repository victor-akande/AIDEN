#!/bin/bash
set -e

echo "=========================================================="
echo "⚙️  Phase 2: Provisioning KubeVirt & Image Tooling..."
echo "=========================================================="

# Hardware virtualization check. Without /dev/kvm, KubeVirt VMs will not
# start unless software emulation is enabled (much slower, but works in
# nested/cloud environments without VT-x/AMD-V).
# Set KUBEVIRT_USE_EMULATION=true|false to skip the prompt.
if [ -z "${KUBEVIRT_USE_EMULATION}" ]; then
  if [ -e /dev/kvm ]; then
    KUBEVIRT_USE_EMULATION=false
  else
    echo -e "\e[33m⚠️  /dev/kvm not found on this host.\e[0m"
    echo "   Hardware virtualization appears unavailable (disabled in BIOS,"
    echo "   or nested virtualization is not enabled for this VM)."
    echo "   On multi-node clusters VMs run on the workers, so check /dev/kvm there too."
    read -p "Enable KubeVirt software emulation? [y/N]: " EMU_ANSWER
    case "$EMU_ANSWER" in
      [yY]*) KUBEVIRT_USE_EMULATION=true ;;
      *)     KUBEVIRT_USE_EMULATION=false ;;
    esac
  fi
fi

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

if [ "${KUBEVIRT_USE_EMULATION}" = "true" ]; then
  echo "   -> Enabling software emulation (useEmulation: true)..."
  kubectl patch kubevirt kubevirt -n kubevirt --type merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
fi

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
if [ "${KUBEVIRT_USE_EMULATION}" = "true" ]; then
  echo "Note: software emulation is enabled — expect reduced VM performance."
fi
echo "=========================================================="
