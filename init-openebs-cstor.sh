#!/bin/bash
set -e

# Step 1: 安装 OpenEBS 核心组件
kubectl apply -f https://openebs.github.io/charts/openebs-operator.yaml
echo "Waiting for OpenEBS NDM to be ready..."
kubectl rollout status deployment -n openebs openebs-ndm-operator

# Step 2: 安装 CStor CSI
kubectl apply -f https://openebs.github.io/charts/cstor-operator.yaml
echo "Waiting for CStor CSI operator to be ready..."
kubectl rollout status deploy cspc-operator -n openebs
kubectl rollout status deploy cvc-operator -n openebs

# Step 3: 获取可用 blockdevice 和节点
echo "Collecting available block devices..."
# 获取所有 Unclaimed blockdevice 的 <node> <bd-name> 列表
mapfile -t bd_info < <(kubectl get bd -n openebs -o jsonpath='{range .items[?(@.status.claimState=="Unclaimed")]}{.spec.nodeAttributes.nodeName}{"|"}{.metadata.name}{"\n"}{end}' | sort -u)
# 分组构建 CSPC 的 pools
pools=""
declare -A node_seen
for info in "${bd_info[@]}"; do
  NODE="${info%%|*}"
  BD="${info##*|}"

  # 每个节点只取一个 blockdevice
  if [[ -z "${node_seen[$NODE]}" ]]; then
    node_seen[$NODE]=1

    pools+="
    - nodeSelector:
        kubernetes.io/hostname: \"$NODE\"
      dataRaidGroups:
        - blockDevices:
            - blockDeviceName: \"$BD\"
      poolConfig:
        dataRaidGroupType: \"stripe\""
  fi
done
if [[ -z "$pools" ]]; then
  echo "No available unclaimed block devices found across nodes."
  exit 1
fi

# Step 4: 创建 CStorPoolCluster
echo "Generating CStorPoolCluster for nodes: ${!node_seen[*]}"
cat <<EOF | kubectl apply -f -
apiVersion: cstor.openebs.io/v1
kind: CStorPoolCluster
metadata:
  name: cstor-disk-pool
  namespace: openebs
spec:
  pools:$pools
EOF

# Step 5: 创建 StorageClass（CSI Provisioner）
# 获取当前 CStorPoolInstance 数量（即节点上已部署的 pool 数）
pool_count=$(kubectl get cstorpoolinstances -n openebs --no-headers 2>/dev/null | wc -l)
if [[ "$pool_count" -eq 0 ]]; then
  echo "No available CStorPoolInstance, cannot create StorageClass。"
  exit 1
fi
# 根据 pool 数量设定 replicaCount（最大3，最小1）
if (( pool_count >= 3 )); then
  replica_count=3
elif (( pool_count == 2 )); then
  replica_count=2
else
  replica_count=1
fi
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-cstor
provisioner: cstor.csi.openebs.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
parameters:
  cas-type: cstor
  cstorPoolCluster: cstor-disk-pool
  replicaCount: "$replica_count"
EOF
