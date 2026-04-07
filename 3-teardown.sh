#!/bin/bash
# ==========================================================
# 🗑️ Kubernetes & KubeVirt Teardown Script
# ==========================================================
set -e

echo "⚠️  Starting full system restoration..."

# 1. Reset Kubernetes
echo "[1/9] Resetting Kubernetes cluster..."
kubeadm reset -f || true

# 2. Remove K8s and Containerd packages
echo "[2/9] Removing Kubernetes and Containerd packages..."
dnf remove -y kubelet kubeadm kubectl containerd.io
rm -rf /etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/docker-ce.repo

# 3. Clean up Configuration Directories
echo "[3/9] Cleaning up configuration files and data..."
rm -rf /etc/kubernetes/
rm -rf /var/lib/etcd/
rm -rf /var/lib/kubelet/
rm -rf /var/lib/containerd/
rm -rf /etc/containerd/
rm -rf /root/.kube/
rm -rf /home/*/.kube/
rm -rf /etc/cni/net.d/

# 4. Remove Binary Tools
echo "[4/9] Removing virtctl..."
rm -f /usr/local/bin/virtctl

# 5. Restore Network Interfaces & Iptables
echo "[5/9] Cleaning up networking (IPVS/Iptables)..."
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
ip link delete cni0 || true
ip link delete flannel.1 || true
ip link delete tunl0 || true
ip link delete cali* || true # Remove Calico interfaces

# 6. Re-enable Swap
echo "[6/9] Re-enabling Swap..."
sed -i 's/^#\(.*swap.*\)$/\1/' /etc/fstab
swapon -a || echo "No swap partitions found to enable."

# 7. Restore SELinux & Firewall
echo "[7/9] Restoring Security settings (Firewall/SELinux)..."
setenforce 1 || true
sed -i 's/^SELINUX=permissive$/SELINUX=enforcing/' /etc/selinux/config
systemctl enable --now firewalld || true

# 8. Clean up Kernel Modules and Sysctl
echo "[8/9] Removing Kernel Modules and Network configs..."
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/k8s.conf
modprobe -r br_netfilter || true
modprobe -r overlay || true
sysctl --system

# 9. Remove the created user
echo "[9/9] Checking for custom user removal..."
read -p "Enter the username created during setup to delete (leave blank to skip): " USER_TO_DEL
if [ -n "$USER_TO_DEL" ]; then
    userdel -r "$USER_TO_DEL" || echo "User not found."
fi

echo "=========================================================="
echo "✅ Teardown Complete!"
echo "It is highly recommended to REBOOT the machine now."
echo "=========================================================="