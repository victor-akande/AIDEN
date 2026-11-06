# AIDEN Lab Setup Scripts

This repository contains a collection of shell scripts that automate the installation, configuration, and teardown of AIDEN Lab on Kubernetes (single-node or multi-node) with Cilium networking (kube-proxy replacement, BGP, L2 announcements, Hubble) and KubeVirt.

---

## What is included

- `0-init-singlenode.sh`
  - Sets up the base Linux host for Kubernetes.
  - Installs `containerd` and Kubernetes components (`kubeadm`, `kubelet`, `kubectl`).
  - Configures the system for Kubernetes networking.
  - Initializes a single-node Kubernetes cluster (control plane untainted so VMs can run on it).
  - Initializes the cluster without kube-proxy and installs the Cilium CNI as its replacement, with BGP, L2 announcements, and Hubble.

- `0-init-multinode.sh`
  - Does the same host preparation on the local machine (control plane) **and** on 1–3 worker nodes over SSH.
  - Initializes the control plane, joins the workers, and installs Cilium.

- `1-kubevirt-setup.sh`
  - Checks for hardware virtualization (`/dev/kvm`) and offers software emulation if it is missing.
  - Installs the pinned KubeVirt operator and custom resources.
  - Downloads and installs the `virtctl` tool.
  - Pulls the custom AIDEN Lab disk image into the containerd image store.
  - On multi-node clusters, installs [Spegel](https://github.com/spegel-org/spegel) and distributes the image peer-to-peer to every node, so it is downloaded from Docker Hub only once.

- `2-deploy-vms.sh`
  - Deploys one or more AIDEN Lab instances in the Kubernetes cluster using KubeVirt.
  - Creates matching NodePort services so you can connect to each guest instance over RDP.

- `3-teardown.sh`
  - Removes the Kubernetes cluster and KubeVirt resources (including worker nodes in multi-node setups).
  - Removes installed packages, configuration files, and generated state.
  - Restores swap, SELinux, and firewalld to the state recorded before setup.

---

## Important notes before you begin

- These scripts are designed to be run on a Linux machine with root privileges.
- The scripts assume a package manager available through `dnf` (RHEL / Rocky / Alma 9 family).
- The scripts make changes to networking, firewall, and system configuration.
- The VMs need hardware virtualization (`/dev/kvm`) on every node that runs them. Without it, KubeVirt can use software emulation, which is much slower.
- A reboot after teardown is recommended to fully restore the machine.

---

## Pinned versions

Every component is pinned in [`lib/versions.sh`](lib/versions.sh), the one place to change them:

| Component | Version |
|---|---|
| Kubernetes (cgroup v2 hosts) | 1.36.6 |
| Kubernetes (cgroup v1 hosts) | 1.34.13 |
| containerd | 2.4.2 |
| Cilium | 1.20.4 (CLI v0.20.2, Hubble CLI v1.20.2) |
| KubeVirt | v1.9.1 |
| Helm | v4.3.1 |
| Spegel chart | 0.8.1 |

The Kubernetes packages and containerd are locked at these versions: the `kubernetes` repo file and the `[docker-ce-stable]` section of `docker-ce.repo` each get an `exclude=` line, so a routine `dnf update` won't upgrade them. To upgrade on purpose, change `lib/versions.sh` or run `dnf` with `--disableexcludes=kubernetes` or `--disableexcludes=docker-ce-stable`.

KubeVirt 1.9 and Cilium 1.20 both officially support Kubernetes 1.34 through 1.36, so both Kubernetes versions are within their tested range.

### cgroup check

Kubernetes 1.35 and newer refuse to start the kubelet on cgroup v1 by default, so the init scripts pick the release automatically with [`check-cgroup.sh`](check-cgroup.sh):

- **cgroup v2**: Kubernetes 1.36
- **cgroup v1 or hybrid**: Kubernetes 1.34, the last release that runs on cgroup v1 by default

On multi-node setups every node is checked, and a single cgroup v1 node puts the whole cluster on 1.34, because all nodes must run the same release. To check a host before installing:

```bash
bash check-cgroup.sh
```

To move a RHEL-family host to cgroup v2, run `grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"` and reboot.

---

## Usage guide

### 0. Clone this repository

Start by copying the repository to your machine.

```bash
git clone https://github.com/victor-akande/aiden-lab-setup-scripts.git
cd aiden-lab-setup-scripts
chmod +x *.sh
```

### 1. Prepare and run the initial setup

Choose **one** of the two init scripts.

#### Option A — Single node

```bash
sudo bash 0-init-singlenode.sh
```

You will be asked for:

- a username to create (default `AIDEN`)
- a password for that user (default `AIDEN#`)
- the Pod network range (default `192.168.0.0/16`)
- which network interface to use for the API server
- the Cilium networking options (see [Cilium networking](#cilium-networking) below)

#### Option B — Multi-node (1 control plane + 1–3 workers)

Run this on the machine that will be the control plane:

```bash
sudo bash 0-init-multinode.sh
```

In addition to the prompts above, you will be asked for:

- the number of worker nodes (1, 2, or 3)
- the IP address and hostname of each worker
- the root SSH password for the worker nodes (all workers must share the same root password and allow root SSH login)

The password is used through `expect` and is only held in memory. It is never written to disk. Per-worker logs are written to `/var/log/aiden-lab/`.

> Note: You may choose to leave the default options if they meet your requirements.

#### Cilium networking

Both init scripts install Cilium with:

- **kube-proxy replacement** (`kubeProxyReplacement=true`). `kubeadm` runs with `--skip-phases=addon/kube-proxy`, and Cilium handles ClusterIP, NodePort, and LoadBalancer services in eBPF.
- **BGP Control Plane** (`bgpControlPlane.enabled=true`), only when you give a BGP peer
- **L2 announcements** (`l2announcements.enabled=true`), so LoadBalancer IPs answer ARP on the LAN
- **Hubble** with relay and UI, plus the `cilium` and `hubble` CLIs
- `socketLB.hostNamespaceOnly=true`, which Cilium recommends for KubeVirt VMs

You will be asked for (all optional, press Enter to skip):

| Prompt | Example | Used for |
|---|---|---|
| LoadBalancer IP pool | `10.0.0.240/28` or `10.0.0.240-10.0.0.250` | `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` |
| BGP peer IP | `10.0.0.1` | `CiliumBGPClusterConfig` peering with your router |
| Local / peer ASN | `65001` / `65000` | BGP session |

When a BGP peer is set, each node advertises its Pod CIDR and all LoadBalancer IPs.

**L2-only (no BGP):** enter an IP pool and leave the BGP peer blank. Cilium runs with BGP switched off and announces the LoadBalancer IPs on the LAN through ARP. In this mode:

- the pool must be in the nodes' subnet, and clients must be on the same layer-2 network (ARP does not cross routers)
- for each service, one node answers for its IP, and another takes over within a few seconds if that node fails; there is no load balancing across nodes for a single IP
- on nodes with several network cards, you may need to set Cilium's `devices` option so announcements go out on the right interface

To turn BGP on later, run `cilium upgrade --reuse-values --set bgpControlPlane.enabled=true`, restart the agents with `kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator`, then apply your own `CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, and `CiliumBGPAdvertisement`.

The generated resources are saved in `/var/lib/aiden-lab/cilium-network.yaml`, and you can edit and re-apply that file later. Set `CILIUM_VERSION=1.x.y` to override the pinned release (1.16 or newer).

Useful commands:

```bash
cilium status
```
```bash
cilium bgp peers
```
```bash
cilium hubble ui
```

Both scripts record the original SELinux, firewalld, and swap configuration in `/var/lib/aiden-lab/` so that `3-teardown.sh` can restore it later.

### 2. Install KubeVirt and image tooling

After the initial host and Kubernetes setup is complete, run:

```bash
sudo bash 1-kubevirt-setup.sh
```

This script will:

- check for `/dev/kvm` and, if it is missing, ask whether to enable software emulation
- install the KubeVirt operator and CRDs
- install `virtctl`
- pull the latest AIDEN Lab container image for the VMs into containerd (the only Docker Hub pull)
- on multi-node clusters: install Spegel and pre-warm the image on every node

#### How the image is distributed (multi-node)

The AIDEN Lab disk image is large, so it is pulled from Docker Hub **once**, on the control plane. Every other node gets it over the node network:

1. [Spegel](https://github.com/spegel-org/spegel) runs on every node as a small DaemonSet. It serves the images in each node's containerd store to the other nodes.
2. The init scripts configure containerd to read registry mirrors from `/etc/containerd/certs.d` and to keep layer blobs after unpacking (`discard_unpacked_layers = false`), so every node can serve what it has.
3. A short-lived pre-warm DaemonSet makes every node pull the image. containerd asks Spegel first and downloads the layers from whichever peers already have them. Each node that finishes becomes another source, and Docker Hub is used only if no node has a layer.

Nodes added to the cluster later get the image the same way. Set `SPEGEL_VERSION` to override the pinned Spegel chart version.

To skip the emulation prompt, set `KUBEVIRT_USE_EMULATION=true` or `false`. To override the pinned release, set `KUBEVIRT_VERSION=vX.Y.Z`.

### 3. Deploy one or more VMs

When the cluster is ready and KubeVirt is installed, deploy VMs with:

```bash
bash 2-deploy-vms.sh
```

You will be asked for:

- number of VMs to create
- memory per VM
- CPU cores per VM
- VM name prefix
- how to expose RDP:
  - **NodePort**: `<node-ip>:30001`, `30002`, ... (you choose the starting port)
  - **LoadBalancer**: each VM gets its own IP from the Cilium pool on the standard port, for example `10.0.0.241:3389`. This is the default when a pool exists.

With NodePort, ports that are already in use are skipped automatically. Re-running with the same prefix keeps each existing VM's port. Live migration (`evictionStrategy: LiveMigrate`) is only enabled when the cluster has at least two schedulable nodes.

Once completed, the script prints the RDP endpoint addresses for each VM. With LoadBalancer, it waits for Cilium to assign each IP first. If an IP stays `<pending>`, the pool has run out of free addresses.

### 4. Teardown and restore the system

When you want to remove the cluster and clean up changes, run on the control plane / single node:

```bash
sudo bash 3-teardown.sh
```

This script will:

- tear down the recorded worker nodes over SSH (multi-node setups; you will be asked for the root password)
- reset the Kubernetes cluster
- remove installed packages and configuration files
- clean up network changes (iptables rules, Cilium/CNI interfaces, and BPF state)
- remove the `cilium`, `hubble`, and `helm` CLIs, but only those the setup installed
- re-enable exactly the swap entries that setup disabled
- restore SELinux and firewalld to their original state (they are **not** forced on if they were off before setup)
- optionally delete the user created during setup

If no recorded state is found (for example, the machine was set up with an older version of these scripts), swap, SELinux, and firewalld are left unchanged and a warning is printed.

> Note: Running the teardown script does not guarantee a perfect restoration in every environment. A reboot after teardown is strongly recommended.

---

## Tips for success

- Run the scripts in order: `0-init-singlenode.sh` (or `0-init-multinode.sh`), then `1-kubevirt-setup.sh`, then `2-deploy-vms.sh`.
- If you are not sure which network interface to choose, select the one with the correct local IP address.
- Keep an eye on the script output for any errors.
- If the cluster becomes unstable or you need a fresh start, use `3-teardown.sh` and then rerun the init script.

---

## Troubleshooting

- If an init script fails while installing packages, make sure your system can reach the configured repositories and has a working internet connection.
- If a worker fails during multi-node setup, check `/var/log/aiden-lab/prep-<hostname>.log` or `join-<hostname>.log`.
- If `1-kubevirt-setup.sh` fails to pull the custom image, verify that `containerd` is running and that the image name is correct.
- If VMs stay in `Scheduling` or fail to start, check that `/dev/kvm` exists on the nodes, or re-run `1-kubevirt-setup.sh` with `KUBEVIRT_USE_EMULATION=true`.
- If pods cannot reach services, run `cilium status` and `cilium connectivity test`.
- If BGP sessions do not come up, check `cilium bgp peers` and make sure your router is configured to peer with every node IP.
- If a node is slow to receive the image, check the Spegel pods with `kubectl -n spegel get pods -o wide` and their logs.
- If `kubectl` cannot connect after setup, ensure the Kubernetes control plane is up and `kubectl` is using `/etc/kubernetes/admin.conf`.

---

## Files at a glance

| File | Purpose |
|------|---------|
| `0-init-singlenode.sh` | Single-node host and Kubernetes setup with Cilium networking |
| `0-init-multinode.sh` | Control plane + 1–3 worker nodes setup with Cilium networking |
| `1-kubevirt-setup.sh` | Install KubeVirt operator, CRDs, `virtctl`, and (multi-node) Spegel image distribution |
| `check-cgroup.sh` | Detects cgroup v1/v2 and picks Kubernetes 1.36 or 1.34 (run alone or sourced by the init scripts) |
| `lib/versions.sh` | All pinned component versions |
| `lib/cilium.sh` | Shared Cilium install and network config, sourced by both init scripts |
| `2-deploy-vms.sh` | Create VMs and NodePort services for RDP access |
| `3-teardown.sh` | Clean up and restore the machine (and workers) after use |

---

## Final reminder

These scripts are a convenience layer for environment setup. They make significant system changes, so use them carefully and only on a machine where you can safely perform package installs and networking changes.
