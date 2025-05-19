# OpenEBS Stack 扩容文档

本文档详细介绍了 OpenEBS Stack 在单机和高可用部署模式下的扩容操作步骤和验证方法。通过适当的扩容，可以提高系统的性能、可用性和容错能力。

## 目录

- [概述](#概述)
- [前置准备](#前置准备)
- [单机部署扩容](#单机部署扩容)
- [高可用部署扩容](#高可用部署扩容)
- [组件缩容指南](#组件缩容指南)
- [扩容验证](#扩容验证)
- [常见问题](#常见问题)

## 概述

OpenEBS Stack 包含多个组件，每个组件都可以根据需求进行独立扩容：

- **PostgreSQL**：增加副本数量提高可用性，或调整资源配置提高性能
- **Redis**：增加副本和哨兵数量，加强缓存服务的高可用性
- **Kafka**：增加 Controller 节点数量，提高消息处理能力
- **RabbitMQ**：增加集群节点，提升消息队列处理能力
- **Kafka Connect**：增加副本数量，提高数据同步的并行度
- **Quickwit**：增加搜索节点，提高索引和查询性能

## 前置准备

执行扩容操作前，请确保：

1. 已安装并正常运行 OpenEBS Stack
2. 集群资源充足（CPU、内存、存储）
3. 已安装 kubectl 1.19+
4. 具有集群管理员权限

## 单机部署扩容

单机版部署通常用于开发和测试环境。虽然单机版默认不提供高可用性，但您仍可以进行一定程度的扩容来提高性能。

### PostgreSQL 扩容

单机版默认使用单节点 PostgreSQL，不支持主从复制。如需高可用，建议切换到高可用部署。

#### 资源扩容

```bash
# 增加 PostgreSQL 资源限制
kubectl patch statefulset openebs-stack-postgresql -p '{"spec":{"template":{"spec":{"containers":[{"name":"postgresql","resources":{"requests":{"memory":"2Gi"},"limits":{"memory":"4Gi"}}}]}}}}'
```

#### 存储扩容

```bash
# 增加 PostgreSQL 存储容量（注意：需要 StorageClass 支持卷扩展）
kubectl patch pvc data-openebs-stack-postgresql-0 -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

### Kafka 扩容

```bash
# 增加 Kafka 资源配置
kubectl patch statefulset openebs-stack-kafka-controller -p '{"spec":{"template":{"spec":{"containers":[{"name":"kafka","resources":{"requests":{"memory":"2Gi"},"limits":{"memory":"4Gi"}}}]}}}}'

# 增加 Kafka 存储容量
kubectl patch pvc data-openebs-stack-kafka-controller-0 -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

### Redis 扩容

单机版 Redis 默认为单实例模式，如需高可用，建议切换到高可用部署。

```bash
# 增加 Redis 资源配置
kubectl patch statefulset openebs-stack-redis-master -p '{"spec":{"template":{"spec":{"containers":[{"name":"redis","resources":{"requests":{"memory":"1Gi"},"limits":{"memory":"2Gi"}}}]}}}}'

# 增加 Redis 存储容量
kubectl patch pvc redis-data-openebs-stack-redis-master-0 -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
```

### Kafka Connect 扩容

```bash
# 增加 Kafka Connect 副本数
kubectl scale deployment openebs-stack-kafka-connect --replicas=2
```

### Quickwit 扩容

```bash
# 增加 Quickwit 副本数
kubectl scale deployment openebs-stack-quickwit --replicas=2

# 增加 Quickwit 资源配置
kubectl patch deployment openebs-stack-quickwit -p '{"spec":{"template":{"spec":{"containers":[{"name":"quickwit","resources":{"requests":{"memory":"1Gi"},"limits":{"memory":"2Gi"}}}]}}}}'
```

## 高可用部署扩容

高可用部署提供更全面的扩容选项，可以同时提高系统的性能和可用性。

### PostgreSQL-HA 扩容

PostgreSQL 高可用版使用 Repmgr 管理主从复制。

#### 扩容副本数

```bash
# 增加 PostgreSQL 副本数（默认为 3）
kubectl patch statefulset openebs-stack-postgresql-ha-postgresql -p '{"spec":{"replicas":5}}'
```

#### 扩容连接池

```bash
# 增加 Pgpool 连接池副本数
kubectl patch deployment openebs-stack-postgresql-ha-pgpool -p '{"spec":{"replicas":3}}'
```

#### 资源扩容

```bash
# 增加 PostgreSQL 资源限制
kubectl patch statefulset openebs-stack-postgresql-ha-postgresql -p '{"spec":{"template":{"spec":{"containers":[{"name":"postgresql-ha","resources":{"requests":{"memory":"1Gi"},"limits":{"memory":"2Gi"}}}]}}}}'
```

#### 存储扩容

```bash
# 增加 PostgreSQL 存储容量
kubectl get pvc -l app.kubernetes.io/name=postgresql-ha -o name | xargs -I{} kubectl patch {} -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

### Redis 扩容

高可用版 Redis 使用 Sentinel 模式。

```bash
# 增加 Redis 主从副本数
kubectl patch statefulset openebs-stack-redis-node -p '{"spec":{"replicas":5}}'

# 增加 Redis Sentinel 哨兵数量
kubectl patch statefulset openebs-stack-redis-sentinel -p '{"spec":{"replicas":5}}'
```

### Kafka 扩容

高可用版 Kafka 使用 KRaft 模式。

```bash
# 增加 Kafka Controller 节点数
kubectl patch statefulset openebs-stack-kafka-controller -p '{"spec":{"replicas":5}}'

# 增加 Kafka 资源配置
kubectl patch statefulset openebs-stack-kafka-controller -p '{"spec":{"template":{"spec":{"containers":[{"name":"kafka","resources":{"requests":{"memory":"6Gi"},"limits":{"memory":"12Gi"}}}]}}}}'
```

### RabbitMQ 扩容

```bash
# 增加 RabbitMQ 节点数
kubectl patch statefulset openebs-stack-rabbitmq -p '{"spec":{"replicas":5}}'

# 增加 RabbitMQ 资源配置
kubectl patch statefulset openebs-stack-rabbitmq -p '{"spec":{"template":{"spec":{"containers":[{"name":"rabbitmq","resources":{"requests":{"memory":"1Gi"},"limits":{"memory":"2Gi"}}}]}}}}'
```

### Kafka Connect 扩容

```bash
# 增加 Kafka Connect 副本数
kubectl scale deployment openebs-stack-kafka-connect --replicas=5

# 更新 Kafka Connect 复制因子配置
# 首先获取当前ConfigMap
kubectl get configmap openebs-stack-kafka-connect-config -o yaml > kafka-connect-config.yaml
# 编辑文件修改复制因子相关配置
# 然后应用更改
kubectl apply -f kafka-connect-config.yaml
```

### Quickwit 扩容

```bash
# 增加 Quickwit 副本数
kubectl scale statefulset openebs-stack-quickwit --replicas=5
```

> **重要提示**：当更改 Kafka、Kafka Connect 或 Quickwit 的副本数时，您可能需要重新配置数据流，特别是更新复制因子相关的配置。建议执行相应的数据流设置命令。

## 组件缩容指南

系统扩容后，如需缩减资源以优化成本，可执行缩容操作。本章节详细说明各组件缩容的步骤、注意事项及对数据的影响。

### 缩容通用注意事项

1. **PVC处理**：缩容StatefulSet时，被移除节点的PVC默认不会自动删除，将保持"Released"状态
2. **数据安全**：执行缩容前确保重要数据已备份或迁移
3. **最佳时机**：选择系统负载较低的时段执行缩容
4. **节点选择**：通常从高索引节点开始缩容（例如先移除index-4，再移除index-3）
5. **最小节点数**：高可用部署建议保留至少3个节点以维持集群稳定性

### Redis缩容

Redis使用主从复制模式，每个节点数据相似但不完全相同。

```bash
# Redis节点缩容（例如从5个缩减到3个）
kubectl patch statefulset openebs-stack-redis-node -p '{"spec":{"replicas":3}}'

# Redis Sentinel缩容（应与节点数匹配）
kubectl patch statefulset openebs-stack-redis-sentinel -p '{"spec":{"replicas":3}}'
```

**数据影响**：
- 主节点存储完整数据，从节点存储数据副本
- 缩容从节点影响较小，仅减少冗余度
- 缩容主节点会触发主节点切换
- 建议至少保留3个节点以维持哨兵机制正常工作

**PVC处理**：
```bash
# 列出相关PVC
kubectl get pvc | grep openebs-stack-redis

# 手动删除不再需要的PVC（确认数据安全后）
kubectl delete pvc redis-data-openebs-stack-redis-node-3
kubectl delete pvc redis-data-openebs-stack-redis-node-4
```

### RabbitMQ缩容

RabbitMQ是分布式集群系统，不同节点PVC内容差异较大。

**缩容前准备**：
1. 将目标节点设为维护模式，停止接收新消息
2. 确保节点上的消息被消费完毕或已迁移
3. 正确从集群中移除节点

```bash
# 1. 查看集群状态
kubectl exec -it openebs-stack-rabbitmq-0 -- rabbitmqctl cluster_status

# 2. 将节点设为维护模式
kubectl exec -it openebs-stack-rabbitmq-0 -- rabbitmqctl set_policy \
  --priority 1000 --apply-to all "ha-all" "." '{"ha-mode":"all","ha-sync-mode":"automatic"}'

# 3. 从集群中移除节点（从高索引开始）
kubectl exec -it openebs-stack-rabbitmq-0 -- rabbitmqctl forget_cluster_node rabbit@openebs-stack-rabbitmq-4

# 4. 执行缩容
kubectl patch statefulset openebs-stack-rabbitmq -p '{"spec":{"replicas":3}}'
```

**数据影响**：
- 每个节点存储不同的队列数据和元数据
- 直接缩容可能导致消息丢失
- 镜像队列会失去部分副本，降低高可用性

**PVC处理**：
```bash
# 缩容并确认集群稳定后，删除不再需要的PVC
kubectl delete pvc data-openebs-stack-rabbitmq-3
kubectl delete pvc data-openebs-stack-rabbitmq-4
```

### Kafka缩容

Kafka集群数据以分区形式分布，缩容前必须重新分配分区。

**缩容前分区重新分配**：
```bash
# 1. 创建要迁移的主题列表（示例为迁移所有主题）
cat > topics.json << EOF
{
  "topics": [
    {"topic": "*"}
  ],
  "version": 1
}
EOF

# 2. 生成重新分配计划（假设保留broker 0,1,2）
kubectl exec -it openebs-stack-kafka-controller-0 -- kafka-reassign-partitions.sh \
  --bootstrap-server localhost:9092 \
  --generate \
  --topics-to-move-json-file topics.json \
  --broker-list "0,1,2" > reassignment-plan.json

# 3. 检查并编辑生成的计划（需要将文件复制出容器）
kubectl cp openebs-stack-kafka-controller-0:reassignment-plan.json ./reassignment-plan.json
# 检查并修改文件
kubectl cp ./reassignment-plan.json openebs-stack-kafka-controller-0:reassignment-plan.json

# 4. 执行重新分配
kubectl exec -it openebs-stack-kafka-controller-0 -- kafka-reassign-partitions.sh \
  --bootstrap-server localhost:9092 \
  --execute \
  --reassignment-json-file reassignment-plan.json

# 5. 监控重新分配进度
kubectl exec -it openebs-stack-kafka-controller-0 -- kafka-reassign-partitions.sh \
  --bootstrap-server localhost:9092 \
  --verify \
  --reassignment-json-file reassignment-plan.json
```

**确认分区迁移完成后执行缩容**：
```bash
# 执行Kafka缩容
kubectl patch statefulset openebs-stack-kafka-controller -p '{"spec":{"replicas":3}}'
```

**数据影响**：
- 每个节点存储特定的分区数据
- 未正确迁移的分区可能变得不可用
- 确保复制因子设置不超过缩容后的节点数

**PVC处理**：
```bash
# 确认所有分区可用后，删除不再需要的PVC
kubectl delete pvc data-openebs-stack-kafka-controller-3
kubectl delete pvc data-openebs-stack-kafka-controller-4
```

### PostgreSQL-HA缩容

PostgreSQL-HA使用复制管理器(Repmgr)，缩容需谨慎处理主节点和从节点角色。缩容时必须确保不会移除当前的主节点，否则可能导致服务中断。

> **重要警告**：直接缩容包含主节点的集群（例如移除当前为index-4或index-5的主节点）会触发紧急故障转移，这可能导致：
> - 不可预测的服务中断（长达数分钟）
> - 应用程序写入错误和连接断开
> - 最近提交的事务可能丢失
> - 数据不一致风险
> - 在高负载系统中可能引发连锁故障
>
> 始终使用下面描述的计划迁移方法，而非依赖自动故障转移。

**确认主节点位置并安全缩容**：

```bash
# 1. 首先识别当前的主节点
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- /opt/bitnami/scripts/postgresql-repmgr/entrypoint.sh repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show

# 2. 假设当前Pod-1是主节点，需要将Pod-1变为备用节点
# 停止Pod-1上的PostgreSQL服务
kubectl exec -it openebs-stack-postgresql-ha-postgresql-1 -c postgresql -- bash -c "pg_ctl stop -m fast
 -D /bitnami/postgresql/data"

# 3. 查看整体复制状态，确定新选举的主节点
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- /opt/bitnami/scripts/postgresql-repmgr/entrypoint.sh repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show

# 4. 确认主节点已成功切换到低索引Pod后，执行缩容
kubectl patch statefulset openebs-stack-postgresql-ha-postgresql -p '{"spec":{"replicas":3}}'

# 5. 更新应用程序连接池以识别新的主节点
# 这通常会由pgpool自动处理，但最好验证一下
```

**重要提示**：
- 缩容前必须确保集群处于健康状态，只有一个活跃的主节点
- 切换主节点会导致写入操作短暂中断（通常数秒到数十秒）
- 理想情况下，在非业务高峰期执行这些操作
- 执行任何操作前确保有当前数据的备份
- 如果需要缩容包含主节点的实例，使用上述计划迁移方法，不要依赖自动故障转移

**验证缩容结果**：
```bash
# 检查剩余Pod状态
kubectl get pods -l app.kubernetes.io/name=postgresql-ha

# 验证集群健康状态
# 查看复制状态
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -c postgresql -- psql -U postgres -c "SELECT application_name, state FROM pg_stat_replication;"
```

### Quickwit缩容

```bash
# Quickwit缩容
kubectl scale statefulset openebs-stack-quickwit --replicas=3
```

**数据影响**：
- 缩容会减少搜索和索引性能
- 确保剩余节点能处理当前索引和查询负载

**PVC处理**：
```bash
# 删除不再需要的PVC
kubectl delete pvc data-openebs-stack-quickwit-3
kubectl delete pvc data-openebs-stack-quickwit-4
```

### 自动化PVC清理（Kubernetes 1.23+）

对于支持的Kubernetes版本，可配置StatefulSet自动删除PVC：

```bash
# 编辑StatefulSet添加PVC保留策略
kubectl edit statefulset openebs-stack-redis-node

# 在spec部分添加以下配置
persistentVolumeClaimRetentionPolicy:
  whenScaled: Delete  # 缩容时删除PVC
  whenDeleted: Retain # StatefulSet删除时保留PVC
```

> **注意**：此功能需要Kubernetes 1.23+版本支持，且对现有StatefulSet的修改可能需要重新创建。

## 扩容验证

执行扩容操作后，需要进行验证确保系统正常工作。

### 1. 检查 Pod 状态

```bash
# 检查所有组件 Pod 状态
kubectl get pods -l app.kubernetes.io/instance=openebs-stack

# 检查特定组件 Pod 状态
kubectl get pods -l app.kubernetes.io/name=postgresql-ha  # PostgreSQL-HA
kubectl get pods -l app.kubernetes.io/name=redis          # Redis
kubectl get pods -l app.kubernetes.io/name=kafka          # Kafka
kubectl get pods -l app.kubernetes.io/name=rabbitmq       # RabbitMQ
kubectl get pods -l app=kafka-connect                     # Kafka Connect
kubectl get pods -l app=quickwit                          # Quickwit
```

### 2. 验证 PostgreSQL 扩容

#### 验证副本数

```bash
# 检查 PostgreSQL Pod 数量
kubectl get pods -l app.kubernetes.io/name=postgresql-ha

# 检查节点角色
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### 3. 验证 Kafka 扩容

```bash
# 获取 Kafka Pod 名称
KAFKA_POD=$(kubectl get pods -l app.kubernetes.io/name=kafka -o name | head -n 1)

# 检查 Kafka 集群状态
kubectl exec -it $KAFKA_POD -- kafka-cluster.sh --bootstrap-server openebs-stack-kafka:9092 \
  --describe
```

### 4. 验证 Redis 扩容

```bash
# 检查 Redis Sentinel 状态
kubectl exec -it openebs-stack-redis-node-0 -c redis -- redis-cli -a "redis-password" info replication
```

### 5. 验证 Quickwit 扩容

```bash
# 获取 Quickwit Pod
QUICKWIT_POD=$(kubectl get pods -l app=quickwit -o name | head -n 1)

# 检查集群状态
kubectl exec -it $QUICKWIT_POD -- quickwit cluster status
```

### 6. 验证数据流

扩容后需要验证整个数据流是否正常工作：

```bash
# 1. 向 PostgreSQL 插入数据
kubectl run pg-insert-test --rm -i --restart=Never --image=postgres:13 -- \
  psql "postgresql://postgres:yourpassword@openebs-stack-postgresql-ha-primary:5432/yourdb" -c \
  "INSERT INTO public.messages (message, user_id) VALUES ('扩容测试消息', 1001);"

# 2. 检查 Quickwit 索引是否收到数据
kubectl exec -it $QUICKWIT_POD -- quickwit index search --index messages --query "message:扩容测试" --max-hits 10
```

## 常见问题

### 1. Pod 无法扩容

**问题**: 扩容后 Pod 卡在 `Pending` 状态。

**解决**:
- 检查集群资源是否充足: `kubectl describe node`
- 检查 PVC 是否创建成功: `kubectl get pvc`
- 检查 Pod 事件: `kubectl describe pod <pod-name>`

### 2. 复制因子配置不匹配

**问题**: Kafka 相关组件扩容后报错。

**解决**:
- 确保相关组件的复制因子与节点数匹配
- 更新相关 ConfigMap 中的复制因子设置

```bash
# 修改 Kafka Connect 配置
kubectl edit configmap openebs-stack-kafka-connect-config
```

### 3. 存储卷扩容失败

**问题**: 执行存储扩容后 PVC 容量未增加。

**解决**:
- 确认 StorageClass 支持卷扩展功能
- 检查 OpenEBS cStor 版本是否支持扩容
- 检查 PVC 扩容状态: `kubectl describe pvc <pvc-name>`

### 4. 服务中断时扩容

为避免扩容过程中的服务中断，建议遵循以下最佳实践：

- 在非高峰期执行扩容操作
- 逐步扩容，而非一次性大幅扩容
- 扩容前确保已备份关键数据
- 先进行资源扩容，再扩大副本数量

### 5. 扩容后数据同步问题

**问题**: 扩容后 Kafka Connect 数据同步出现问题。

**解决**:
- 检查连接器状态: `curl -s http://<kafka-connect-service>:8083/connectors/postgres-source/status`
- 如有必要，重新创建连接器：

```bash
kubectl run kafka-connect-delete --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X DELETE "http://kafka-connect:8083/connectors/postgres-source"

# 然后重新配置连接器
kubectl run kafka-connect-create --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Content-Type: application/json" --data @connector-config.json "http://kafka-connect:8083/connectors"
``` 