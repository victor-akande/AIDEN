#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root.\e[0m"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=check-cgroup.sh
source "$SCRIPT_DIR/check-cgroup.sh"   # also loads lib/versions.sh
# shellcheck source=lib/cilium.sh
source "$SCRIPT_DIR/lib/cilium.sh"

echo -e "\e[32m==========================================================\e[0m"
echo -e "\e[32m🚀 Initiating Interactive Multi-Node Kubernetes Build\e[0m"
echo -e "\e[32m==========================================================\e[0m"

# ==========================================================
# 0. Interactive Configuration Prompts
# ==========================================================
echo ""
echo -e "\e[33m--- 🛠️  Customization Parameters ---\e[0m"
echo "Press [ENTER] to accept the default values."

read -p "Enter username for new sudo user [AIDEN]: " NEW_USER
NEW_USER=${NEW_USER:-AIDEN}

read -s -p "Enter password for user '$NEW_USER' [AIDEN#]: " NEW_USER_PASS
echo ""
NEW_USER_PASS=${NEW_USER_PASS:-AIDEN#}

read -p "Enter Pod Network CIDR [192.168.0.0/16]: " POD_CIDR
POD_CIDR=${POD_CIDR:-192.168.0.0/16}

echo ""
echo -e "\e[33m--- 🌐 Control Plane Interface Selection ---\e[0m"
INTERFACES=$(ip -o -4 addr show | awk '$2 != "lo" {print $2 ":" $4}')
IFS=$'\n' read -rd '' -a INT_ARRAY <<<"$INTERFACES" || true

for i in "${!INT_ARRAY[@]}"; do
    echo "  [$i] ${INT_ARRAY[$i]}"
done

read -p "Select the network interface number for the API Server [0]: " INT_SELECTION
INT_SELECTION=${INT_SELECTION:-0}

SELECTED_INT_INFO=${INT_ARRAY[$INT_SELECTION]}
SELECTED_IFACE=$(echo "$SELECTED_INT_INFO" | cut -d':' -f1)
SELECTED_IP_CIDR=$(echo "$SELECTED_INT_INFO" | cut -d':' -f2)
SELECTED_IP=$(echo "$SELECTED_IP_CIDR" | cut -d'/' -f1)
echo "-> Selected Control Plane Interface: $SELECTED_IFACE (IP: $SELECTED_IP)"

echo ""
echo -e "\e[33m--- 🖥️  Worker Node Configuration ---\e[0m"
read -p "Enter number of worker nodes (1, 2, or 3) [1]: " WORKER_COUNT
WORKER_COUNT=${WORKER_COUNT:-1}

declare -a WORKER_IPS
declare -a WORKER_HOSTS

for (( i=1; i<=WORKER_COUNT; i++ )); do
    read -p "Enter Worker $i IP address: " W_IP
    read -p "Enter Worker $i Hostname (e.g., worker$i): " W_HOST
    WORKER_IPS+=("$W_IP")
    WORKER_HOSTS+=("$W_HOST")
done

echo ""
cilium_prompt

echo ""
echo -e "\e[33m--- 🔑 SSH Credentials ---\e[0m"
read -s -p "Enter the SSH (root) password for the worker nodes: " SSH_PASSWORD
echo ""

echo "----------------------------------------------------------"
echo "Configuration gathered. Starting infrastructure build..."
echo "----------------------------------------------------------"
echo ""

# Ensure expect is installed locally for remote automation
dnf install -y expect dnf-plugins-core >/dev/null 2>&1

# Private working directory for generated scripts; removed on exit.
WORK_DIR=$(mktemp -d /tmp/aiden-lab.XXXXXX)
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

LOG_DIR=/var/log/aiden-lab
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# Generic expect wrapper: runs the given command, answers password prompts.
# The password is read from the environment, never written to disk.
EXP_SCRIPT="$WORK_DIR/run_with_password.exp"
cat > "$EXP_SCRIPT" <<'EOF'
#!/usr/bin/expect -f
set timeout -1
set pass $env(AIDEN_SSH_PASS)
spawn {*}$argv
expect {
    -re "(?i)password:" { send -- "$pass\r"; exp_continue }
    eof
}
lassign [wait] pid spawnid os_error value
exit $value
EOF
chmod 600 "$EXP_SCRIPT"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

# Usage: with_password <command...>
with_password() {
    AIDEN_SSH_PASS="$SSH_PASSWORD" expect -f "$EXP_SCRIPT" "$@"
}

# Create configured user
useradd -m "$NEW_USER" || true
echo "$NEW_USER:$NEW_USER_PASS" | chpasswd
usermod -aG wheel "$NEW_USER"
echo "User '$NEW_USER' configured locally."

# ==========================================================
# cgroup check on every node. All nodes must run the same Kubernetes
# release, so a single cgroup v1 node puts the whole cluster on 1.34.
# ==========================================================
echo -e "\e[33m--- 🔎 cgroup Check (all nodes) ---\e[0m"
CLUSTER_CGROUP=$(aiden_cgroup_version)
echo "  -> control plane: cgroup v${CLUSTER_CGROUP}"
for (( i=0; i<WORKER_COUNT; i++ )); do
    W_IP=${WORKER_IPS[$i]}
    W_HOST=${WORKER_HOSTS[$i]}
    CG_OUT=$(with_password ssh "${SSH_OPTS[@]}" root@"$W_IP" "stat -fc %T /sys/fs/cgroup" 2>&1) \
      || { echo -e "\e[31mCould not check cgroup version on $W_HOST ($W_IP):\e[0m"; echo "$CG_OUT"; exit 1; }
    if grep -q 'cgroup2fs' <<<"$CG_OUT"; then
        W_CG=2
    elif grep -q 'tmpfs' <<<"$CG_OUT"; then
        W_CG=1
    else
        echo -e "\e[31mUnexpected cgroup check output from $W_HOST ($W_IP):\e[0m"; echo "$CG_OUT"; exit 1
    fi
    echo "  -> $W_HOST: cgroup v${W_CG}"
    if [ "$W_CG" = "1" ]; then CLUSTER_CGROUP=1; fi
done
aiden_select_k8s_version "$CLUSTER_CGROUP"
echo "-> Installing Kubernetes ${K8S_PATCH} on all nodes"
if [ "$CLUSTER_CGROUP" = "1" ]; then
  aiden_cgroup_v1_notice
fi
echo ""

# ==========================================================
# 1. Generate Shared System Preparation Script
# ==========================================================
echo -e "\e[32m[1/7] Generating shared system preparation script...\e[0m"

PREP_SCRIPT="$WORK_DIR/k8s_prep.sh"
# Header with the pinned versions (expanded now), then the static body
cat << EOF > "$PREP_SCRIPT"
#!/bin/bash
set -e
AIDEN_CONTAINERD_VERSION=${AIDEN_CONTAINERD_VERSION}
EOF
cat << 'EOF' >> "$PREP_SCRIPT"

# Record the original system state (used by 3-teardown.sh). Written once only.
STATE_DIR=/var/lib/aiden-lab
STATE_FILE=$STATE_DIR/state
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
if [ ! -f "$STATE_FILE" ]; then
  {
    echo "ORIG_SELINUX_RUNTIME=$(getenforce 2>/dev/null || echo Disabled)"
    echo "ORIG_SELINUX_CONFIG=$(grep -E '^SELINUX=' /etc/selinux/config 2>/dev/null | cut -d= -f2)"
    echo "ORIG_FIREWALLD_ENABLED=$(systemctl is-enabled firewalld 2>/dev/null || true)"
    echo "ORIG_FIREWALLD_ACTIVE=$(systemctl is-active firewalld 2>/dev/null || true)"
  } > "$STATE_FILE"
  cp -a /etc/fstab "$STATE_DIR/fstab.orig"
fi

# Disable Swap (tag commented lines so teardown restores exactly these)
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#AIDEN# /' /etc/fstab

# Disable SELinux & Firewall
setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
systemctl disable --now firewalld || true

# Kernel Modules & Sysctl
cat <<IEOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
IEOF
modprobe overlay
modprobe br_netfilter

cat <<IEOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
IEOF
sysctl --system
sysctl -w net.ipv4.ip_forward=1

# Install Containerd
dnf install -y dnf-plugins-core
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sed -i 's/\$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
dnf install -y "containerd.io-${AIDEN_CONTAINERD_VERSION}" --disableexcludes=docker-ce-stable
# Lock containerd at the pinned version: exclude it from the Docker repo so a
# routine 'dnf update' cannot upgrade it (3-teardown.sh removes this repo file).
grep -q '^exclude=containerd.io' /etc/yum.repos.d/docker-ce.repo \
  || sed -i '/^\[docker-ce-stable\]$/a exclude=containerd.io' /etc/yum.repos.d/docker-ce.repo
containerd config default > /etc/containerd/config.toml
# containerd 2.x's generated default may omit SystemdCgroup, so add it when missing
if grep -q 'SystemdCgroup' /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
else
  sed -i -E '/runtimes\.runc\.options\][[:space:]]*$/a\            SystemdCgroup = true' /etc/containerd/config.toml
fi
# Read per-registry mirror config from certs.d (Spegel P2P image distribution)
# and keep layer blobs after unpacking so this node can serve images to peers.
sed -i -E "/\.registry\]\$/,/^[[:space:]]*\[/ s#^([[:space:]]*config_path = )(\"\"|'')#\1\"/etc/containerd/certs.d\"#" /etc/containerd/config.toml
sed -i 's/discard_unpacked_layers = true/discard_unpacked_layers = false/' /etc/containerd/config.toml
mkdir -p /etc/containerd/certs.d
systemctl enable --now containerd
systemctl restart containerd
EOF

# Append Kubernetes Repositories (pinned version chosen by the cgroup check).
# The exclude line stops a routine 'dnf update' from upgrading Kubernetes.
cat << EOF >> "$PREP_SCRIPT"
cat << 'IEOF' > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
IEOF
dnf install -y kubelet-${K8S_PATCH} kubeadm-${K8S_PATCH} kubectl-${K8S_PATCH} --disableexcludes=kubernetes
systemctl enable --now kubelet
EOF

chmod 700 "$PREP_SCRIPT"

# ==========================================================
# 2. Prepare Local System (Control Plane)
# ==========================================================
echo -e "\e[32m[2/7] Executing system prep on local Control Plane...\e[0m"
bash "$PREP_SCRIPT"
echo "AIDEN_USER=$NEW_USER" > /var/lib/aiden-lab/user

# Record the workers so 3-teardown.sh can clean them up too
: > /var/lib/aiden-lab/workers
chmod 600 /var/lib/aiden-lab/workers
for (( i=0; i<WORKER_COUNT; i++ )); do
    echo "${WORKER_IPS[$i]} ${WORKER_HOSTS[$i]}" >> /var/lib/aiden-lab/workers
done

# ==========================================================
# 3. Prepare Remote Systems (Worker Nodes)
# ==========================================================
echo -e "\e[32m[3/7] Executing system prep on Worker Nodes...\e[0m"

for (( i=0; i<WORKER_COUNT; i++ )); do
    W_IP=${WORKER_IPS[$i]}
    W_HOST=${WORKER_HOSTS[$i]}
    W_LOG="$LOG_DIR/prep-$W_HOST.log"
    echo "  -> Preparing $W_HOST ($W_IP)... (log: $W_LOG)"

    {
      # Chained with && because set -e does not apply inside a "{ } ||" group
      with_password ssh "${SSH_OPTS[@]}" root@"$W_IP" "hostnamectl set-hostname $W_HOST" &&
      with_password scp "${SSH_OPTS[@]}" "$PREP_SCRIPT" root@"$W_IP":/root/aiden_k8s_prep.sh &&
      with_password ssh "${SSH_OPTS[@]}" root@"$W_IP" "bash /root/aiden_k8s_prep.sh && rm -f /root/aiden_k8s_prep.sh"
    } > "$W_LOG" 2>&1 || { echo -e "\e[31mPreparation of $W_HOST failed. See $W_LOG\e[0m"; exit 1; }
done

# ==========================================================
# 4. Initialize Kubernetes Cluster
# ==========================================================
echo -e "\e[32m[4/7] Initializing Control Plane (without kube-proxy; Cilium replaces it)...\e[0m"
kubeadm init \
  --kubernetes-version="v${K8S_PATCH}" \
  --skip-phases=addon/kube-proxy \
  --cri-socket unix:///var/run/containerd/containerd.sock \
  --pod-network-cidr="$POD_CIDR" \
  --apiserver-advertise-address="$SELECTED_IP"

# Configure kubectl for root
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown $(id -u):$(id -g) /root/.kube/config

# Configure kubectl for new user
mkdir -p /home/"$NEW_USER"/.kube
cp -i /etc/kubernetes/admin.conf /home/"$NEW_USER"/.kube/config
chown "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# ==========================================================
# 5. Generate Join Command & Attach Workers
# ==========================================================
echo -e "\e[32m[5/7] Attaching Worker Nodes to the cluster...\e[0m"
JOIN_CMD=$(kubeadm token create --print-join-command)

for (( i=0; i<WORKER_COUNT; i++ )); do
    W_IP=${WORKER_IPS[$i]}
    W_HOST=${WORKER_HOSTS[$i]}
    W_LOG="$LOG_DIR/join-$W_HOST.log"
    echo "  -> Joining $W_HOST ($W_IP)... (log: $W_LOG)"

    with_password ssh "${SSH_OPTS[@]}" root@"$W_IP" "$JOIN_CMD" > "$W_LOG" 2>&1 \
      || { echo -e "\e[31mJoining $W_HOST failed. See $W_LOG\e[0m"; exit 1; }
done

# ==========================================================
# 6. Install Cilium CNI
# ==========================================================
echo -e "\e[32m[6/7] Installing Cilium CNI...\e[0m"
# Two operator replicas for HA now that there is more than one node
cilium_install "$SELECTED_IP" 2

# ==========================================================
# 7. Cleanup & Finalization
# ==========================================================
echo -e "\e[32m[7/7] Cleaning up temporary files...\e[0m"
# WORK_DIR (generated scripts) is removed automatically by the EXIT trap.
unset SSH_PASSWORD

echo -e "\e[32m==========================================================\e[0m"
echo -e "\e[32m✅ Multi-Node Infrastructure successfully provisioned!\e[0m"
cilium_print_summary
echo -e "Check that all nodes are Ready:"
echo -e "  \e[36mkubectl get nodes -w\e[0m"
echo -e "\e[32m==========================================================\e[0m"
