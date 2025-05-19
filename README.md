
# 🚀 openebs-stack Helm Chart（高可用完整版）

本项目提供全栈大数据服务部署，包括：
- PostgreSQL（高可用，支持 pgvector）
- Redis（Sentinel 模式高可用）
- RabbitMQ（多副本集群 + 队列高可用）
- Kafka + ZooKeeper（全副本持久化）
- Quickwit（全文索引）
- Debezium CDC + Kafka Connector 自动注册
- 使用 OpenEBS + cStor 作为持久化存储方案

---

- [OpenEBS-Stack-部署文档](doc/OpenEBS-Stack-部署文档.md)
- [PostgreSQL-CDC-工作流文档](doc/PostgreSQL-CDC-工作流文档.md)
- [OpenEBS-Stack-扩缩容文档](doc/OpenEBS-Stack-扩容文档.md)
- [OpenEBS-Stack-备份恢复文档](doc/OpenEBS-Stack-备份恢复文档.md)

---

### 1. 初始化 OpenEBS + cStor

```bash
./init-openebs-cstor.sh
```

### 2. 安装依赖

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update .
```

### 🔧 快速部署全栈(单机)
```bash
helm install openebs-stack . -f values.yaml
```

## 🔧 快速部署全栈（高可用）

```bash
helm install openebs-stack . -f values-prod-all.yaml
```

---

## ✅ 支持的高可用组件及架构

| 中间件      | 高可用架构                 | 说明                        |
|------------|--------------------------|-----------------------------|
| PostgreSQL | 主从复制 + Repmgr         | 自动故障转移 + pgvector 支持   |
| Redis      | Sentinel                 | 自动选主 + 读写分离            |
| RabbitMQ   | 多副本集群 + quorum queue  | 队列强一致，高可用             |
| Kafka      | 多 Broker + ZooKeeper     | 分区 + 副本容灾               |
| Quickwit   | 多副本 ingestion/searcher | 分布式全文索引                 |

---

## 📁 文件结构说明

| 文件名                        | 说明                         |
|------------------------------|-----------------------------|
| `values-prod-all.yaml`       | 一键高可用配置（推荐使用）       |
| `doc/`                       | 部署、扩容、备份恢复、工作流文档  |
| `scripts/setup-data-flow.sh` | 初始化工作流测试脚本            |

---

## 📦 数据链路示意图

```
[PostgreSQL] --(Debezium)--> [Kafka] --(Quickwit Ingestion)--> [Quickwit 索引]
          |                                     ↑
          |-- pgvector (向量搜索可选) -----------|
```

---

## 🧼 清理方式

```bash
helm uninstall openebs-stack
```

---

## 🧪 验证同步链路

### 插入 PostgreSQL 数据
```sql
INSERT INTO message (id, message, user_id, ts) VALUES (1, '你好 Quickwit', 123, now());
```

### 查询 Quickwit 索引
```bash
curl http://<quickwit-service>:7280/api/v1/message/search -d '{"query": "message:你好"}'
```

---

## 🛠 构建 Debezium 镜像（Kafka Connect）
```bash
./push-images.sh
```