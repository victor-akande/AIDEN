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

# 2. Configuration 
IMAGE_NAME="docker.io/victhedev/aiden:latest"
IMAGE_PATH="/disk/disk.qcow2" 
USERNAME="AIDEN"
PASSWORD="AIDEN"
MANIFEST_FILE="temp_vms.yaml"

# Get Node IP for the final summary
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Clean up temp file
> "$MANIFEST_FILE"

echo "Generating batch manifest for $VM_COUNT VMs..."

# 3. Build the single manifest
for ((i=1; i<=VM_COUNT; i++))
do
  VM_NAME="${VM_PREFIX}-${i}"
  NODE_PORT=$((30000 + i))

  cat <<EOF >> "$MANIFEST_FILE"
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  labels:
    app: ${VM_PREFIX}
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
        app: ${VM_PREFIX}
    spec:
      evictionStrategy: LiveMigrate
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
rm "$MANIFEST_FILE"

echo "=========================================================="
echo "✅ Deployment Complete!"
echo "To monitor: kubectl get vmi -w"
echo "To cleanup: kubectl delete vm,svc -l app=${VM_PREFIX}"
echo "----------------------------------------------------------"
echo "RDP Credentials: $USERNAME / $PASSWORD"
for ((i=1; i<=VM_COUNT; i++))
do
  echo "  - ${VM_PREFIX}-${i} -> ${NODE_IP}:$((30000 + i))"
done
echo "=========================================================="
