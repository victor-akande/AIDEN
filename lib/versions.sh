# shellcheck shell=bash
# ==========================================================
# Pinned component versions — the single place to change them.
# Sourced by the setup scripts; not meant to be executed.
#
# Kubernetes is chosen by check-cgroup.sh:
#   cgroup v2 -> AIDEN_K8S_CGROUPV2_*   (1.36)
#   cgroup v1 -> AIDEN_K8S_CGROUPV1_*   (1.34; kubelet >= 1.35 refuses
#                to start on cgroup v1 by default: failCgroupV1=true)
# ==========================================================

# Kubernetes (pkgs.k8s.io repo channel + exact package/control-plane version)
AIDEN_K8S_CGROUPV2_MINOR=v1.36
AIDEN_K8S_CGROUPV2_PATCH=1.36.6
AIDEN_K8S_CGROUPV1_MINOR=v1.34
AIDEN_K8S_CGROUPV1_PATCH=1.34.13

# Container runtime (containerd.io package from download.docker.com).
# Locked against 'dnf update' via exclude=containerd.io in docker-ce.repo.
AIDEN_CONTAINERD_VERSION=2.4.2

# Cilium CNI and CLIs
AIDEN_CILIUM_VERSION=1.20.4
AIDEN_CILIUM_CLI_VERSION=v0.20.2
AIDEN_HUBBLE_CLI_VERSION=v1.20.2

# KubeVirt (operator, CRs and virtctl)
AIDEN_KUBEVIRT_VERSION=v1.9.1

# Multi-node image distribution
AIDEN_HELM_VERSION=v4.3.1
AIDEN_SPEGEL_CHART_VERSION=0.8.1

# Helper images used by the image pre-warm DaemonSet
AIDEN_BUSYBOX_IMAGE=docker.io/library/busybox:1.36.1-musl
AIDEN_PAUSE_IMAGE=registry.k8s.io/pause:3.10
