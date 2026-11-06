#!/bin/bash
# ==========================================================
# 🗑️ Kubernetes & KubeVirt Teardown Script
#
# Usage:
#   sudo bash 3-teardown.sh               # full teardown (workers + this node)
#   sudo bash 3-teardown.sh --local-only  # this node only, non-interactive
#                                         # (used internally on worker nodes)
# ==========================================================
set -e

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root.\e[0m"
  exit 1
fi

LOCAL_ONLY=false
[ "$1" = "--local-only" ] && LOCAL_ONLY=true

STATE_DIR=/var/lib/aiden-lab
STATE_FILE=$STATE_DIR/state
WORKERS_FILE=$STATE_DIR/workers

echo "⚠️  Starting full system restoration..."

# 0. Tear down worker nodes first (multi-node setups only)
if [ "$LOCAL_ONLY" = false ] && [ -s "$WORKERS_FILE" ]; then
  echo "[0/9] Worker nodes recorded by 0-init-multinode.sh:"
  sed 's/^/        /' "$WORKERS_FILE"
  read -p "Tear down these worker nodes too? [Y/n]: " DO_WORKERS
  if [[ ! "$DO_WORKERS" =~ ^[nN] ]]; then
    command -v expect >/dev/null || dnf install -y expect
    read -s -p "Enter the SSH (root) password for the worker nodes: " SSH_PASSWORD
    echo ""

    WORK_DIR=$(mktemp -d /tmp/aiden-lab.XXXXXX)
    chmod 700 "$WORK_DIR"
    trap 'rm -rf "$WORK_DIR"' EXIT

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
    with_password() { AIDEN_SSH_PASS="$SSH_PASSWORD" expect -f "$EXP_SCRIPT" "$@"; }

    mkdir -p /var/log/aiden-lab
    SELF="$(readlink -f "$0")"
    while read -r W_IP W_HOST; do
      [ -z "$W_IP" ] && continue
      W_LOG="/var/log/aiden-lab/teardown-$W_HOST.log"
      echo "  -> Tearing down $W_HOST ($W_IP)... (log: $W_LOG)"
      if with_password scp "${SSH_OPTS[@]}" "$SELF" root@"$W_IP":/root/aiden_teardown.sh > "$W_LOG" 2>&1 &&
         with_password ssh "${SSH_OPTS[@]}" root@"$W_IP" \
           "bash /root/aiden_teardown.sh --local-only; rc=\$?; rm -f /root/aiden_teardown.sh; exit \$rc" >> "$W_LOG" 2>&1; then
        echo "     done."
      else
        echo -e "     \e[31mfailed — see $W_LOG and clean up $W_HOST manually.\e[0m"
      fi
    done < "$WORKERS_FILE"
    unset SSH_PASSWORD
  fi
fi

# 1. Reset Kubernetes
echo "[1/9] Resetting Kubernetes cluster..."
kubeadm reset -f || true

# 2. Remove K8s and Containerd packages
echo "[2/9] Removing Kubernetes and Containerd packages..."
dnf remove -y --disableexcludes=all kubelet kubeadm kubectl containerd.io || true
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
rm -rf /var/lib/cni/
rm -rf /var/lib/calico/
rm -rf /var/run/cilium/ /run/cilium/
rm -f /opt/cni/bin/cilium-cni
# Cilium's pinned BPF maps/programs (bpffs is not persistent; a reboot also clears these)
rm -rf /sys/fs/bpf/cilium /sys/fs/bpf/tc/globals/cilium_* 2>/dev/null || true

# 4. Remove Binary Tools
echo "[4/9] Removing virtctl and tools installed by setup (cilium, hubble, helm)..."
rm -f /usr/local/bin/virtctl
if [ -f "$STATE_DIR/installed-bins" ]; then
  while read -r BIN; do
    case "$BIN" in
      /usr/local/bin/*) rm -f "$BIN" && echo "   removed $BIN" ;;
    esac
  done < "$STATE_DIR/installed-bins"
fi

# 5. Restore Network Interfaces & Iptables
echo "[5/9] Cleaning up networking (IPVS/Iptables)..."
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
# Delete CNI interfaces one by one (`ip link delete` takes a single name, no globs)
for LINK in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 \
              | grep -E '^(cilium_host|cilium_net|cilium_vxlan|cilium_geneve|lxc.+|cali.+|tunl0|vxlan\.calico|cni0|flannel\.1)$' || true); do
  ip link delete "$LINK" 2>/dev/null || true
done

# Load the original state recorded by 0-init-*.sh, if available
HAVE_STATE=false
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  HAVE_STATE=true
else
  echo -e "\e[33m⚠️  No recorded state at $STATE_FILE — swap, SELinux and firewalld"
  echo -e "   will NOT be changed. Restore them manually if needed.\e[0m"
fi

# 6. Re-enable Swap (only the lines setup commented out)
echo "[6/9] Re-enabling Swap..."
if grep -q '^#AIDEN# ' /etc/fstab; then
  sed -i 's/^#AIDEN# //' /etc/fstab
  swapon -a || echo "No swap partitions found to enable."
elif [ "$HAVE_STATE" = true ] && [ -f "$STATE_DIR/fstab.orig" ]; then
  # Setup from an older version of the scripts (untagged lines): fall back to the backup
  echo "   No tagged swap lines found; restoring /etc/fstab from $STATE_DIR/fstab.orig"
  cp -a /etc/fstab /etc/fstab.aiden-teardown.bak
  cp -a "$STATE_DIR/fstab.orig" /etc/fstab
  swapon -a || echo "No swap partitions found to enable."
else
  echo "   Nothing to restore."
fi

# 7. Restore SELinux & Firewall to their original state
echo "[7/9] Restoring Security settings (Firewall/SELinux)..."
if [ "$HAVE_STATE" = true ]; then
  if [ -n "$ORIG_SELINUX_CONFIG" ] && [ -f /etc/selinux/config ]; then
    sed -i "s/^SELINUX=.*/SELINUX=${ORIG_SELINUX_CONFIG}/" /etc/selinux/config
  fi
  case "$ORIG_SELINUX_RUNTIME" in
    Enforcing)  setenforce 1 || true ;;
    Permissive) setenforce 0 || true ;;
  esac
  echo "   SELinux -> runtime: ${ORIG_SELINUX_RUNTIME:-unknown}, config: ${ORIG_SELINUX_CONFIG:-unchanged}"

  if [ "$ORIG_FIREWALLD_ENABLED" = "enabled" ]; then
    systemctl enable firewalld || true
  fi
  if [ "$ORIG_FIREWALLD_ACTIVE" = "active" ]; then
    systemctl start firewalld || true
  fi
  echo "   firewalld -> ${ORIG_FIREWALLD_ENABLED:-unknown}/${ORIG_FIREWALLD_ACTIVE:-unknown}"
else
  echo "   Skipped (no recorded state)."
fi

# 8. Clean up Kernel Modules and Sysctl
echo "[8/9] Removing Kernel Modules and Network configs..."
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/k8s.conf
modprobe -r br_netfilter || true
modprobe -r overlay || true
sysctl --system

# 9. Remove the created user
echo "[9/9] Checking for custom user removal..."
if [ "$LOCAL_ONLY" = false ]; then
  DEFAULT_USER=""
  [ -f "$STATE_DIR/user" ] && DEFAULT_USER=$(sed -n 's/^AIDEN_USER=//p' "$STATE_DIR/user")
  USER_TO_DEL=""
  if [ -n "$DEFAULT_USER" ]; then
    read -p "Delete user '$DEFAULT_USER' created during setup (home dir included)? [y/N]: " DEL_ANSWER
    [[ "$DEL_ANSWER" =~ ^[yY] ]] && USER_TO_DEL=$DEFAULT_USER
  else
    read -p "Enter the username created during setup to delete (leave blank to skip): " USER_TO_DEL
  fi
  if [ -n "$USER_TO_DEL" ]; then
    userdel -r "$USER_TO_DEL" || echo "User not found."
  fi
else
  echo "   Skipped (--local-only)."
fi

# Remove recorded state now that it has been restored
rm -rf "$STATE_DIR"

echo "=========================================================="
echo "✅ Teardown Complete!"
echo "It is highly recommended to REBOOT the machine now."
echo "=========================================================="
