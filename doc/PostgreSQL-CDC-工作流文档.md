# PostgreSQL CDC 数据变更捕获工作流文档

## 目录

- [概述](#1-概述)
- [工作流程详解](#2-工作流程详解)
- [配置模板与参数说明](#3-配置模板与参数说明)
- [部署模式区别](#4-部署模式区别)
- [操作示例](#5-操作示例)
- [常见问题与解决方案](#6-常见问题与解决方案)
- [最佳实践](#7-最佳实践)
- [python应用示例](#8-python应用示例)
- [实时检索优化配置](#9-实时检索优化配置)

## 1. 概述

本文档详细说明了 PostgreSQL 数据变更捕获(CDC)工作流程，从数据库到全文索引的完整数据链路。该工作流基于 Debezium 实现，将 PostgreSQL 的数据变更实时同步到 Kafka，再由 Quickwit 进行索引处理，最终提供高性能的全文检索服务。

### 数据流路径

```
PostgreSQL ---(Debezium)---> Kafka Connect ---> Kafka ---(Source)---> Quickwit
```

### 工作流组件

- **PostgreSQL**：源数据库，配置逻辑复制功能
- **Debezium**：CDC 引擎，捕获 PostgreSQL 数据变更
- **Kafka Connect**：数据连接器框架，运行 Debezium 连接器
- **Kafka**：分布式流平台，存储变更事件流
- **Quickwit**：分布式搜索引擎，提供全文检索能力

## 2. 工作流程详解

### 2.1 PostgreSQL 配置

1. **启用逻辑复制**：
   - 配置 `wal_level = logical`
   - 设置足够的 `max_wal_senders` 和 `max_replication_slots`

2. **创建 Publication**：为需要监控变更的表创建发布
   ```sql
   CREATE PUBLICATION dbz_publication FOR TABLE public.messages;
   ```

3. **准备测试数据**：创建示例表结构
   ```sql
   CREATE TABLE IF NOT EXISTS public.messages (
     id SERIAL PRIMARY KEY,
     message TEXT NOT NULL,
     user_id INTEGER NOT NULL,
     ts TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
   );
   ```

### 2.2 Kafka Connect 配置

1. **安装 Debezium 连接器**：确保 Kafka Connect 中已安装 Debezium PostgreSQL 连接器

2. **创建 Debezium 连接器**：通过 Kafka Connect REST API 创建连接器

### 2.3 Kafka 配置

1. **创建 Kafka 主题**：为 PostgreSQL 表数据变更创建对应主题
2. **配置主题参数**：包括分区数、复制因子等

### 2.4 Quickwit 配置

1. **创建 Quickwit 索引**：定义索引映射和设置
2. **配置 Kafka 源**：将 Quickwit 连接到 Kafka 主题
3. **启动索引服务**：开始消费 Kafka 消息并构建索引

## 3. 配置模板与参数说明

### 3.1 Debezium PostgreSQL 连接器

#### 连接器配置模板

```json
{
  "name": "postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "<PostgreSQL-hostname>",
    "database.port": "<PostgreSQL-port>",
    "database.user": "<PostgreSQL-user>",
    "database.password": "<PostgreSQL-password>",
    "database.dbname": "<PostgreSQL-database>",
    "database.server.name": "postgres",
    "topic.prefix": "postgres",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "false",
    "schema.include.list": "public",
    "table.include.list": "public.messages",
    "plugin.name": "pgoutput",
    "slot.name": "debezium",
    "publication.name": "dbz_publication",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "config.storage.replication.factor": "<replication-factor>",
    "offset.storage.replication.factor": "<replication-factor>", 
    "status.storage.replication.factor": "<replication-factor>",
    "heartbeat.interval.ms": "5000",
    "max.queue.size": "8192",
    "max.batch.size": "1024",
    "poll.interval.ms": "1000"
  }
}
```

#### 参数说明

| 参数 | 说明 | 示例值 |
|------|------|---------|
| `connector.class` | 连接器类名，指定使用 PostgreSQL 连接器 | `io.debezium.connector.postgresql.PostgresConnector` |
| `tasks.max` | 最大任务数，控制并行处理能力 | `1`（单节点）或 `3`（高可用） |
| `database.hostname` | PostgreSQL 主机名 | `openebs-stack-postgresql-ha-postgresql-0.openebs-stack-postgresql-ha-postgresql-headless` |
| `database.port` | PostgreSQL 端口 | `5432` |
| `database.user` | 数据库用户名 | `postgres` |
| `database.password` | 数据库密码 | `yourpassword` |
| `database.dbname` | 数据库名称 | `yourdb` |
| `database.server.name` | 服务器逻辑名称，用于构建主题名前缀 | `postgres` |
| `topic.prefix` | Kafka 主题前缀 | `postgres` |
| `schema.include.list` | 要包含的数据库模式 | `public` |
| `table.include.list` | 要监控的表列表 | `public.messages` |
| `plugin.name` | 使用的 PostgreSQL 逻辑解码插件 | `pgoutput` |
| `slot.name` | 复制槽名称 | `debezium` |
| `publication.name` | 发布名称 | `dbz_publication` |
| `transforms` | 消息转换器名称 | `unwrap` |
| `transforms.unwrap.type` | 转换器类型 | `io.debezium.transforms.ExtractNewRecordState` |
| `heartbeat.interval.ms` | 心跳间隔（毫秒） | `5000` |

### 3.2 Kafka 主题配置

#### 创建主题命令

```bash
kafka-topics.sh --create \
  --bootstrap-server <kafka-service>:9092 \
  --replication-factor <replication-factor> \
  --partitions 3 \
  --topic <topic-name> \
  --command-config <client-properties-file>
```

#### 参数说明

| 参数 | 说明 | 示例值 |
|------|------|---------|
| `bootstrap-server` | Kafka 服务器地址 | `openebs-stack-kafka:9092` |
| `replication-factor` | 复制因子，高可用环境建议 ≥ 2 | `3`（高可用）或 `1`（单机） |
| `partitions` | 分区数，影响并行消费能力 | `3` |
| `topic` | 主题名称 | `postgres.public.messages` |

### 3.3 Quickwit 索引配置

#### 索引配置模板

```json
{
  "version": "0.8",
  "index_id": "messages",
  "doc_mapping": {
    "field_mappings": [
      {
        "name": "id",
        "type": "i64",
        "stored": true,
        "indexed": true
      },
      {
        "name": "message",
        "type": "text",
        "stored": true,
        "tokenizer": "chinese_compatible",
        "indexed": true
      },
      {
        "name": "user_id",
        "type": "i64",
        "stored": true,
        "indexed": true
      },
      {
        "name": "ts",
        "type": "datetime",
        "stored": true,
        "fast": true,
        "indexed": true
      }
    ],
    "dynamic_mapping": {
      "indexed": true,
      "tokenizer": "raw",
      "stored": true,
      "expand_dots": true
    }
  },
  "search_settings": {
    "default_search_fields": ["message"]
  },
  "indexing_settings": {
    "commit_timeout_secs": 10
  }
}
```

#### 字段映射参数说明

| 参数 | 说明 | 可选值/示例 |
|------|------|-------------|
| `name` | 字段名称 | `message`, `id` 等 |
| `type` | 字段类型 | `text`, `i64`, `datetime` 等 |
| `stored` | 是否存储字段值 | `true`, `false` |
| `indexed` | 是否索引该字段 | `true`, `false` |
| `tokenizer` | 分词器 | `chinese_compatible` (中文), `default` (英文), `raw` (不分词) |
| `fast` | 是否支持高速过滤和排序 | `true`, `false` |

#### 特殊配置说明

- `chinese_compatible`: 中文分词器，适用于中文内容检索
- `default_search_fields`: 默认搜索字段，用户未指定字段时搜索的字段列表
- `commit_timeout_secs`: 索引提交超时时间，影响实时性和性能的平衡

### 3.4 Quickwit Kafka 源配置

#### Kafka 源配置模板

```json
{
  "version": "0.8",
  "source_id": "kafka_source",
  "source_type": "kafka",
  "num_pipelines": <replication-factor>,
  "params": {
    "topic": "<kafka-topic>",
    "client_params": {
      "bootstrap.servers": "<kafka-service>:9092",
      "security.protocol": "SASL_PLAINTEXT",
      "sasl.mechanism": "PLAIN",
      "sasl.username": "<username>",
      "sasl.password": "<password>",
      "auto.offset.reset": "earliest"
    },
    "enable_backfill_mode": true
  }
}
```

#### 参数说明

| 参数 | 说明 | 示例值 |
|------|------|---------|
| `source_id` | 源标识符 | `kafka_source` |
| `source_type` | 源类型 | `kafka` |
| `num_pipelines` | 摄取管道数量，影响并行度 | `1`（单机）或 `3`（高可用） |
| `topic` | Kafka 主题名称 | `postgres.public.messages` |
| `bootstrap.servers` | Kafka 服务器地址 | `openebs-stack-kafka:9092` |
| `security.protocol` | 安全协议 | `SASL_PLAINTEXT` |
| `sasl.mechanism` | SASL 机制 | `PLAIN` |
| `auto.offset.reset` | 消费初始位置 | `earliest`（从头开始）或 `latest`（从最新开始） |
| `enable_backfill_mode` | 是否启用回填模式 | `true`（回填历史数据）或 `false`（仅处理新数据） |

## 4. 部署模式区别

### 4.1 单机部署

- PostgreSQL: 单实例部署，直接连接主库
- Kafka: 单个 Broker，复制因子设为 1
- Kafka Connect: 单实例部署
- Quickwit: 单实例部署，管道数为 1

### 4.2 高可用部署

- PostgreSQL: 使用主从架构，连接器配置连接到主节点
- Kafka: 多个 Broker，复制因子通常设为 3
- Kafka Connect: 多实例部署，增强可靠性
- Quickwit: 多实例部署，摄取管道数与 Kafka 复制因子匹配

## 5. 操作示例

### 5.1 创建数据并验证

1. **插入测试数据**:

```bash
kubectl run pg-insert-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="<namespace>" -- \
  psql "<pg-connection-string>" -c \
  "INSERT INTO public.messages (message, user_id) VALUES ('测试消息', 1001);"
```

2. **查询 Quickwit 索引**:

```bash
# 使用 CLI 查询
kubectl exec -it <quickwit-pod> -- quickwit index search --index messages --query "message:测试" --max-hits 10

# 使用 REST API 查询
kubectl exec -it <quickwit-pod> -- curl -s -X POST 'http://localhost:7280/api/v1/messages/search' \
  -H 'Content-Type: application/json' \
  -d '{"query": "message:测试", "max_hits": 5}'
```

### 5.2 监控数据变更流

1. **检查 PostgreSQL 复制槽状态**:

```sql
SELECT * FROM pg_replication_slots WHERE slot_name = 'debezium';
```

2. **查看 Kafka 主题消息**:

```bash
kubectl exec -it <kafka-pod> -- \
  kafka-console-consumer.sh --bootstrap-server <kafka-service>:9092 \
  --topic postgres.public.messages --from-beginning
```

3. **查看 Quickwit 索引统计信息**:

```bash
kubectl exec -it <quickwit-pod> -- quickwit index describe --index messages
```

## 6. 常见问题与解决方案

1. **复制槽未创建**:
   - 确认 PostgreSQL 配置正确开启了逻辑复制
   - 检查连接器配置中的用户权限

2. **数据未同步到 Kafka**:
   - 检查 Debezium 连接器状态: `curl -s http://<connect-service>:8083/connectors/postgres-source/status`
   - 查看连接器日志中是否有错误

3. **数据未索引到 Quickwit**:
   - 确认 Kafka 源配置正确
   - 检查 Quickwit 日志是否有错误信息
   - 验证索引映射是否与数据结构匹配

4. **中文搜索不准确**:
   - 确认使用了 `chinese_compatible` 分词器
   - 检查查询语法是否正确

5. **排序问题解决方案**：
   - 如果使用排序功能导致400错误，首先检查索引配置中该字段是否设置了 `fast: true`
   - Quickwit中排序需要使用 `sort_by_field` 参数而不是 `sort_by`，且值应为字符串而非列表
   - 在服务器端排序不可用时，建议使用客户端排序: `sorted_results = sorted(results.get('hits', []), key=lambda x: x.get('ts', ''), reverse=True)`
   - 降序排序用正常字段名，升序排序在字段名前加减号，如 `-ts`

6. **时间范围查询问题**：
   - 确保查询的时间范围与实际数据的时间范围有交集
   - 检查时间格式是否正确，应为 ISO 8601 格式 (如 `2025-05-18T05:48:55Z`)
   - 简化查询，先使用 `*` 查询确认能够返回结果，再逐步添加条件

7. **空结果问题**：
   - 验证索引中确实存在数据：`curl -s http://<quickwit-host>:7280/api/v1/<index-id>/search -d '{"query":"*"}'`
   - 检查查询条件是否过于严格，尝试使用更宽松的查询条件
   - 使用 `message:*` 这样的通配符查询测试是否能返回所有文档

## 7. 最佳实践

1. **连接器配置**:
   - 在高可用环境中，设置适当的复制因子（通常为3）
   - 合理配置 `max.batch.size` 和 `poll.interval.ms` 以平衡性能和资源消耗

2. **索引设计**:
   - 对频繁查询的字段设置 `fast: true` 以提高查询性能
   - 选择合适的分词器，对中文内容使用 `chinese_compatible`

3. **运维管理**:
   - 定期监控复制槽状态，避免 WAL 日志积压
   - 定期检查和清理不再使用的 Kafka 主题数据 

## 8. Python应用示例

本节提供使用Python调用Quickwit REST API进行全文检索的代码示例，包括基本搜索、高级过滤、分页查询等功能实现。

### 8.1 环境准备

首先安装必要的Python依赖：

```bash
pip install requests pandas
```

#### Quickwit API 响应格式说明

Quickwit REST API 的搜索响应格式如下：

```json
{
  "num_hits": 3,
  "hits": [
    {
      "id": 6,
      "message": "测试消息",
      "ts": "2025-05-18T05:48:55.381959Z",
      "user_id": 1001
    },
    // 更多命中结果...
  ],
  "elapsed_time_micros": 18548,
  "errors": []
}
```

### 8.2 基本搜索示例

```python
import requests
import json
from typing import Dict, List, Any, Optional

class QuickwitClient:
    """Quickwit搜索客户端"""
    
    def __init__(self, base_url: str, index_id: str):
        """
        初始化Quickwit客户端
        
        Args:
            base_url: Quickwit服务地址，例如 'http://localhost:7280'
            index_id: 索引ID，例如 'messages'
        """
        self.base_url = base_url.rstrip('/')
        self.index_id = index_id
        self.search_endpoint = f"{self.base_url}/api/v1/{self.index_id}/search"
    
    def search(self, 
               query: str, 
               max_hits: int = 10,
               start_offset: int = 0,
               search_fields: Optional[List[str]] = None,
               sort_by: Optional[List[Dict[str, str]]] = None,
               target_fields: Optional[List[str]] = None) -> Dict[str, Any]:
        """
        执行搜索查询
        
        Args:
            query: 查询语句，例如 'message:测试'
            max_hits: 最大返回结果数
            start_offset: 结果起始偏移量（用于分页）
            search_fields: 搜索字段列表
            sort_by: 排序规则
            target_fields: 要返回的字段列表
            
        Returns:
            搜索结果字典
        """
        payload = {
            "query": query,
            "max_hits": max_hits,
            "start_offset": start_offset
        }
        
        if search_fields:
            payload["search_fields"] = search_fields
            
        if sort_by:
            if len(sort_by) > 0:
                first_sort = sort_by[0]
                field = first_sort.get("field", "")
                order = first_sort.get("order", "desc")
                payload["sort_by_field"] = field
                if order.lower() == "asc":
                    payload["sort_by_field"] = "-" + field
        
        if target_fields:
            payload["target_fields"] = target_fields
        
        try:
            response = requests.post(
                self.search_endpoint,
                headers={"Content-Type": "application/json"},
                data=json.dumps(payload)
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"搜索请求失败: {e}")
            # 尝试获取更多错误详情
            if hasattr(e, 'response') and e.response is not None:
                try:
                    error_detail = e.response.json()
                    print(f"错误详情: {error_detail}")
                except:
                    pass
            return {"error": str(e)}

# 使用示例
if __name__ == "__main__":
    # 创建客户端实例
    client = QuickwitClient(
        base_url="http://10.233.11.93:7280",  # 修改为实际的Quickwit服务地址
        index_id="messages"
    )
    
    # 基本搜索
    results = client.search("message:测试")
    print(f"找到 {results.get('num_hits', 0)} 条匹配结果")
    
    # 打印搜索结果
    for hit in results.get('hits', []):
        print(f"ID: {hit.get('id')}, 得分: {hit.get('score', None)}")
        print(f"消息: {hit.get('message')}")
        print(f"用户ID: {hit.get('user_id')}")
        print(f"时间戳: {hit.get('ts')}")
        print("-" * 40)
```

### 8.3 高级查询示例

```python
def advanced_search_examples(client: QuickwitClient):
    """展示各种高级搜索用法"""
    
    # 1. 字段精确匹配
    results = client.search("user_id:1001")
    print(f"用户ID为1001的消息数: {results.get('num_hits', 0)}")
    
    # 2. 组合查询 - AND 操作符
    results = client.search("message:测试 AND user_id:1001")
    print(f"包含'测试'且用户ID为1001的消息数: {results.get('num_hits', 0)}")
    
    # 3. 组合查询 - OR 操作符
    results = client.search("message:测试 OR message:问题")
    print(f"包含'测试'或'问题'的消息数: {results.get('num_hits', 0)}")
    
    # 4. 按时间范围过滤 - 使用实际数据的年份
    results = client.search("ts:[2025-01-01T00:00:00Z TO 2025-12-31T23:59:59Z]")
    print(f"2025年的消息数: {results.get('num_hits', 0)}")
    
    # 5. 使用手动排序功能
    # 先获取所有匹配结果，然后在应用代码中进行排序
    results = client.search(query="message:测试", max_hits=20)
    # 在Python代码中手动排序结果
    hits = results.get('hits', [])
    # 手动按时间戳排序
    sorted_hits = sorted(hits, key=lambda x: x.get('ts', ''), reverse=True)
    print(f"获取到 {len(sorted_hits)} 条结果，按时间戳倒序排列:")
    for hit in sorted_hits[:3]:
        print(f"时间: {hit.get('ts')} - {hit.get('message')}")
    
    # 6. 分页查询示例
    page_size = 2
    try:
        page1 = client.search(query="*", max_hits=page_size, start_offset=0)
        page2 = client.search(query="*", max_hits=page_size, start_offset=page_size)
        
        print(f"第一页结果数: {len(page1.get('hits', []))}")
        print(f"第二页结果数: {len(page2.get('hits', []))}")
    except Exception as e:
        print(f"分页查询异常: {e}")
```

### 8.4 故障排查指南

使用Python调用Quickwit API时可能遇到的常见问题及解决方法：

1. **连接错误**：
   - 检查Quickwit服务是否正常运行：`curl -s http://<quickwit-host>:7280/health`
   - 验证网络连接和防火墙设置，确保可以从Python应用访问Quickwit服务

2. **400错误 (Bad Request)**：
   - 检查查询语法是否正确，特别是字段名称和值的格式
   - 时间范围查询格式应符合 `ts:[2023-01-01T00:00:00Z TO 2023-12-31T23:59:59Z]` 的形式
   - 确保排序字段已设置 `fast: true` 属性
   - **排序问题解决方案**：
     - 如果使用排序功能导致400错误，首先检查索引配置中该字段是否设置了 `fast: true`
     - Quickwit中排序需要使用 `sort_by_field` 参数而不是 `sort_by`，且值应为字符串而非列表
     - 在服务器端排序不可用时，建议使用客户端排序: `sorted_results = sorted(results.get('hits', []), key=lambda x: x.get('ts', ''), reverse=True)`
     - 降序排序用正常字段名，升序排序在字段名前加减号，如 `-ts`
   - **时间范围查询问题**：
     - 确保查询的时间范围与实际数据的时间范围有交集
     - 检查时间格式是否正确，应为 ISO 8601 格式 (如 `2025-05-18T05:48:55Z`)
     - 简化查询，先使用 `*` 查询确认能够返回结果，再逐步添加条件

3. **空结果问题**：
   - 验证索引中确实存在数据：`curl -s http://<quickwit-host>:7280/api/v1/<index-id>/search -d '{"query":"*"}'`
   - 检查查询条件是否过于严格，尝试使用更宽松的查询条件
   - 使用 `message:*` 这样的通配符查询测试是否能返回所有文档

4. **中文分词问题**：
   - 确保索引配置中对中文字段使用了 `chinese_compatible` 分词器
   - 测试不同的查询方式，如完整词语、部分词语等

5. **性能优化**：
   - 对于大型结果集，使用分页查询而不是一次请求所有结果
   - 限制返回字段：在请求中添加 `"target_fields": ["id", "message"]` 参数
   - 对频繁查询的字段使用过滤器缓存：`"filters_cache_fields": ["user_id", "ts"]`

6. **API调试**：
   - 使用HTTP客户端(如curl)直接调用API检查原始响应：
   ```bash
   curl -X POST 'http://<quickwit-host>:7280/api/v1/<index-id>/search' \
     -H 'Content-Type: application/json' \
     -d '{"query":"message:测试", "max_hits": 10}'
   ```
   - 使用Python的requests模块查看完整HTTP交互：
   ```python
   import requests
   response = requests.post(
       'http://<quickwit-host>:7280/api/v1/<index-id>/search',
       json={"query": "message:测试"},
       headers={"Content-Type": "application/json"}
   )
   print("状态码:", response.status_code)
   print("响应头:", response.headers)
   print("响应内容:", response.text)
   ```

## 9. 实时检索优化配置

根据实际部署场景，可以从以下几个方面进行优化配置：

### 9.1 PostgreSQL 优化

1. **WAL 配置优化**：
   ```ini
   wal_level = logical
   max_wal_senders = 10
   max_replication_slots = 10
   wal_keep_size = '1GB'
   max_wal_size = '1GB'
   min_wal_size = '80MB'
   ```

2. **复制槽配置**：
   - 定期清理未使用的复制槽
   - 监控复制延迟：`SELECT * FROM pg_stat_replication;`

### 9.2 Debezium 连接器优化

1. **性能相关参数**：
   ```json
   {
     "poll.interval.ms": "100",           // 降低轮询间隔
     "max.batch.size": "2048",            // 增加批处理大小
     "max.queue.size": "16384",           // 增加队列大小
     "heartbeat.interval.ms": "1000",      // 降低心跳间隔
     "snapshot.fetch.size": "2048",       // 快照获取大小
     "database.history.kafka.recovery.poll.interval.ms": "100"  // 恢复轮询间隔
   }
   ```

2. **并行处理配置**：
   ```json
   {
     "tasks.max": "3",                    // 增加并行任务数
     "database.server.id": "1",           // 确保唯一ID
     "database.server.name": "postgres"    // 服务器名称
   }
   ```

### 9.3 Kafka 优化

1. **主题配置**：
   ```bash
   kafka-topics.sh --create \
     --bootstrap-server <kafka-service>:9092 \
     --topic postgres.public.messages \
     --partitions 3 \
     --replication-factor 3 \
     --config retention.ms=3600000 \
     --config segment.bytes=1073741824 \
     --config min.insync.replicas=2
   ```

2. **生产者配置**：
   ```properties
   acks=1
   linger.ms=0
   batch.size=16384
   compression.type=none
   ```

3. **消费者配置**：
   ```properties
   fetch.min.bytes=1
   fetch.max.wait.ms=100
   max.partition.fetch.bytes=1048576
   ```

### 9.4 Quickwit 优化

1. **索引配置优化**：
   ```json
   {
     "indexing_settings": {
       "commit_timeout_secs": 1,           // 降低提交超时
       "docstore_compression": "none",     // 禁用压缩以提高性能
       "merge_policy": {
         "max_merge_docs": 1000000,
         "min_level_size": 1000000
       }
     },
     "search_settings": {
       "default_search_fields": ["message"],
       "fast_field": ["ts", "user_id"]     // 快速字段配置
     }
   }
   ```

2. **Kafka 源配置优化**：
   ```json
   {
     "source_id": "kafka_source",
     "source_type": "kafka",
     "num_pipelines": 3,                   // 增加管道数
     "params": {
       "topic": "postgres.public.messages",
       "client_params": {
         "bootstrap.servers": "<kafka-service>:9092",
         "auto.offset.reset": "latest",    // 从最新位置开始消费
         "fetch.min.bytes": 1,
         "fetch.max.wait.ms": 100,
         "max.partition.fetch.bytes": 1048576
       },
       "enable_backfill_mode": false       // 禁用回填模式
     }
   }
   ```

3. **系统资源优化**：
   - 增加 Quickwit 节点的内存配置
   - 使用 SSD 存储
   - 配置足够数量的 CPU 核心

### 9.5 监控与调优

1. **性能监控指标**：
   - Debezium 延迟：`curl -s http://<connect-service>:8083/connectors/postgres-source/status`
   - Kafka 消费延迟：`kafka-consumer-groups.sh --bootstrap-server <kafka-service>:9092 --describe --group <group-id>`
   - Quickwit 索引延迟：`quickwit index describe --index messages`

2. **定期维护**：
   - 定期清理过期的 Kafka 消息
   - 监控并清理未使用的复制槽
   - 定期优化 Quickwit 索引

### 9.6 最佳实践建议

1. **数据量控制**：
   - 控制单条消息大小，避免过大的消息体
   - 合理设置 Kafka 消息保留时间
   - 定期清理历史数据

2. **架构优化**：
   - 使用多分区提高并行处理能力
   - 合理设置复制因子确保高可用
   - 考虑使用 SSD 存储提高 I/O 性能

3. **查询优化**：
   - 使用精确匹配替代模糊查询
   - 合理使用字段过滤
   - 避免复杂的组合查询

通过以上优化配置，可以将数据写入到检索的延迟控制在秒级以内。具体配置参数需要根据实际业务场景和系统资源进行调整。