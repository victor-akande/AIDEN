# shellcheck shell=bash
# ==========================================================
# Shared Cilium helpers — sourced by 0-init-singlenode.sh and
# 0-init-multinode.sh. Not meant to be executed directly.
#
# Installs Cilium with:
#   - kube-proxy replacement (kubeadm must run with --skip-phases=addon/kube-proxy)
#   - BGP Control Plane (only when a BGP peer is given)
#   - L2 announcements + LB IPAM
#   - Hubble (relay + UI) and the hubble CLI
#
# Optional environment overrides:
#   CILIUM_VERSION   e.g. 1.20.4 (default: latest stable)
# ==========================================================

AIDEN_STATE_DIR=${AIDEN_STATE_DIR:-/var/lib/aiden-lab}

# Remember binaries we installed (not ones that already existed),
# so 3-teardown.sh removes only what we added.
aiden_record_bin() {
  mkdir -p "$AIDEN_STATE_DIR"
  grep -qxF "$1" "$AIDEN_STATE_DIR/installed-bins" 2>/dev/null || echo "$1" >> "$AIDEN_STATE_DIR/installed-bins"
}

aiden_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    *)             echo amd64 ;;
  esac
}

# Download <url>.tar.gz + .sha256sum, verify, and extract <binary> into /usr/local/bin
# Usage: aiden_install_tarball_bin <name> <base-url-without-.tar.gz>
aiden_install_tarball_bin() {
  local name=$1 base=$2 tmp
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    curl -fsSL --remote-name-all "${base}.tar.gz" "${base}.tar.gz.sha256sum"
    sha256sum --check --quiet "$(basename "$base").tar.gz.sha256sum"
    tar xzf "$(basename "$base").tar.gz" -C /usr/local/bin "$name"
  )
  rm -rf "$tmp"
  aiden_record_bin "/usr/local/bin/$name"
}

# Interactive prompts for the Cilium networking features.
# Sets: LB_POOL, BGP_PEER_IP, BGP_LOCAL_ASN, BGP_PEER_ASN
cilium_prompt() {
  echo ""
  echo -e "\e[33m--- 🐝 Cilium Networking (kube-proxy replacement, BGP, L2, Hubble) ---\e[0m"
  echo "LoadBalancer IPs are announced on the LAN via L2 (ARP) and, if a peer is set, via BGP."
  echo "Use free addresses on the node network that your DHCP server does not hand out."
  read -p "LoadBalancer IP pool (CIDR e.g. 10.0.0.240/28, or range 10.0.0.240-10.0.0.250) [skip]: " LB_POOL

  read -p "BGP peer (router) IP address [skip: L2-only, BGP off]: " BGP_PEER_IP
  if [ -n "$BGP_PEER_IP" ]; then
    read -p "Local (cluster) BGP ASN [65001]: " BGP_LOCAL_ASN
    BGP_LOCAL_ASN=${BGP_LOCAL_ASN:-65001}
    read -p "Peer (router) BGP ASN [65000]: " BGP_PEER_ASN
    BGP_PEER_ASN=${BGP_PEER_ASN:-65000}
  fi
}

# Storage API version of a CRD, e.g. "v2" or "v2alpha1"
cilium_crd_version() {
  kubectl get crd "$1" -o jsonpath='{.spec.versions[?(@.storage==true)].name}'
}

# Usage: cilium_install <api-server-ip> <operator-replicas>
cilium_install() {
  local api_ip=$1 operator_replicas=${2:-1} arch
  arch=$(aiden_arch)

  if ! command -v cilium >/dev/null 2>&1; then
    local cli_version
    cli_version=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    echo "   -> Installing cilium CLI ${cli_version}..."
    aiden_install_tarball_bin cilium \
      "https://github.com/cilium/cilium-cli/releases/download/${cli_version}/cilium-linux-${arch}"
  fi

  if ! command -v hubble >/dev/null 2>&1; then
    local hubble_version
    hubble_version=$(curl -fsSL https://raw.githubusercontent.com/cilium/hubble/main/stable.txt)
    echo "   -> Installing hubble CLI ${hubble_version}..."
    aiden_install_tarball_bin hubble \
      "https://github.com/cilium/hubble/releases/download/${hubble_version}/hubble-linux-${arch}"
  fi

  if [ -z "${CILIUM_VERSION}" ]; then
    CILIUM_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium/main/stable.txt)
  fi
  CILIUM_VERSION=${CILIUM_VERSION#v}
  if [ -z "$CILIUM_VERSION" ]; then
    echo "Failed to resolve the latest Cilium release. Set CILIUM_VERSION and retry." >&2
    return 1
  fi
  # BGP v2 resources (CiliumBGPClusterConfig etc.) need Cilium >= 1.16
  local major minor
  IFS=. read -r major minor _ <<<"$CILIUM_VERSION"
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 16 ]; }; then
    echo "Cilium $CILIUM_VERSION is too old; 1.16 or newer is required." >&2
    return 1
  fi

  # BGP is only switched on when a peer was given; L2-only setups run without it.
  local bgp_enabled=false
  [ -n "$BGP_PEER_IP" ] && bgp_enabled=true

  echo "   -> Installing Cilium ${CILIUM_VERSION} (BGP: ${bgp_enabled})..."
  cilium install --version "$CILIUM_VERSION" \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$api_ip" \
    --set k8sServicePort=6443 \
    --set ipam.mode=kubernetes \
    --set operator.replicas="$operator_replicas" \
    --set socketLB.hostNamespaceOnly=true \
    --set bgpControlPlane.enabled="$bgp_enabled" \
    --set l2announcements.enabled=true \
    --set externalIPs.enabled=true \
    --set k8sClientRateLimit.qps=50 \
    --set k8sClientRateLimit.burst=100 \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true

  echo "   -> Waiting for Cilium to become ready..."
  cilium status --wait --wait-duration 10m

  cilium_apply_network_config
}

# Apply LB IP pool, L2 announcement policy and BGP peering from the prompt values.
cilium_apply_network_config() {
  local manifest="$AIDEN_STATE_DIR/cilium-network.yaml"
  mkdir -p "$AIDEN_STATE_DIR"
  : > "$manifest"

  if [ -z "$LB_POOL" ] && [ -z "$BGP_PEER_IP" ]; then
    echo "   -> No LoadBalancer pool or BGP peer given; L2 announcements are enabled but have no IPs to announce."
    return 0
  fi

  local crds=(ciliumloadbalancerippools.cilium.io ciliuml2announcementpolicies.cilium.io)
  if [ -n "$BGP_PEER_IP" ]; then
    # BGP CRDs are only registered when the BGP Control Plane is enabled
    crds+=(ciliumbgpclusterconfigs.cilium.io ciliumbgppeerconfigs.cilium.io
           ciliumbgpadvertisements.cilium.io)
  fi
  local crd
  for crd in "${crds[@]}"; do
    kubectl wait --for=condition=Established "crd/$crd" --timeout=180s
  done

  if [ -n "$LB_POOL" ]; then
    local block
    if [[ "$LB_POOL" == *-* ]]; then
      block="    - start: \"${LB_POOL%-*}\"
      stop: \"${LB_POOL#*-}\""
    else
      block="    - cidr: \"${LB_POOL}\""
    fi
    cat >> "$manifest" <<EOF
apiVersion: cilium.io/$(cilium_crd_version ciliumloadbalancerippools.cilium.io)
kind: CiliumLoadBalancerIPPool
metadata:
  name: aiden-lb-pool
spec:
  blocks:
${block}
---
apiVersion: cilium.io/$(cilium_crd_version ciliuml2announcementpolicies.cilium.io)
kind: CiliumL2AnnouncementPolicy
metadata:
  name: aiden-l2
spec:
  loadBalancerIPs: true
  externalIPs: true
---
EOF
  fi

  if [ -n "$BGP_PEER_IP" ]; then
    cat >> "$manifest" <<EOF
apiVersion: cilium.io/$(cilium_crd_version ciliumbgpclusterconfigs.cilium.io)
kind: CiliumBGPClusterConfig
metadata:
  name: aiden-bgp
spec:
  bgpInstances:
  - name: "aiden-${BGP_LOCAL_ASN}"
    localASN: ${BGP_LOCAL_ASN}
    peers:
    - name: "upstream-router"
      peerASN: ${BGP_PEER_ASN}
      peerAddress: ${BGP_PEER_IP}
      peerConfigRef:
        name: aiden-bgp-peer
---
apiVersion: cilium.io/$(cilium_crd_version ciliumbgppeerconfigs.cilium.io)
kind: CiliumBGPPeerConfig
metadata:
  name: aiden-bgp-peer
spec:
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: aiden-bgp
---
apiVersion: cilium.io/$(cilium_crd_version ciliumbgpadvertisements.cilium.io)
kind: CiliumBGPAdvertisement
metadata:
  name: aiden-bgp-adverts
  labels:
    advertise: aiden-bgp
spec:
  advertisements:
  - advertisementType: "PodCIDR"
  - advertisementType: "Service"
    service:
      addresses:
      - LoadBalancerIP
    selector:
      matchExpressions:
      - {key: aiden-never-used-key, operator: NotIn, values: ["never-used-value"]}
---
EOF
  fi

  echo "   -> Applying Cilium network config (saved to $manifest)..."
  kubectl apply -f "$manifest"
}

cilium_print_summary() {
  if [ -n "$BGP_PEER_IP" ]; then
    echo "Cilium:  kube-proxy replacement, BGP Control Plane, L2 announcements, Hubble"
  else
    echo "Cilium:  kube-proxy replacement, L2 announcements, Hubble (BGP off)"
  fi
  [ -n "$LB_POOL" ]     && echo "  LB pool:  $LB_POOL (announced via L2${BGP_PEER_IP:+ and BGP})"
  if [ -n "$BGP_PEER_IP" ]; then
    echo "  BGP:      AS${BGP_LOCAL_ASN} <-> ${BGP_PEER_IP} AS${BGP_PEER_ASN}   (check: cilium bgp peers)"
  else
    echo "  BGP:      off — enable later with: cilium upgrade --reuse-values --set bgpControlPlane.enabled=true"
  fi
  echo "  Status:   cilium status"
  echo "  Hubble:   cilium hubble ui   (or: cilium hubble port-forward & hubble observe)"
  return 0
}
