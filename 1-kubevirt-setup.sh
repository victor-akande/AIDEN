#!/bin/bash
set -e

echo "=========================================================="
echo "⚙️  Phase 2: Provisioning KubeVirt & Image Tooling..."
echo "=========================================================="

AIDEN_IMAGE="docker.io/victhedev/aiden:latest"
AIDEN_STATE_DIR=/var/lib/aiden-lab
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

# Remember binaries we installed so 3-teardown.sh removes only those
aiden_record_bin() {
  sudo mkdir -p "$AIDEN_STATE_DIR"
  grep -qxF "$1" "$AIDEN_STATE_DIR/installed-bins" 2>/dev/null \
    || echo "$1" | sudo tee -a "$AIDEN_STATE_DIR/installed-bins" >/dev/null
}

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

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)

# Resolve the latest KubeVirt release tag if not already provided.
if [ -z "${KUBEVIRT_VERSION}" ]; then
  echo "[1/7] Resolving latest KubeVirt release tag..."
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

echo "[2/7] Deploying KubeVirt Operator..."
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

echo "[3/7] Deploying KubeVirt Custom Resources..."
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

if [ "${KUBEVIRT_USE_EMULATION}" = "true" ]; then
  echo "   -> Enabling software emulation (useEmulation: true)..."
  kubectl patch kubevirt kubevirt -n kubevirt --type merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
fi

echo "[4/7] Installing virtctl CLI tool..."
curl -fL -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
chmod +x virtctl
sudo mv virtctl /usr/local/bin/

echo "[5/7] Pulling the AIDEN Lab image from Docker Hub into Containerd (seed node)..."
# KubeVirt running on modern K8s uses containerd.
# We must pull into the 'k8s.io' namespace so KubeVirt can see the disk image.
# This is the ONLY pull that goes to Docker Hub; other nodes fetch it from peers.
sudo ctr -n k8s.io images pull "$AIDEN_IMAGE"

echo "----------------------------------------------------------"
echo "⏳ Waiting for KubeVirt components to become ready..."
echo "----------------------------------------------------------"
kubectl wait -n kubevirt deployment virt-operator --for=condition=Available --timeout=300s
kubectl wait -n kubevirt deployment virt-api --for=condition=Available --timeout=300s
kubectl wait -n kubevirt deployment virt-controller --for=condition=Available --timeout=300s

if [ "$NODE_COUNT" -gt 1 ]; then
  # ==========================================================
  # P2P image distribution with Spegel
  # Every node runs a Spegel agent that serves the images in its local
  # containerd store to the other nodes. containerd is configured (via
  # /etc/containerd/certs.d, written by Spegel) to ask peers first and only
  # fall back to Docker Hub when no node has the layer. Nodes that finish
  # downloading immediately become sources for the rest.
  # ==========================================================
  echo "[6/7] Installing Spegel (peer-to-peer image distribution, $NODE_COUNT nodes)..."
  if ! command -v helm >/dev/null 2>&1; then
    HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest \
      | grep -Eo '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)
    if [ -z "$HELM_VERSION" ]; then
      echo "Failed to determine the latest Helm release." >&2
      exit 1
    fi
    echo "   -> Installing helm ${HELM_VERSION}..."
    HELM_TMP=$(mktemp -d)
    (
      cd "$HELM_TMP"
      curl -fsSL -O "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
      curl -fsSL -O "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
      sha256sum --check --quiet "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
      tar xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
      sudo mv linux-amd64/helm /usr/local/bin/helm
    )
    rm -rf "$HELM_TMP"
    aiden_record_bin /usr/local/bin/helm
  fi

  # SPEGEL_VERSION can pin the chart version (e.g. 0.8.1); default is latest.
  helm upgrade --install spegel oci://ghcr.io/spegel-org/helm-charts/spegel \
    ${SPEGEL_VERSION:+--version "$SPEGEL_VERSION"} \
    --namespace spegel --create-namespace \
    --set spegel.containerdRegistryConfigPath=/etc/containerd/certs.d \
    --wait --timeout 10m

  echo "[7/7] Pre-warming the AIDEN Lab image on all nodes over the node network..."
  # A throwaway DaemonSet references the image on every node, which makes each
  # kubelet pull it through containerd -> Spegel -> peers. The image has no
  # shell, so a static busybox is copied in to give the container something
  # trivial to run. Once every pod is Ready the image is cached everywhere.
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: aiden-image-prewarm
  namespace: kube-system
  labels:
    app: aiden-image-prewarm
spec:
  selector:
    matchLabels:
      app: aiden-image-prewarm
  template:
    metadata:
      labels:
        app: aiden-image-prewarm
    spec:
      tolerations:
      - operator: Exists
      terminationGracePeriodSeconds: 0
      initContainers:
      - name: tools
        image: docker.io/library/busybox:1.36.1-musl
        command: ["cp", "/bin/busybox", "/tools/busybox"]
        volumeMounts:
        - name: tools
          mountPath: /tools
      - name: pull-aiden-image
        image: ${AIDEN_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/tools/busybox", "true"]
        volumeMounts:
        - name: tools
          mountPath: /tools
      containers:
      - name: done
        image: registry.k8s.io/pause:3.10
      volumes:
      - name: tools
        emptyDir: {}
EOF
  # Large disk images can take a while even over the LAN
  kubectl rollout status daemonset/aiden-image-prewarm -n kube-system --timeout=60m
  kubectl delete daemonset aiden-image-prewarm -n kube-system --wait=false
else
  echo "[6/7] Single node — skipping Spegel (no peers to distribute to)."
  echo "[7/7] Image already cached locally."
fi

echo "=========================================================="
echo "✅ Phase 2 Complete!"
if [ "$NODE_COUNT" -gt 1 ]; then
  echo "KubeVirt is active, virtctl is installed, and your custom image is cached"
  echo "on all $NODE_COUNT nodes (distributed peer-to-peer by Spegel)."
else
  echo "KubeVirt is active, virtctl is installed, and your custom image is cached."
fi
if [ "${KUBEVIRT_USE_EMULATION}" = "true" ]; then
  echo "Note: software emulation is enabled — expect reduced VM performance."
fi
echo "=========================================================="
