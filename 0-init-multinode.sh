#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root.\e[0m"
  exit 1
fi

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

read -p "Enter Kubernetes Version (e.g., v1.29, v1.30, v1.31) [v1.33]: " K8S_VERSION
K8S_VERSION=${K8S_VERSION:-v1.33}

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
# 1. Generate Shared System Preparation Script
# ==========================================================
echo -e "\e[32m[1/7] Generating shared system preparation script...\e[0m"

PREP_SCRIPT="$WORK_DIR/k8s_prep.sh"
cat << 'EOF' > "$PREP_SCRIPT"
#!/bin/bash
set -e

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
dnf install -y containerd.io
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl enable --now containerd
EOF

# Append Kubernetes Repositories (with dynamic version)
cat << EOF >> "$PREP_SCRIPT"
cat << 'IEOF' > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
IEOF
dnf install -y kubelet kubeadm kubectl
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
echo -e "\e[32m[4/7] Initializing Control Plane...\e[0m"
kubeadm init \
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
# 6. Install Calico CNI
# ==========================================================
echo -e "\e[32m[6/7] Installing Calico CNI...\e[0m"
CALICO_VERSION=$(curl -fsSL https://api.github.com/repos/projectcalico/calico/releases/latest \
  | grep -Eo '"tag_name":\s*"[^"]+"' \
  | head -n1 \
  | cut -d'"' -f4)

if [ -z "${CALICO_VERSION}" ]; then
  echo "Failed to resolve latest Calico release. Deploying fallback version."
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
else
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
fi

# ==========================================================
# 7. Cleanup & Finalization
# ==========================================================
echo -e "\e[32m[7/7] Cleaning up temporary files...\e[0m"
# WORK_DIR (generated scripts) is removed automatically by the EXIT trap.
unset SSH_PASSWORD

echo -e "\e[32m==========================================================\e[0m"
echo -e "\e[32m✅ Multi-Node Infrastructure successfully provisioned!\e[0m"
echo -e "Wait a few moments for Calico pods to start, then run:"
echo -e "  \e[36mkubectl get nodes -w\e[0m"
echo -e "\e[32m==========================================================\e[0m"
