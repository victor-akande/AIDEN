#!/bin/bash
# ==========================================================
# 🔎 cgroup version check
#
# Kubernetes 1.35+ kubelets refuse to start on cgroup v1 by default
# (failCgroupV1=true), so the Kubernetes release depends on the host:
#   cgroup v2          -> Kubernetes 1.36
#   cgroup v1 / hybrid -> Kubernetes 1.34 (last release that runs on v1 by default)
# Exact versions are pinned in lib/versions.sh.
#
# Run it directly to check this host:
#   bash check-cgroup.sh
# The init scripts source it and use the functions below.
# ==========================================================

_AIDEN_CG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/versions.sh
source "$_AIDEN_CG_DIR/lib/versions.sh"

# Filesystem type of /sys/fs/cgroup: "cgroup2fs" on cgroup v2,
# "tmpfs" on cgroup v1 and on hybrid hosts (v2 only at /sys/fs/cgroup/unified).
aiden_cgroup_fstype() {
  stat -fc %T /sys/fs/cgroup 2>/dev/null
}

# Usage: aiden_cgroup_version_from_fstype <fstype>  -> prints 2 or 1
# Kubernetes only treats a host as cgroup v2 when /sys/fs/cgroup itself is cgroup2.
aiden_cgroup_version_from_fstype() {
  if [ "$1" = "cgroup2fs" ]; then echo 2; else echo 1; fi
}

aiden_cgroup_version() {
  aiden_cgroup_version_from_fstype "$(aiden_cgroup_fstype)"
}

# Usage: aiden_select_k8s_version <cgroup-version>
# Sets K8S_VERSION (repo channel, e.g. v1.36) and K8S_PATCH (e.g. 1.36.6).
aiden_select_k8s_version() {
  if [ "$1" = "2" ]; then
    K8S_VERSION=$AIDEN_K8S_CGROUPV2_MINOR
    K8S_PATCH=$AIDEN_K8S_CGROUPV2_PATCH
  else
    K8S_VERSION=$AIDEN_K8S_CGROUPV1_MINOR
    K8S_PATCH=$AIDEN_K8S_CGROUPV1_PATCH
  fi
}

aiden_cgroup_v1_notice() {
  echo -e "\e[33m⚠️  cgroup v1 detected — installing Kubernetes ${AIDEN_K8S_CGROUPV1_PATCH} instead of ${AIDEN_K8S_CGROUPV2_PATCH}.\e[0m"
  echo "   Kubernetes 1.35 and newer will not start on cgroup v1 by default."
  echo "   To use ${AIDEN_K8S_CGROUPV2_PATCH}, switch the host(s) to cgroup v2 and reboot, e.g. on RHEL-family systems:"
  echo "     grubby --update-kernel=ALL --args=\"systemd.unified_cgroup_hierarchy=1\""
}

# Run directly: report on this host
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  FSTYPE=$(aiden_cgroup_fstype)
  CG=$(aiden_cgroup_version_from_fstype "$FSTYPE")
  aiden_select_k8s_version "$CG"
  echo "cgroup version:         v${CG} (/sys/fs/cgroup is ${FSTYPE:-unknown})"
  echo "Kubernetes to install:  ${K8S_PATCH}"
  if [ "$CG" = "1" ]; then
    aiden_cgroup_v1_notice
  fi
fi
