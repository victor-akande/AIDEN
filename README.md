# AIDEN Lab Setup Scripts

This repository contains a collection of shell scripts that automate the installation, configuration, and teardown of AIDEN Lab in a Single-Node Kubernetes environment with Calico networking and KubeVirt.

---

## What is included

- `0-init.sh`
  - Sets up the base Linux host for Kubernetes.
  - Installs `containerd` and Kubernetes components (`kubeadm`, `kubelet`, `kubectl`).
  - Configures the system for Kubernetes networking.
  - Initializes a single-node Kubernetes cluster.
  - Installs the Calico Container Network Interface (CNI).

- `1-kubevirt-setup.sh`
  - Installs the latest KubeVirt operator and custom resources.
  - Downloads and installs the `virtctl` tool.
  - Pulls the custom AIDEN Lab disk image into the containerd image store.

- `2-deploy-vms.sh`
  - Deploys one or more AIDEN Lab instances in the Kubernetes cluster using KubeVirt.
  - Creates matching NodePort services so you can connect to each guest instance over RDP.

- `3-teardown.sh`
  - Attempts to remove the Kubernetes cluster and KubeVirt resources.
  - Removes installed packages, configuration files, and generated state.
  - Restores the system towards its previous state.

---

## Important notes before you begin

- These scripts are designed to be run on a Linux machine with root privileges.
- The scripts assume a package manager available through `dnf`.
- The scripts make changes to networking, firewall, and system configuration.
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

This script configures the host and builds the Kubernetes cluster.

```bash
sudo bash 0-init.sh
```

You will be asked for:

- a username to create
- a password for that user
- the Kubernetes version to install
- the Pod network range
- which network interface to use for the API server

> Note: You may choose to leave the default options if they meet your requirements.

The script then configures system settings, installs `containerd`, installs Kubernetes, initializes the cluster, and installs Calico.

### 2. Install KubeVirt and image tooling

After the initial host and Kubernetes setup is complete, run:

```bash
sudo bash 1-kubevirt-setup.sh
```

This script will:

- detect the latest KubeVirt release
- install the KubeVirt operator and CRDs
- install `virtctl`
- pull the latest AIDEN Lab container image for the VMs into containerd

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

Once completed, the script prints the RDP endpoint addresses for each VM.

### 4. Teardown and restore the system

When you want to remove the cluster and clean up changes, run:

```bash
sudo bash 3-teardown.sh
```

This script will attempt to:

- reset the Kubernetes cluster
- remove installed packages and configuration files
- clean up network changes
- restore swap, SELinux, and firewall settings
- delete a custom user if requested

> Note: Running the teardown script does not guarantee a perfect restoration in every environment. A reboot after teardown is strongly recommended.

---

## Tips for success

- Run the scripts in order: `0-init.sh`, then `1-kubevirt-setup.sh`, then `2-deploy-vms.sh`.
- If you are not sure which network interface to choose, select the one with the correct local IP address.
- Keep an eye on the script output for any errors.
- If the cluster becomes unstable or you need a fresh start, use `3-teardown.sh` and then rerun `0-init.sh`.

---

## Troubleshooting

- If `0-init.sh` fails while installing packages, make sure your system can reach the configured repositories and has a working internet connection.
- If `1-kubevirt-setup.sh` fails to pull the custom image, verify that `containerd` is running and that the image name is correct.
- If `kubectl` cannot connect after setup, ensure the Kubernetes control plane is up and `kubectl` is using `/etc/kubernetes/admin.conf`.

---

## Files at a glance

| File | Purpose |
|------|---------|
| `0-init.sh` | Initial host and Kubernetes setup with Calico networking |
| `1-kubevirt-setup.sh` | Install KubeVirt operator, CRDs, and `virtctl` |
| `2-deploy-vms.sh` | Create VMs and NodePort services for RDP access |
| `3-teardown.sh` | Clean up and restore the machine after use |

---

## Final reminder

These scripts are a convenience layer for environment setup. They make significant system changes, so use them carefully and only on a machine where you can safely perform package installs and networking changes.
