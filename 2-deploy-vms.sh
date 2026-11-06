#!/bin/bash
set -e

echo "=========================================================="
echo "🖥️  Interactive Aiden Lab VM Deployment"
echo "=========================================================="

# 1. Collect Inputs
read -p "Enter the number of VMs to create [1]: " VM_COUNT
VM_COUNT=${VM_COUNT:-1}

read -p "Enter Memory per VM (e.g., 4Gi, 8Gi) [8Gi]: " VM_MEMORY
VM_MEMORY=${VM_MEMORY:-8Gi}

read -p "Enter CPU Cores per VM [2]: " VM_CORES
VM_CORES=${VM_CORES:-2}

read -p "Enter VM Name Prefix [aiden-labs]: " VM_PREFIX
VM_PREFIX=${VM_PREFIX:-aiden-labs}

read -p "Enter starting RDP NodePort (30000-32767) [30001]: " START_PORT
START_PORT=${START_PORT:-30001}
if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 30000 ] || [ "$START_PORT" -gt 32767 ]; then
  echo "Starting port must be a number between 30000 and 32767." >&2
  exit 1
fi

# 2. Configuration
IMAGE_NAME="docker.io/victhedev/aiden:latest"
IMAGE_PATH="/disk/disk.qcow2"   # path inside the container image
USERNAME="AIDEN"
PASSWORD="AIDEN"
MANIFEST_FILE=$(mktemp /tmp/aiden-vms.XXXXXX.yaml)
trap 'rm -f "$MANIFEST_FILE"' EXIT

# Get Node IP for the final summary
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Live migration needs at least two nodes that can run VMs. On a single
# schedulable node, LiveMigrate would block node drains forever.
SCHEDULABLE_NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[*].effect}{"\n"}{end}' \
  | grep -vc NoSchedule || true)
if [ "${SCHEDULABLE_NODES:-0}" -ge 2 ]; then
  EVICTION_STRATEGY="LiveMigrate"
else
  EVICTION_STRATEGY="None"
fi
echo "-> Schedulable nodes: ${SCHEDULABLE_NODES:-0} (evictionStrategy: $EVICTION_STRATEGY)"

# NodePorts already taken anywhere in the cluster
USED_PORTS=" $(kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{" "}{end}') "

declare -a VM_PORTS
NEXT_PORT=$START_PORT

echo "Generating batch manifest for $VM_COUNT VMs..."

# 3. Build the single manifest
for ((i=1; i<=VM_COUNT; i++))
do
  VM_NAME="${VM_PREFIX}-${i}"

  # Reuse the port if this VM's service already exists (re-run/update),
  # otherwise take the next free port.
  EXISTING_PORT=$(kubectl get svc "${VM_NAME}-rdp" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
  if [ -n "$EXISTING_PORT" ]; then
    NODE_PORT=$EXISTING_PORT
  else
    while [[ "$USED_PORTS" == *" $NEXT_PORT "* ]]; do
      NEXT_PORT=$((NEXT_PORT + 1))
    done
    if [ "$NEXT_PORT" -gt 32767 ]; then
      echo "Ran out of free NodePorts in the 30000-32767 range." >&2
      exit 1
    fi
    NODE_PORT=$NEXT_PORT
    USED_PORTS="$USED_PORTS$NODE_PORT "
  fi
  VM_PORTS+=("$NODE_PORT")

  cat <<EOF >> "$MANIFEST_FILE"
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  labels:
    app: ${VM_PREFIX}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
        app: ${VM_PREFIX}
    spec:
      evictionStrategy: ${EVICTION_STRATEGY}
      domain:
        cpu:
          cores: ${VM_CORES}
        resources:
          requests:
            memory: "${VM_MEMORY}"
          limits:
            memory: "${VM_MEMORY}"
        devices:
          disks:
          - name: bootdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
            ports:
            - port: 3389
      networks:
      - name: default
        pod: {}
      volumes:
      - name: bootdisk
        containerDisk:
          image: ${IMAGE_NAME}
          path: ${IMAGE_PATH}
          imagePullPolicy: IfNotPresent
---
apiVersion: v1
kind: Service
metadata:
  name: ${VM_NAME}-rdp
  labels:
    app: ${VM_PREFIX}
spec:
  type: NodePort
  selector:
    kubevirt.io/domain: ${VM_NAME}
  ports:
    - protocol: TCP
      port: 3389
      targetPort: 3389
      nodePort: ${NODE_PORT}
---
EOF
done

# 4. Deploy
echo "Applying manifests..."
kubectl apply -f "$MANIFEST_FILE"

echo "=========================================================="
echo "✅ Deployment Complete!"
echo "To monitor: kubectl get vmi -w"
echo "To cleanup: kubectl delete vm,svc -l app=${VM_PREFIX}"
echo "----------------------------------------------------------"
echo "RDP Credentials: $USERNAME / $PASSWORD"
for ((i=1; i<=VM_COUNT; i++))
do
  echo "  - ${VM_PREFIX}-${i} -> ${NODE_IP}:${VM_PORTS[$((i-1))]}"
done
echo "=========================================================="
