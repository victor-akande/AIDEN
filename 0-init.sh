#!/bin/bash
set -e

echo "=========================================================="
echo "🚀 Initiating Interactive Kubernetes & Calico Build"
echo "=========================================================="

# ==========================================================
# 0. Interactive Configuration Prompts
# ==========================================================
echo ""
echo "--- 🛠️  Customization Parameters ---"
echo "Press [ENTER] to accept the default values."

read -p "Enter username for new sudo user [AIDEN]: " NEW_USER
NEW_USER=${NEW_USER:-AIDEN}

read -p "Enter password for user '$NEW_USER' [AIDEN#]: " NEW_USER_PASS
NEW_USER_PASS=${NEW_USER_PASS:-AIDEN}

read -p "Enter Kubernetes Version (e.g., v1.29, v1.30, v1.31) [v1.33]: " K8S_VERSION
K8S_VERSION=${K8S_VERSION:-v1.33}

read -p "Enter Pod Network CIDR [192..0.0/16]: " POD_CIDR
POD_CIDR=${POD_CIDR:-192.168.0.0/16}

echo ""
echo "--- 🌐 Network Interface Selection ---"
# Fetch non-loopback interfaces and their IPv4 addresses
INTERFACES=$(ip -o -4 addr show | awk '$2 != "lo" {print $2 ":" $4}')
IFS=$'\n' read -rd '' -a INT_ARRAY <<<"$INTERFACES" || true

echo "Available Network Interfaces:"
for i in "${!INT_ARRAY[@]}"; do
    echo "  [$i] ${INT_ARRAY[$i]}"
done

read -p "Select the network interface number for the API Server [0]: " INT_SELECTION
INT_SELECTION=${INT_SELECTION:-0}

# Extract the interface name and IP address based on user selection
SELECTED_INT_INFO=${INT_ARRAY[$INT_SELECTION]}
SELECTED_IFACE=$(echo "$SELECTED_INT_INFO" | cut -d':' -f1)
SELECTED_IP_CIDR=$(echo "$SELECTED_INT_INFO" | cut -d':' -f2)
SELECTED_IP=$(echo "$SELECTED_IP_CIDR" | cut -d'/' -f1)

echo "-> Selected Interface: $SELECTED_IFACE (IP: $SELECTED_IP)"

echo "----------------------------------------------------------"
echo "Configuration gathered. Starting infrastructure build..."
echo "----------------------------------------------------------"
echo ""

# Create configured user with home directory
useradd -m "$NEW_USER" || true # Avoid failing if user already exists
echo "$NEW_USER:$NEW_USER_PASS" | chpasswd
usermod -aG wheel "$NEW_USER"
echo "User '$NEW_USER' configured and granted sudo privileges."

# 1. Disable Swap (Kubelet requirement)
echo "[1/8] Disabling Swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 2. Disable SELinux & Firewall (Required for standard K8s networking)
echo "[2/8] Permissing SELinux and disabling Firewalld..."
setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
systemctl disable --now firewalld || true

# 3. Load Kernel Modules & Configure Sysctl for Networking
echo "[3/8] Configuring Kernel Modules and IP Forwarding..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
mkdir -p /disk

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 4. Install Containerd
echo "[4/8] Installing Containerd..."
# Add the repository that provides containerd.io
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sed -i 's/\$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
dnf install -y containerd.io

# Configure containerd to use Systemd Cgroup (Crucial for stability)
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl enable --now containerd

# 5. Add Kubernetes Repository & Install Components
echo "[5/8] Installing Kubeadm, Kubelet, and Kubectl ($K8S_VERSION)..."
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
EOF

dnf install -y kubelet kubeadm kubectl
systemctl enable --now kubelet

# 6. Initialize Kubernetes Cluster
echo "[6/8] Initializing Single-Node Control Plane..."
kubeadm init \
  --cri-socket unix:///var/run/containerd/containerd.sock \
  --pod-network-cidr="$POD_CIDR" \
  --apiserver-advertise-address="$SELECTED_IP" \
  --v=7

# Configure kubectl for root
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown $(id -u):$(id -g) /root/.kube/config

# Configure kubectl for new user
mkdir -p /home/"$NEW_USER"/.kube
cp -i /etc/kubernetes/admin.conf /home/"$NEW_USER"/.kube/config
chown "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.kube/config

# 7. Untaint the Control Plane (Allows pods to run on this single node)
echo "[7/8] Removing control-plane taint for single-node operation..."
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# 8. Install Calico CNI
echo "[8/8] Installing Calico CNI..."
CALICO_VERSION=$(curl -fsSL https://api.github.com/repos/projectcalico/calico/releases/latest \
  | grep -Eo '"tag_name":\s*"[^"]+"' \
  | head -n1 \
  | cut -d'"' -f4)
if [ -z "${CALICO_VERSION}" ]; then
  echo "Failed to resolve latest Calico release." >&2
  exit 1
fi

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

echo "=========================================================="
echo "✅ Infrastructure layer successfully provisioned!"
echo "Run 'kubectl get nodes -w' to watch your node become Ready."
echo "=========================================================="

kubcectl get nodes -w
