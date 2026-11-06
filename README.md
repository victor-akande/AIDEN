# AIDEN Lab Setup Scripts

This repository contains a collection of shell scripts that automate the installation, configuration, and teardown of AIDEN Lab on Kubernetes (single-node or multi-node) with Calico networking and KubeVirt.

---

## What is included

- `0-init-singlenode.sh`
  - Sets up the base Linux host for Kubernetes.
  - Installs `containerd` and Kubernetes components (`kubeadm`, `kubelet`, `kubectl`).
  - Configures the system for Kubernetes networking.
  - Initializes a single-node Kubernetes cluster (control plane untainted so VMs can run on it).
  - Installs the Calico Container Network Interface (CNI).

- `0-init-multinode.sh`
  - Does the same host preparation on the local machine (control plane) **and** on 1–3 worker nodes over SSH.
  - Initializes the control plane, joins the workers, and installs Calico.

- `1-kubevirt-setup.sh`
  - Checks for hardware virtualization (`/dev/kvm`) and offers software emulation if it is missing.
  - Installs the latest KubeVirt operator and custom resources.
  - Downloads and installs the `virtctl` tool.
  - Pulls the custom AIDEN Lab disk image into the containerd image store.

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
- the Kubernetes version to install (default `v1.33`)
- the Pod network range (default `192.168.0.0/16`)
- which network interface to use for the API server

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

Both scripts record the original SELinux, firewalld, and swap configuration in `/var/lib/aiden-lab/` so that `3-teardown.sh` can restore it later.

### 2. Install KubeVirt and image tooling

After the initial host and Kubernetes setup is complete, run:

```bash
sudo bash 1-kubevirt-setup.sh
```

This script will:

- check for `/dev/kvm` and, if it is missing, ask whether to enable software emulation
- detect the latest KubeVirt release
- install the KubeVirt operator and CRDs
- install `virtctl`
- pull the latest AIDEN Lab container image for the VMs into containerd

To skip the emulation prompt, set `KUBEVIRT_USE_EMULATION=true` or `false`. To pin a release, set `KUBEVIRT_VERSION=vX.Y.Z`.

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
- starting RDP NodePort (default `30001`)

Ports that are already in use are skipped automatically. Re-running with the same prefix keeps each existing VM's port. Live migration (`evictionStrategy: LiveMigrate`) is only enabled when the cluster has at least two schedulable nodes.

Once completed, the script prints the RDP endpoint addresses for each VM.

### 4. Teardown and restore the system

When you want to remove the cluster and clean up changes, run on the control plane / single node:

```bash
sudo bash 3-teardown.sh
```

This script will:

- tear down the recorded worker nodes over SSH (multi-node setups; you will be asked for the root password)
- reset the Kubernetes cluster
- remove installed packages and configuration files
- clean up network changes (iptables rules and Calico/CNI interfaces)
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
- If `kubectl` cannot connect after setup, ensure the Kubernetes control plane is up and `kubectl` is using `/etc/kubernetes/admin.conf`.

---

## Files at a glance

| File | Purpose |
|------|---------|
| `0-init-singlenode.sh` | Single-node host and Kubernetes setup with Calico networking |
| `0-init-multinode.sh` | Control plane + 1–3 worker nodes setup with Calico networking |
| `1-kubevirt-setup.sh` | Install KubeVirt operator, CRDs, and `virtctl` |
| `2-deploy-vms.sh` | Create VMs and NodePort services for RDP access |
| `3-teardown.sh` | Clean up and restore the machine (and workers) after use |

---

## Final reminder

These scripts are a convenience layer for environment setup. They make significant system changes, so use them carefully and only on a machine where you can safely perform package installs and networking changes.
