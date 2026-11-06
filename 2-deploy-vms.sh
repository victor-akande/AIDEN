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

# RDP exposure: LoadBalancer gives each VM its own LAN IP on port 3389,
# announced by Cilium (L2/ARP and/or BGP). It needs a CiliumLoadBalancerIPPool.
LB_POOLS=$(kubectl get ciliumloadbalancerippools.cilium.io --no-headers 2>/dev/null | wc -l || true)
if [ "${LB_POOLS:-0}" -gt 0 ]; then
  DEFAULT_SVC=2
else
  DEFAULT_SVC=1
fi
echo "How should RDP be exposed?"
echo "  [1] NodePort      -> <node-ip>:30001, 30002, ..."
echo "  [2] LoadBalancer  -> <own-ip>:3389 per VM (needs a Cilium LoadBalancer IP pool)"
read -p "Select service type [$DEFAULT_SVC]: " SVC_CHOICE
SVC_CHOICE=${SVC_CHOICE:-$DEFAULT_SVC}
case "$SVC_CHOICE" in
  1) SVC_TYPE=NodePort ;;
  2) SVC_TYPE=LoadBalancer ;;
  *) echo "Invalid choice: $SVC_CHOICE" >&2; exit 1 ;;
esac

if [ "$SVC_TYPE" = "LoadBalancer" ] && [ "${LB_POOLS:-0}" -eq 0 ]; then
  echo "No CiliumLoadBalancerIPPool found, so LoadBalancer services would never get an IP." >&2
  echo "Create one (see README: Cilium networking) or choose NodePort." >&2
  exit 1
fi

if [ "$SVC_TYPE" = "NodePort" ]; then
  read -p "Enter starting RDP NodePort (30000-32767) [30001]: " START_PORT
  START_PORT=${START_PORT:-30001}
  if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 30000 ] || [ "$START_PORT" -gt 32767 ]; then
    echo "Starting port must be a number between 30000 and 32767." >&2
    exit 1
  fi
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
echo "-> RDP service type: $SVC_TYPE"

if [ "$SVC_TYPE" = "NodePort" ]; then
  # NodePorts already taken anywhere in the cluster
  USED_PORTS=" $(kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{" "}{end}') "
  NEXT_PORT=$START_PORT
fi

declare -a VM_PORTS

echo "Generating batch manifest for $VM_COUNT VMs..."

# 3. Build the single manifest
for ((i=1; i<=VM_COUNT; i++))
do
  VM_NAME="${VM_PREFIX}-${i}"

  if [ "$SVC_TYPE" = "NodePort" ]; then
    # Reuse the port if this VM's NodePort service already exists (re-run/update),
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
    SVC_SPEC="  type: NodePort
  selector:
    kubevirt.io/domain: ${VM_NAME}
  ports:
    - protocol: TCP
      port: 3389
      targetPort: 3389
      nodePort: ${NODE_PORT}"
  else
    # No NodePort needed: Cilium answers for the LB IP directly
    SVC_SPEC="  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
  selector:
    kubevirt.io/domain: ${VM_NAME}
  ports:
    - protocol: TCP
      port: 3389
      targetPort: 3389"
  fi

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
${SVC_SPEC}
---
EOF
done

# 4. Deploy
echo "Applying manifests..."
kubectl apply -f "$MANIFEST_FILE"

# 5. For LoadBalancer services, wait for Cilium LB IPAM to assign IPs
if [ "$SVC_TYPE" = "LoadBalancer" ]; then
  echo "Waiting for LoadBalancer IPs to be assigned..."
  for ((i=1; i<=VM_COUNT; i++)); do
    VM_NAME="${VM_PREFIX}-${i}"
    LB_IP=""
    for _ in $(seq 1 30); do
      LB_IP=$(kubectl get svc "${VM_NAME}-rdp" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      [ -n "$LB_IP" ] && break
      sleep 2
    done
    VM_PORTS+=("${LB_IP:-<pending>}")
  done
fi

echo "=========================================================="
echo "✅ Deployment Complete!"
echo "To monitor: kubectl get vmi -w"
echo "To cleanup: kubectl delete vm,svc -l app=${VM_PREFIX}"
echo "----------------------------------------------------------"
echo "RDP Credentials: $USERNAME / $PASSWORD"
for ((i=1; i<=VM_COUNT; i++))
do
  if [ "$SVC_TYPE" = "NodePort" ]; then
    echo "  - ${VM_PREFIX}-${i} -> ${NODE_IP}:${VM_PORTS[$((i-1))]}"
  else
    echo "  - ${VM_PREFIX}-${i} -> ${VM_PORTS[$((i-1))]}:3389"
  fi
done
if [ "$SVC_TYPE" = "LoadBalancer" ] && [[ " ${VM_PORTS[*]} " == *"<pending>"* ]]; then
  echo "Some IPs are still pending. Check the pool has free addresses: kubectl get ciliumloadbalancerippools"
fi
echo "=========================================================="
