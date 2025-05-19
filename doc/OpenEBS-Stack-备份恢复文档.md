# OpenEBS Stack 备份与恢复文档

本文档详细介绍了 OpenEBS Stack 各组件的备份与恢复方法，包括全量备份和增量备份策略。

## 目录

- [概述](#概述)
- [PostgreSQL 备份与恢复](#postgresql-备份与恢复)
- [Redis 备份与恢复](#redis-备份与恢复)
- [RabbitMQ 备份与恢复](#rabbitmq-备份与恢复)
- [存储卷备份](#存储卷备份)
- [完整系统备份与恢复](#完整系统备份与恢复)
- [自动化备份策略](#自动化备份策略)
- [自动化恢复方案](#自动化恢复方案)
- [常见问题](#常见问题)

## 概述

数据备份是确保系统可靠性和灾难恢复能力的关键要素。OpenEBS Stack 中的不同组件需要使用不同的备份策略：

- **PostgreSQL**: 使用原生备份工具如 pg_dump 和连续归档（WAL）
- **Redis**: 使用 RDB 快照、AOF 日志和复制
- **RabbitMQ**: 定义、消息和状态备份

备份类型：
- **全量备份**: 完整数据副本，适合定期计划备份
- **增量备份**: 仅备份自上次备份后更改的数据，减少备份时间和存储需求

## PostgreSQL 备份与恢复

PostgreSQL 提供多种备份方法，适用于不同的需求。

### 全量备份

#### 使用 pg_dump 进行逻辑备份

```bash
# 单机部署
kubectl exec -it openebs-stack-postgresql-0 -- bash -c "pg_dump -U postgres -d yourdb -F c -f /tmp/fullbackup.dump"
kubectl cp openebs-stack-postgresql-0:/tmp/fullbackup.dump ./fullbackup.dump

# 高可用部署
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "pg_dump -U postgres -d yourdb -F c -f /tmp/fullbackup.dump"
kubectl cp openebs-stack-postgresql-ha-postgresql-0:/tmp/fullbackup.dump ./fullbackup.dump
```

参数说明：
- `-U postgres`: 用户名
- `-d yourdb`: 数据库名
- `-F c`: 使用自定义格式（压缩）
- `-f /tmp/fullbackup.dump`: 输出文件路径

#### 使用 pg_basebackup 进行物理备份

```bash
# 高可用部署 - 从主节点进行物理备份
PRIMARY_POD=$(kubectl get pod -l repmgr.role=primary -o jsonpath='{.items[0].metadata.name}')
PGPASSWORD=$(kubectl get secret openebs-stack-postgresql-ha-postgresql -o jsonpath="{.data.repmgr-password}" | base64 --decode)
kubectl exec -it $PRIMARY_POD -- bash -c "mkdir -p /tmp/basebackup && chmod 777 /tmp/basebackup && PGPASSWORD=85bH82BmBp pg_basebackup -D /tmp/basebackup -Ft -z -P -v -R -h 127.0.0.1 -U repmgr"
kubectl cp $PRIMARY_POD:/tmp/basebackup ./basebackup
```

参数说明：
- `-D /tmp/basebackup`: 备份目录
- `-Ft`: 输出为 tar 格式
- `-z`: 启用压缩
- `-P`: 显示进度
- `-R`: 自动生成 standby.signal
- `-v`: 详细输出

### 增量备份

#### WAL 归档备份

1. 配置 WAL 归档（在 values.yaml 或 values-prod-all.yaml 中设置）:

```yaml
postgresql:
  primary:
    configuration: |
      wal_level = replica
      archive_mode = on
      archive_command = 'test ! -f /tmp/archive/%f && cp %p /tmp/archive/%f'
      max_wal_senders = 10
      wal_keep_size = 1024
```

2. 创建 WAL 归档目录:

```bash
kubectl exec -it $PRIMARY_POD -- mkdir -p /tmp/archive
```

3. 复制 WAL 文件:

```bash
kubectl exec -it $PRIMARY_POD -- ls -la /tmp/archive
kubectl cp $PRIMARY_POD:/tmp/archive ./wal_archives
```

### 恢复

#### 使用 pg_dump 备份恢复

```bash
# 将备份文件复制到 Pod
kubectl cp ./fullbackup.dump openebs-stack-postgresql-ha-postgresql-0:/tmp/

# 恢复数据
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "pg_restore -U postgres -d yourdb -c -v /tmp/fullbackup.dump"
```

参数说明：
- `-c`: 在恢复之前清除（删除）数据库对象
- `-v`: 详细模式

#### 使用物理备份恢复

```bash
# 1. 停止 PostgreSQL 服务
kubectl scale statefulset openebs-stack-postgresql-ha-postgresql --replicas=0

# 2. 拷贝 base.tar.gz 和 pg_wal.tar.gz 到 Pod
kubectl cp ./base.tar.gz openebs-stack-postgresql-ha-postgresql-0:/tmp/
kubectl cp ./pg_wal.tar.gz openebs-stack-postgresql-ha-postgresql-0:/tmp/

# 3. 清空旧数据目录（非常重要，避免混合残留数据）
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "rm -rf /bitnami/postgresql/*"

# 4. 解压 base.tar.gz 到数据目录（带 `--strip-components=1`，避免嵌套目录）
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "tar -xzf /tmp/base.tar.gz -C /bitnami/postgresql/ --strip-components=1"

# 5. 解压 pg_wal.tar.gz 到 WAL 目录（必须确保 pg_wal 存在）
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "mkdir -p /bitnami/postgresql/pg_wal && tar -xzf /tmp/pg_wal.tar.gz -C /bitnami/postgresql/pg_wal/"

# 6. 设置权限（Bitnami 镜像使用 UID 1001）
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "chown -R 1001:1001 /bitnami/postgresql"

# PostgreSQL 识别 standby.signal 文件 进入恢复/追主模式，如果需要主库运行而非副本，可执行：
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- rm /bitnami/postgresql/standby.signal

# 7. 启动 PostgreSQL 服务
kubectl scale statefulset openebs-stack-postgresql-ha-postgresql --replicas=3
```

#### PITR（时间点恢复）

使用 WAL 文件进行 PITR:

```bash
# 创建恢复配置
cat > recovery.conf << EOF
restore_command = 'cp /path/to/archive/%f %p'
recovery_target_time = '2023-05-01 12:00:00'
EOF

# 复制恢复配置到 Pod
kubectl cp ./recovery.conf openebs-stack-postgresql-ha-postgresql-0:/tmp/

# 应用恢复配置
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "cp /tmp/recovery.conf /bitnami/postgresql/recovery.conf"
kubectl exec -it openebs-stack-postgresql-ha-postgresql-0 -- bash -c "touch /bitnami/postgresql/recovery.signal"

# 重启 Pod
kubectl delete pod openebs-stack-postgresql-ha-postgresql-0
```

## Redis 备份与恢复

Redis 提供两种主要的持久化机制：RDB 快照和 AOF 日志。

### 全量备份

#### RDB 快照备份

```bash
# 单机部署
kubectl exec -it openebs-stack-redis-master-0 -- redis-cli -a 'redis-password' SAVE
kubectl cp openebs-stack-redis-master-0:/data/dump.rdb ./redis-dump.rdb

# 高可用部署 - 从主节点获取 RDB
REDIS_MASTER=$(kubectl exec -it openebs-stack-redis-node-0 -c sentinel --   bash -c 'redis-cli --raw -h openebs-stack-redis -p 26379 -a "$REDIS_PASSWORD" sentinel get-master-addr-by-name mymaster' | grep redis-node | awk -F. '{print $1}')
kubectl exec -it $REDIS_MASTER -- redis-cli -a 'redis-password' SAVE
kubectl cp $REDIS_MASTER:/data/dump.rdb ./redis-dump.rdb
```

### 增量备份

#### AOF 日志备份

1. 确保 AOF 已启用（在 values.yaml 或 values-prod-all.yaml 中设置）:

```yaml
redis:
  master:
    configuration: |
      appendonly yes
      appendfsync everysec
```

2. 复制 AOF 文件:

```bash
kubectl cp $REDIS_MASTER:/data/appendonly.aof ./redis-appendonly.aof
```

### 恢复

#### 使用 RDB 恢复

```bash
# 将 RDB 文件复制到 Pod
kubectl cp ./redis-dump.rdb openebs-stack-redis-master-0:/data/dump.rdb

# 重启 Redis 服务
kubectl delete pod openebs-stack-redis-master-0
```

#### 使用 AOF 恢复

```bash
# 将 AOF 文件复制到 Pod
kubectl cp ./redis-appendonly.aof openebs-stack-redis-master-0:/data/appendonly.aof

# 重启 Redis 服务
kubectl delete pod openebs-stack-redis-master-0
```

## RabbitMQ 备份与恢复

### 定义和配置备份

RabbitMQ 的定义（队列、交换器、绑定等）可以通过管理 API 导出。

```bash
# 导出定义
kubectl exec -it openebs-stack-rabbitmq-0 -- bash -c "rabbitmqctl export_definitions /tmp/rabbitmq-definitions.json"
kubectl cp openebs-stack-rabbitmq-0:/tmp/rabbitmq-definitions.json ./rabbitmq-definitions.json

# 或使用 HTTP API
kubectl exec -it openebs-stack-rabbitmq-0 -- curl -s -u user:bitnami123 -X GET http://10.233.29.153:15672/api/definitions > rabbitmq-definitions.json
```

### 消息备份

RabbitMQ 没有官方的消息备份工具，但有以下选项：

1. 使用 shovel 或 federation 插件将消息复制到另一个集群
2. 使用第三方工具如 rabbitmq-dump-queue

```bash
# 安装 rabbitmq-dump-queue 工具
kubectl exec -it openebs-stack-rabbitmq-0 -- bash -c "apt-get update && apt-get install -y python3-pip && pip3 install rabbitmq-dump-queue"

# 备份特定队列
kubectl exec -it openebs-stack-rabbitmq-0 -- bash -c "rabbitmq-dump-queue -H localhost -V / -u user -p bitnami123 -q my_queue > /tmp/queue_backup.json"
kubectl cp openebs-stack-rabbitmq-0:/tmp/queue_backup.json ./queue_backup.json
```

### 持久化数据备份

备份数据目录：

```bash
kubectl exec -it openebs-stack-rabbitmq-0 -- bash -c "tar -czf /tmp/rabbitmq-data.tar.gz -C /opt/bitnami/rabbitmq ."
kubectl cp openebs-stack-rabbitmq-0:/tmp/rabbitmq-data.tar.gz ./rabbitmq-data.tar.gz
```

### 恢复

#### 恢复定义

```bash
# 复制定义文件
kubectl cp ./rabbitmq-definitions.json openebs-stack-rabbitmq-0:/tmp/

# 导入定义
kubectl exec -it openebs-stack-rabbitmq-0 -- bash -c "rabbitmqctl import_definitions /tmp/rabbitmq-definitions.json"

# 或使用 HTTP API
kubectl run rabbitmq-restore-$RANDOM --rm -i --restart=Never --image=curlimages/curl -- \
  curl -u user:bitnami123 -X POST -H "Content-Type: application/json" -d @rabbitmq-definitions.json http://openebs-stack-rabbitmq:15672/api/definitions
```

#### 恢复持久化数据

```bash
# 停止 RabbitMQ 服务
kubectl scale statefulset openebs-stack-rabbitmq --replicas=0

# 复制备份文件
kubectl cp ./rabbitmq-data.tar.gz openebs-stack-rabbitmq-0:/tmp/

# 恢复数据
kubectl exec -it openebs-stack-rabbitmq-0 -- bash -c "rm -rf /opt/bitnami/rabbitmq/* && tar -xzf /tmp/rabbitmq-data.tar.gz -C /opt/bitnami/rabbitmq"

# 启动 RabbitMQ 服务
kubectl scale statefulset openebs-stack-rabbitmq --replicas=3
```

## 存储卷备份

OpenEBS cStor 提供了存储卷的备份机制。

### 使用 OpenEBS 快照

1. 创建卷快照:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgresql-data-snapshot
spec:
  volumeSnapshotClassName: cstor-snapshot-class
  source:
    persistentVolumeClaimName: data-openebs-stack-postgresql-0
```

2. 应用配置:

```bash
kubectl apply -f postgresql-snapshot.yaml
```

3. 检查快照状态:

```bash
kubectl get volumesnapshot
```

### 自动化备份方案

OpenEBS Stack 可以结合卷快照和逻辑备份实现全面的备份策略。以下提供基于 Kubernetes Job 和 CronJob 的自动化备份方案。

#### 创建备份所需的资源

首先，创建用于备份的 ServiceAccount 和持久卷：

```yaml
# backup-resources.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backup-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: backup-manager
rules:
- apiGroups: ["snapshot.storage.k8s.io"]
  resources: ["volumesnapshots"]
  verbs: ["get", "list", "create", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backup-manager-binding
subjects:
- kind: ServiceAccount
  name: backup-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: backup-manager
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backup-storage-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-cstor
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f backup-resources.yaml
```

#### PostgreSQL 自动化备份

创建 PostgreSQL 备份的 CronJob：

```yaml
# postgres-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: default
spec:
  schedule: "0 2 * * *"  # 每天凌晨2点
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: postgres-backup
            image: bitnami/postgresql:13
            command:
            - /bin/bash
            - -c
            - |
              # 确保数据一致性
              echo "执行数据库 CHECKPOINT..."
              PGPASSWORD="${POSTGRES_PASSWORD}" psql -h ${POSTGRES_HOST} -U postgres -c "CHECKPOINT;"
              
              # 逻辑备份 - 全量
              echo "执行逻辑备份..."
              BACKUP_FILE="/backup/logical/postgres-$(date +%Y%m%d).dump"
              PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump -h ${POSTGRES_HOST} -U postgres -d ${POSTGRES_DB} -F c -f ${BACKUP_FILE}
              
              # 创建卷快照
              echo "创建卷快照..."
              cat <<EOF | kubectl apply -f -
              apiVersion: snapshot.storage.k8s.io/v1
              kind: VolumeSnapshot
              metadata:
                name: postgres-snapshot-$(date +%Y%m%d)
                namespace: default
              spec:
                volumeSnapshotClassName: cstor-snapshot-class
                source:
                  persistentVolumeClaimName: ${PVC_NAME}
              EOF
              
              # 清理过期备份
              echo "清理过期备份..."
              find /backup/logical -name "postgres-*.dump" -mtime +7 -delete
              
              # 列出快照并删除过期的快照 (保留最新7个)
              OLD_SNAPSHOTS=$(kubectl get volumesnapshot -l app=postgres-backup --sort-by=.metadata.creationTimestamp -o name | head -n -7)
              if [ -n "$OLD_SNAPSHOTS" ]; then
                echo "删除过期快照: $OLD_SNAPSHOTS"
                kubectl delete $OLD_SNAPSHOTS
              fi
              
              echo "备份完成"
            env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openebs-stack-postgresql-ha-postgresql
                  key: postgresql-password
            - name: POSTGRES_HOST
              value: "openebs-stack-postgresql-ha-postgresql"
            - name: POSTGRES_DB
              value: "your_database"  # 替换为实际的数据库名
            - name: PVC_NAME
              value: "data-openebs-stack-postgresql-ha-postgresql-0"  # 高可用部署的PVC名称
            volumeMounts:
            - name: backup-vol
              mountPath: /backup
          volumes:
          - name: backup-vol
            persistentVolumeClaim:
              claimName: backup-storage-pvc
          serviceAccountName: backup-sa
          restartPolicy: OnFailure
```

#### Redis 自动化备份

创建 Redis 备份的 CronJob：

```yaml
# redis-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: redis-backup
  namespace: default
spec:
  schedule: "0 3 * * *"  # 每天凌晨3点
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: redis-backup
            image: bitnami/redis:6.2
            command:
            - /bin/bash
            - -c
            - |
              # 确定 Redis 主节点 
              if [ -n "$(kubectl get pod openebs-stack-redis-master-0 2>/dev/null)" ]; then
                REDIS_POD="openebs-stack-redis-master-0"
                REDIS_SVC="openebs-stack-redis-master"
              else
                # 高可用部署查找主节点
                echo "查找 Redis 主节点..."
                SENTINEL_POD="openebs-stack-redis-sentinel-0"
                REDIS_MASTER_IP=$(kubectl exec $SENTINEL_POD -- redis-cli -p 26379 sentinel get-master-addr-by-name mymaster | head -1)
                REDIS_POD=$(kubectl get pod -l app.kubernetes.io/component=master -o jsonpath="{.items[?(@.status.podIP=='$REDIS_MASTER_IP')].metadata.name}")
                REDIS_SVC=$(kubectl get service -l app.kubernetes.io/component=master -o jsonpath="{.items[0].metadata.name}")
              fi
              
              echo "REDIS_POD = $REDIS_POD"
              echo "REDIS_SVC = $REDIS_SVC"
              
              # 触发 SAVE 命令确保数据写入 RDB 文件
              echo "执行 Redis SAVE 命令..."
              redis-cli -h $REDIS_SVC -a "${REDIS_PASSWORD}" SAVE
              
              # 复制 RDB 文件到备份目录
              echo "复制 RDB 文件到备份目录..."
              BACKUP_FILE="/backup/logical/redis-$(date +%Y%m%d).rdb"
              kubectl exec $REDIS_POD -- cat /data/dump.rdb > $BACKUP_FILE
              
              # 创建卷快照
              echo "创建卷快照..."
              cat <<EOF | kubectl apply -f -
              apiVersion: snapshot.storage.k8s.io/v1
              kind: VolumeSnapshot
              metadata:
                name: redis-snapshot-$(date +%Y%m%d)
                namespace: default
              spec:
                volumeSnapshotClassName: cstor-snapshot-class
                source:
                  persistentVolumeClaimName: ${PVC_NAME}
              EOF
              
              # 清理过期备份
              echo "清理过期备份..."
              find /backup/logical -name "redis-*.rdb" -mtime +7 -delete
              
              # 列出快照并删除过期的快照 (保留最新7个)
              OLD_SNAPSHOTS=$(kubectl get volumesnapshot -l app=redis-backup --sort-by=.metadata.creationTimestamp -o name | head -n -7)
              if [ -n "$OLD_SNAPSHOTS" ]; then
                echo "删除过期快照: $OLD_SNAPSHOTS"
                kubectl delete $OLD_SNAPSHOTS
              fi
              
              echo "备份完成"
            env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openebs-stack-redis
                  key: redis-password
            - name: PVC_NAME
              value: "redis-data-openebs-stack-redis-master-0"  # 单机部署的PVC名称
            volumeMounts:
            - name: backup-vol
              mountPath: /backup
          volumes:
          - name: backup-vol
            persistentVolumeClaim:
              claimName: backup-storage-pvc
          serviceAccountName: backup-sa
          restartPolicy: OnFailure
```

#### RabbitMQ 自动化备份

创建 RabbitMQ 备份的 CronJob：

```yaml
# rabbitmq-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rabbitmq-backup
  namespace: default
spec:
  schedule: "0 4 * * *"  # 每天凌晨4点
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: rabbitmq-backup
            image: curlimages/curl:latest
            command:
            - /bin/bash
            - -c
            - |
              # 导出 RabbitMQ 定义
              echo "导出 RabbitMQ 定义..."
              mkdir -p /backup/logical
              BACKUP_FILE="/backup/logical/rabbitmq-definitions-$(date +%Y%m%d).json"
              curl -s -u ${RABBITMQ_USER}:${RABBITMQ_PASSWORD} -X GET http://${RABBITMQ_HOST}:15672/api/definitions > $BACKUP_FILE
              
              # 创建卷快照
              echo "创建卷快照..."
              cat <<EOF | kubectl apply -f -
              apiVersion: snapshot.storage.k8s.io/v1
              kind: VolumeSnapshot
              metadata:
                name: rabbitmq-snapshot-$(date +%Y%m%d)
                namespace: default
              spec:
                volumeSnapshotClassName: cstor-snapshot-class
                source:
                  persistentVolumeClaimName: ${PVC_NAME}
              EOF
              
              # 清理过期备份
              echo "清理过期备份..."
              find /backup/logical -name "rabbitmq-definitions-*.json" -mtime +7 -delete
              
              # 列出快照并删除过期的快照 (保留最新7个)
              OLD_SNAPSHOTS=$(kubectl get volumesnapshot -l app=rabbitmq-backup --sort-by=.metadata.creationTimestamp -o name | head -n -7)
              if [ -n "$OLD_SNAPSHOTS" ]; then
                echo "删除过期快照: $OLD_SNAPSHOTS"
                kubectl delete $OLD_SNAPSHOTS
              fi
              
              echo "备份完成"
            env:
            - name: RABBITMQ_USER
              value: "user"
            - name: RABBITMQ_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openebs-stack-rabbitmq
                  key: rabbitmq-password
            - name: RABBITMQ_HOST
              value: "openebs-stack-rabbitmq"
            - name: PVC_NAME
              value: "data-openebs-stack-rabbitmq-0"
            volumeMounts:
            - name: backup-vol
              mountPath: /backup
          volumes:
          - name: backup-vol
            persistentVolumeClaim:
              claimName: backup-storage-pvc
          serviceAccountName: backup-sa
          restartPolicy: OnFailure
```

## 完整系统备份与恢复

为了完整备份整个 OpenEBS Stack，建议结合以下策略：

1. 使用组件级备份（如上所述）
2. 备份 Helm 发布配置:

```bash
# 备份 Helm 发布配置
helm get values openebs-stack -n default -o yaml > openebs-stack-values.yaml
```

3. 备份 Kubernetes 资源:

```bash
# 安装 kube-backup
kubectl create namespace backup
kubectl -n backup apply -f https://github.com/pieterlange/kube-backup/blob/master/deploy/rbac.yaml
kubectl -n backup apply -f https://github.com/pieterlange/kube-backup/blob/master/deploy/deployment.yaml

# 或手动备份关键资源
kubectl get secret,configmap,pvc,svc,statefulset,deployment -l app.kubernetes.io/instance=openebs-stack -o yaml > k8s-resources-backup.yaml
```

### 完整恢复

1. 恢复 Kubernetes 资源:

```bash
kubectl apply -f k8s-resources-backup.yaml
```

2. 恢复 Helm 发布:

```bash
helm upgrade openebs-stack . -f openebs-stack-values.yaml
```

3. 恢复各组件数据（如上所述）

## 自动化备份策略

### 定时备份作业

使用 Kubernetes CronJob 实现自动备份:

```yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: postgresql-backup
spec:
  schedule: "0 2 * * *"  # 每天凌晨2点
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: postgres-backup
            image: postgres:13
            command:
            - /bin/bash
            - -c
            - |
              pg_dump -h openebs-stack-postgresql-ha-primary -U postgres -d yourdb -F c -f /backup/fullbackup-$(date +%Y%m%d).dump
              find /backup -name "fullbackup-*.dump" -mtime +7 -delete
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: openebs-stack-postgresql-ha-postgresql
                  key: password
            volumeMounts:
            - name: backup-vol
              mountPath: /backup
          volumes:
          - name: backup-vol
            persistentVolumeClaim:
              claimName: postgresql-backup-pvc
          restartPolicy: OnFailure
```

### 备份到远程存储

```yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: backup-to-s3
spec:
  schedule: "0 3 * * *"  # 每天凌晨3点
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup-s3
            image: amazon/aws-cli
            command:
            - /bin/bash
            - -c
            - |
              aws s3 sync /backup s3://my-bucket/openebs-stack-backups/
            env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: aws-credentials
                  key: access-key
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: aws-credentials
                  key: secret-key
            volumeMounts:
            - name: backup-vol
              mountPath: /backup
          volumes:
          - name: backup-vol
            persistentVolumeClaim:
              claimName: backup-pvc
          restartPolicy: OnFailure
```

## 自动化恢复方案

以下提供基于 Kubernetes Job 的数据恢复方案，可以根据需要从卷快照或逻辑备份中恢复数据。

#### PostgreSQL 自动化恢复

##### 从卷快照恢复

```yaml
# postgres-snapshot-restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: postgres-snapshot-restore
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: postgres-restore
        image: bitnami/postgresql:13
        command:
        - /bin/bash
        - -c
        - |
          echo "开始从快照恢复 PostgreSQL 数据..."
          
          # 1. 确保 PostgreSQL 服务停止
          echo "停止 PostgreSQL 服务..."
          kubectl scale statefulset ${POSTGRES_STS} --replicas=0
          
          # 2. 等待 Pod 完全停止
          echo "等待 Pod 完全停止..."
          while kubectl get pod -l app.kubernetes.io/instance=openebs-stack-postgresql-ha | grep -q Running; do
            echo "等待 PostgreSQL Pod 终止..."
            sleep 5
          done
          
          # 3. 创建从快照恢复的新 PVC
          echo "从快照创建新 PVC..."
          cat <<EOF | kubectl apply -f -
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: postgres-restored-pvc
            namespace: default
          spec:
            storageClassName: openebs-cstor
            dataSource:
              name: ${SNAPSHOT_NAME}
              kind: VolumeSnapshot
              apiGroup: snapshot.storage.k8s.io
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: 10Gi
          EOF
          
          # 4. 等待新 PVC 创建完成
          echo "等待新 PVC 就绪..."
          kubectl wait --for=condition=Bound pvc/postgres-restored-pvc --timeout=5m
          
          # 5. 备份并替换原始 PVC
          echo "备份原始 PVC 名称和重新配置 StatefulSet..."
          kubectl get pvc ${ORIGINAL_PVC} -o yaml > /tmp/original-pvc.yaml
          
          # 使用恢复的 PVC 替换原始 PVC
          kubectl patch statefulset ${POSTGRES_STS} --type='json' -p='[{"op": "replace", "path": "/spec/volumeClaimTemplates/0/spec/dataSource", "value": {"name": "postgres-restored-pvc", "kind": "PersistentVolumeClaim", "apiGroup": ""}}]'
          
          # 6. 启动 PostgreSQL 服务
          echo "启动 PostgreSQL 服务..."
          kubectl scale statefulset ${POSTGRES_STS} --replicas=${REPLICAS}
          
          # 7. 等待 PostgreSQL 服务启动
          echo "等待 PostgreSQL 服务启动..."
          kubectl wait --for=condition=Ready pod/${POSTGRES_STS}-0 --timeout=5m
          
          echo "恢复完成"
        env:
        - name: POSTGRES_STS
          value: "openebs-stack-postgresql-ha-postgresql"  # 高可用部署的 StatefulSet 名称
        - name: ORIGINAL_PVC
          value: "data-openebs-stack-postgresql-ha-postgresql-0"  # 原始 PVC 名称
        - name: SNAPSHOT_NAME
          value: "postgres-snapshot-20230501"  # 替换为要恢复的快照名称
        - name: REPLICAS
          value: "3"  # 恢复后的副本数
      serviceAccountName: backup-sa
      restartPolicy: OnFailure
```

##### 从逻辑备份恢复

```yaml
# postgres-logical-restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: postgres-logical-restore
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: postgres-restore
        image: bitnami/postgresql:13
        command:
        - /bin/bash
        - -c
        - |
          echo "开始从逻辑备份恢复 PostgreSQL 数据..."
          
          # 拷贝备份文件到临时目录
          echo "准备备份文件: ${BACKUP_FILE}..."
          cp ${BACKUP_FILE} /tmp/restore.dump
          
          # 从逻辑备份恢复
          echo "正在恢复数据库..."
          PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore -h ${POSTGRES_HOST} -U postgres -d ${POSTGRES_DB} -c -v /tmp/restore.dump
          
          echo "恢复完成"
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: openebs-stack-postgresql-ha-postgresql
              key: postgresql-password
        - name: POSTGRES_HOST
          value: "openebs-stack-postgresql-ha-postgresql"
        - name: POSTGRES_DB
          value: "your_database"  # 替换为实际的数据库名
        - name: BACKUP_FILE
          value: "/backup/logical/postgres-20230501.dump"  # 替换为要恢复的备份文件
        volumeMounts:
        - name: backup-vol
          mountPath: /backup
      volumes:
      - name: backup-vol
        persistentVolumeClaim:
          claimName: backup-storage-pvc
      restartPolicy: OnFailure
```

#### Redis 自动化恢复

##### 从卷快照恢复

```yaml
# redis-snapshot-restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: redis-snapshot-restore
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: redis-restore
        image: bitnami/redis:6.2
        command:
        - /bin/bash
        - -c
        - |
          echo "开始从快照恢复 Redis 数据..."
          
          # 1. 确保 Redis 服务停止
          echo "停止 Redis 服务..."
          kubectl scale statefulset ${REDIS_STS} --replicas=0
          
          # 2. 等待 Pod 完全停止
          echo "等待 Pod 完全停止..."
          while kubectl get pod -l app.kubernetes.io/instance=openebs-stack-redis | grep -q Running; do
            echo "等待 Redis Pod 终止..."
            sleep 5
          done
          
          # 3. 创建从快照恢复的新 PVC
          echo "从快照创建新 PVC..."
          cat <<EOF | kubectl apply -f -
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: redis-restored-pvc
            namespace: default
          spec:
            storageClassName: openebs-cstor
            dataSource:
              name: ${SNAPSHOT_NAME}
              kind: VolumeSnapshot
              apiGroup: snapshot.storage.k8s.io
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: 10Gi
          EOF
          
          # 4. 等待新 PVC 创建完成
          echo "等待新 PVC 就绪..."
          kubectl wait --for=condition=Bound pvc/redis-restored-pvc --timeout=5m
          
          # 5. 备份并替换原始 PVC
          echo "备份原始 PVC 名称和重新配置 StatefulSet..."
          kubectl get pvc ${ORIGINAL_PVC} -o yaml > /tmp/original-pvc.yaml
          
          # 使用恢复的 PVC 替换原始 PVC
          kubectl patch statefulset ${REDIS_STS} --type='json' -p='[{"op": "replace", "path": "/spec/volumeClaimTemplates/0/spec/dataSource", "value": {"name": "redis-restored-pvc", "kind": "PersistentVolumeClaim", "apiGroup": ""}}]'
          
          # 6. 启动 Redis 服务
          echo "启动 Redis 服务..."
          kubectl scale statefulset ${REDIS_STS} --replicas=${REPLICAS}
          
          # 7. 等待 Redis 服务启动
          echo "等待 Redis 服务启动..."
          kubectl wait --for=condition=Ready pod/${REDIS_STS}-0 --timeout=5m
          
          echo "恢复完成"
        env:
        - name: REDIS_STS
          value: "openebs-stack-redis-master"  # 单机部署的 StatefulSet 名称 
        - name: ORIGINAL_PVC
          value: "redis-data-openebs-stack-redis-master-0"  # 原始 PVC 名称
        - name: SNAPSHOT_NAME
          value: "redis-snapshot-20230501"  # 替换为要恢复的快照名称
        - name: REPLICAS
          value: "1"  # 恢复后的副本数
      serviceAccountName: backup-sa
      restartPolicy: OnFailure
```

##### 从 RDB 文件恢复

```yaml
# redis-rdb-restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: redis-rdb-restore
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: redis-restore
        image: bitnami/redis:6.2
        command:
        - /bin/bash
        - -c
        - |
          echo "开始从 RDB 文件恢复 Redis 数据..."
          
          # 1. 停止 Redis 服务
          echo "停止 Redis 服务..."
          kubectl scale statefulset ${REDIS_STS} --replicas=0
          
          # 2. 等待 Pod 完全停止
          echo "等待 Pod 完全停止..."
          while kubectl get pod -l app.kubernetes.io/name=redis | grep -q Running; do
            echo "等待 Redis Pod 终止..."
            sleep 5
          done
          
          # 3. 将 RDB 文件复制到临时目录
          echo "准备 RDB 备份文件..."
          
          # 4. 创建配置映射以启动临时恢复 Pod
          echo "创建临时恢复 Pod..."
          cat <<EOF | kubectl apply -f -
          apiVersion: v1
          kind: Pod
          metadata:
            name: redis-restore-temp
            namespace: default
          spec:
            containers:
            - name: redis-restore
              image: bitnami/redis:6.2
              command: ["sleep", "3600"]
              volumeMounts:
              - name: redis-data
                mountPath: /data
              - name: backup-vol
                mountPath: /backup
            volumes:
            - name: redis-data
              persistentVolumeClaim:
                claimName: ${ORIGINAL_PVC}
            - name: backup-vol
              persistentVolumeClaim:
                claimName: backup-storage-pvc
            restartPolicy: Never
          EOF
          
          # 5. 等待临时 Pod 就绪
          echo "等待临时 Pod 就绪..."
          kubectl wait --for=condition=Ready pod/redis-restore-temp --timeout=2m
          
          # 6. 复制 RDB 文件到数据目录
          echo "复制 RDB 文件到数据卷..."
          kubectl exec redis-restore-temp -- cp ${BACKUP_FILE} /data/dump.rdb
          
          # 7. 删除临时 Pod
          echo "删除临时 Pod..."
          kubectl delete pod redis-restore-temp
          
          # 8. 启动 Redis 服务
          echo "启动 Redis 服务..."
          kubectl scale statefulset ${REDIS_STS} --replicas=${REPLICAS}
          
          echo "恢复完成"
        env:
        - name: REDIS_STS
          value: "openebs-stack-redis-master"
        - name: ORIGINAL_PVC
          value: "redis-data-openebs-stack-redis-master-0"
        - name: BACKUP_FILE
          value: "/backup/logical/redis-20230501.rdb"  # 替换为实际的 RDB 文件路径
        - name: REPLICAS
          value: "1"
        volumeMounts:
        - name: backup-vol
          mountPath: /backup
      volumes:
      - name: backup-vol
        persistentVolumeClaim:
          claimName: backup-storage-pvc
      serviceAccountName: backup-sa
      restartPolicy: OnFailure
```

#### RabbitMQ 自动化恢复

##### 从卷快照恢复

```yaml
# rabbitmq-snapshot-restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: rabbitmq-snapshot-restore
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: rabbitmq-restore
        image: bitnami/rabbitmq:3.9
        command:
        - /bin/bash
        - -c
        - |
          echo "开始从快照恢复 RabbitMQ 数据..."
          
          # 1. 确保 RabbitMQ 服务停止
          echo "停止 RabbitMQ 服务..."
          kubectl scale statefulset ${RABBITMQ_STS} --replicas=0
          
          # 2. 等待 Pod 完全停止
          echo "等待 Pod 完全停止..."
          while kubectl get pod -l app.kubernetes.io/instance=openebs-stack-rabbitmq | grep -q Running; do
            echo "等待 RabbitMQ Pod 终止..."
            sleep 5
          done
          
          # 3. 创建从快照恢复的新 PVC
          echo "从快照创建新 PVC..."
          cat <<EOF | kubectl apply -f -
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: rabbitmq-restored-pvc
            namespace: default
          spec:
            storageClassName: openebs-cstor
            dataSource:
              name: ${SNAPSHOT_NAME}
              kind: VolumeSnapshot
              apiGroup: snapshot.storage.k8s.io
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: 10Gi
          EOF
          
          # 4. 等待新 PVC 创建完成
          echo "等待新 PVC 就绪..."
          kubectl wait --for=condition=Bound pvc/rabbitmq-restored-pvc --timeout=5m
          
          # 5. 备份并替换原始 PVC
          echo "备份原始 PVC 名称和重新配置 StatefulSet..."
          kubectl get pvc ${ORIGINAL_PVC} -o yaml > /tmp/original-pvc.yaml
          
          # 使用恢复的 PVC 替换原始 PVC
          kubectl patch statefulset ${RABBITMQ_STS} --type='json' -p='[{"op": "replace", "path": "/spec/volumeClaimTemplates/0/spec/dataSource", "value": {"name": "rabbitmq-restored-pvc", "kind": "PersistentVolumeClaim", "apiGroup": ""}}]'
          
          # 6. 启动 RabbitMQ 服务
          echo "启动 RabbitMQ 服务..."
          kubectl scale statefulset ${RABBITMQ_STS} --replicas=${REPLICAS}
          
          # 7. 等待 RabbitMQ 服务启动
          echo "等待 RabbitMQ 服务启动..."
          kubectl wait --for=condition=Ready pod/${RABBITMQ_STS}-0 --timeout=5m
          
          echo "恢复完成"
        env:
        - name: RABBITMQ_STS
          value: "openebs-stack-rabbitmq"
        - name: ORIGINAL_PVC
          value: "data-openebs-stack-rabbitmq-0"
        - name: SNAPSHOT_NAME
          value: "rabbitmq-snapshot-20230501"  # 替换为要恢复的快照名称
        - name: REPLICAS
          value: "3"  # 恢复后的副本数
      serviceAccountName: backup-sa
      restartPolicy: OnFailure
```

##### 从定义文件恢复

```yaml
# rabbitmq-definitions-restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: rabbitmq-definitions-restore
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: rabbitmq-restore
        image: curlimages/curl:latest
        command:
        - /bin/bash
        - -c
        - |
          echo "开始从定义文件恢复 RabbitMQ 配置..."
          
          # 等待 RabbitMQ 服务就绪
          echo "等待 RabbitMQ 服务就绪..."
          until curl -s http://${RABBITMQ_HOST}:15672/api/overview -u ${RABBITMQ_USER}:${RABBITMQ_PASSWORD} > /dev/null; do
            echo "等待 RabbitMQ 管理接口就绪..."
            sleep 10
          done
          
          # 导入定义
          echo "导入 RabbitMQ 定义..."
          curl -s -u ${RABBITMQ_USER}:${RABBITMQ_PASSWORD} -X POST -H "Content-Type: application/json" \
            --data @${BACKUP_FILE} \
            http://${RABBITMQ_HOST}:15672/api/definitions
          
          echo "定义恢复完成"
        env:
        - name: RABBITMQ_USER
          value: "user"
        - name: RABBITMQ_PASSWORD
          valueFrom:
            secretKeyRef:
              name: openebs-stack-rabbitmq
              key: rabbitmq-password
        - name: RABBITMQ_HOST
          value: "openebs-stack-rabbitmq"
        - name: BACKUP_FILE
          value: "/backup/logical/rabbitmq-definitions-20230501.json"  # 替换为实际的定义文件路径
        volumeMounts:
        - name: backup-vol
          mountPath: /backup
      volumes:
      - name: backup-vol
        persistentVolumeClaim:
          claimName: backup-storage-pvc
      restartPolicy: OnFailure
```

## 常见问题

### 备份过程中的性能影响

**问题**: 备份过程影响系统性能。

**解决**:
- 在低负载时间段执行备份
- 使用增量备份减少数据量
- PostgreSQL 备份使用从节点而非主节点
- 对备份作业设置资源限制

### 恢复时间目标 (RTO)

**问题**: 恢复操作耗时过长。

**解决**:
- 制定自动化恢复流程
- 保持最新的备份
- 实施热备用系统
- 定期演练恢复流程

### 恢复一致性

**问题**: 恢复后系统状态不一致。

**解决**:
- 在一个时间点备份所有组件
- 使用有事务支持的备份工具
- 记录备份的依赖关系
- 实施恢复后一致性检查