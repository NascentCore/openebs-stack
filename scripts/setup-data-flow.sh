#!/bin/bash
# 数据流配置脚本(高可用版): PostgreSQL -> Kafka Connect -> Kafka -> Quickwit
# 此脚本在部署完成后配置整个数据流路径

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 引入工具函数
source "$SCRIPT_DIR/k8s-utils.sh"

# 彩色输出函数
print_section() {
  echo -e "\n\033[1;36m========== $1 ==========\033[0m"
}

print_step() {
  echo -e "\033[0;34m>>> $1\033[0m"
}

print_success() {
  echo -e "\033[0;32m✓ $1\033[0m"
}

print_error() {
  echo -e "\033[0;31m✗ $1\033[0m"
  exit 1
}

# 自动检测部署模式（单机或高可用）
detect_deployment_mode() {
  # 检查是否存在PostgreSQL-HA服务
  if kubectl get svc openebs-stack-postgresql-ha-pgpool &>/dev/null; then
    echo "高可用"
  else
    echo "单机"
  fi
}

# 根据部署模式设置服务名称
DEPLOYMENT_MODE=$(detect_deployment_mode)
if [ "$DEPLOYMENT_MODE" == "高可用" ]; then
  print_success "检测到高可用部署模式"
  # 使用指向主节点的服务，无需区分读写
  PG_SERVICE="openebs-stack-postgresql-ha-primary"
  REPLICATION_FACTOR=3
else
  print_success "检测到单机部署模式"
  # 单机模式下使用单一连接
  PG_SERVICE="openebs-stack-postgresql"
  REPLICATION_FACTOR=1
fi

# 设置默认参数
NAMESPACE=$(get_current_namespace)
PG_PORT=5432
PG_USER="postgres"
PG_PASSWORD="yourpassword"
PG_DATABASE="yourdb"  # 根据values-prod-all.yaml配置修改为yourdb
KAFKA_SERVICE="openebs-stack-kafka"
KAFKA_TOPIC="postgres.public.messages"

# 创建连接字符串
PG_CONN="postgresql://${PG_USER}:${PG_PASSWORD}@${PG_SERVICE}:${PG_PORT}/${PG_DATABASE}"

# 获取Kafka Connect和Quickwit的Pod名称 - 获取第一个Pod
KAFKA_CONNECT_POD=$(kubectl get pods -n "$NAMESPACE" | grep "openebs-stack-kafka-connect" | head -1 | awk '{print $1}')
QUICKWIT_POD=$(kubectl get pods -n "$NAMESPACE" | grep "openebs-stack-quickwit" | head -1 | awk '{print $1}')
KAFKA_POD=$(kubectl get pods -n "$NAMESPACE" | grep "openebs-stack-kafka-controller" | head -1 | awk '{print $1}')

# 获取Kafka密码
KAFKA_PASSWORD=$(get_secret_value "openebs-stack-kafka-user-passwords" "client-passwords" "$NAMESPACE" 2>/dev/null || echo 'temporaryPassword123')

# 显示配置信息
print_section "配置信息"
echo "部署模式: $DEPLOYMENT_MODE"
echo "命名空间: $NAMESPACE"
echo "PostgreSQL服务: $PG_SERVICE"
echo "Kafka服务: $KAFKA_SERVICE"
echo "Kafka Pod: $KAFKA_POD"
echo "Kafka Connect Pod: $KAFKA_CONNECT_POD"
echo "Quickwit Pod: $QUICKWIT_POD"
echo "复制因子: $REPLICATION_FACTOR"
echo "Kafka主题: $KAFKA_TOPIC"

# 等待所有组件准备就绪
print_section "等待组件准备就绪"

if [ "$DEPLOYMENT_MODE" == "高可用" ]; then
  print_step "等待PostgreSQL节点准备就绪..."
  wait_for_pod_ready "openebs-stack-postgresql-ha-postgresql" "$NAMESPACE" 60 15 || print_error "PostgreSQL HA节点未准备就绪"
  print_success "PostgreSQL HA节点准备就绪"

  print_step "等待PostgreSQL主节点服务准备就绪..."
  # 检查主节点服务是否可用
  kubectl get svc "$PG_SERVICE" -n "$NAMESPACE" > /dev/null 2>&1 || print_error "PostgreSQL主节点服务未准备就绪"
  print_success "PostgreSQL主节点服务准备就绪"
else
  print_step "等待PostgreSQL准备就绪..."
  wait_for_pod_ready "openebs-stack-postgresql" "$NAMESPACE" 60 15 || print_error "PostgreSQL未准备就绪"
  print_success "PostgreSQL准备就绪"
fi

print_step "等待Kafka准备就绪..."
wait_for_pod_ready "openebs-stack-kafka-controller" "$NAMESPACE" 60 15 || print_error "Kafka控制器未准备就绪"
print_success "Kafka控制器准备就绪"

print_step "等待Kafka Connect准备就绪..."
wait_for_pod_ready "openebs-stack-kafka-connect" "$NAMESPACE" 60 15 || print_error "Kafka Connect未准备就绪"
print_success "Kafka Connect准备就绪"

print_step "等待Quickwit准备就绪..."
wait_for_pod_ready "openebs-stack-quickwit" "$NAMESPACE" 60 15 || print_error "Quickwit未准备就绪"
print_success "Quickwit准备就绪"

if [ "$DEPLOYMENT_MODE" == "单机" ]; then
  if [ ! -f "$SCRIPT_DIR/.kafka_single_node_configured" ]; then
    configure_kafka_single_node
    touch "$SCRIPT_DIR/.kafka_single_node_configured"
  fi
fi

# 检查Vector扩展安装状态
print_section "检查Vector扩展"
kubectl run pg-install-vector-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "$PG_CONN" -c \
  "CREATE EXTENSION IF NOT EXISTS vector;" || print_error "安装Vector扩展失败"
print_success "Vector扩展安装成功"

# 第1步: 在PostgreSQL中创建测试表和数据
print_section "配置PostgreSQL"

print_step "在PostgreSQL中创建消息表..."
MESSAGES_TABLE_SQL="
CREATE TABLE IF NOT EXISTS public.messages (
  id SERIAL PRIMARY KEY,
  message TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  ts TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
"
kubectl run pg-create-table-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "$PG_CONN" -c "$MESSAGES_TABLE_SQL" || print_error "创建消息表失败"
print_success "消息表创建成功"

print_step "插入测试数据..."
kubectl run pg-insert-data-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "$PG_CONN" -c \
  "INSERT INTO public.messages (message, user_id, ts) VALUES 
   ('这是一条测试消息', 1001, '2025-05-15T05:20:06.246314Z'),
   ('这是另一条测试消息', 1002, '2025-05-15T05:50:06.246314Z'),
   ('重要通知: 系统维护', 1001, '2025-05-15T06:05:06.246314Z'),
   ('欢迎使用我们的服务', 1003, '2025-05-15T06:15:06.246314Z'),
   ('这是最新的消息', 1002, '2025-05-15T06:20:06.246314Z')
   ON CONFLICT DO NOTHING;" || print_error "插入测试数据失败"
print_success "测试数据插入成功"

# 第2步: 创建PostgreSQL publication和复制槽
print_section "配置PostgreSQL CDC"

print_step "创建PostgreSQL publication..."
PG_PUBLICATION_SQL="
DROP PUBLICATION IF EXISTS dbz_publication;
CREATE PUBLICATION dbz_publication FOR TABLE public.messages;
"
kubectl run pg-create-pub-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "$PG_CONN" -c "$PG_PUBLICATION_SQL" || print_error "创建PostgreSQL publication失败"
print_success "PostgreSQL publication创建成功"

# 第3步: 配置Kafka Connect
print_section "配置Kafka Connect"

# 获取Kafka Connect服务地址
KAFKA_CONNECT_URL="http://$(kubectl get svc kafka-connect -n $NAMESPACE -o jsonpath='{.spec.clusterIP}'):8083"

# 检查并删除已存在的连接器
print_step "检查并删除已存在的Debezium PostgreSQL连接器..."
kubectl run kafka-connect-check-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
  curl -s -X DELETE "${KAFKA_CONNECT_URL}/connectors/postgres-source" || echo "没有找到现有连接器或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 5

print_step "删除PostgreSQL复制槽(如果存在)..."
kubectl run pg-drop-slot-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "$PG_CONN" -c \
  "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'debezium';" || echo "未找到复制槽或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 5

print_step "创建Debezium PostgreSQL连接器..."
# 构建PostgreSQL连接器配置 - 使用单一主节点服务
PG_CONNECTOR_CONFIG=$(cat <<EOF
{
  "name": "postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "$PG_SERVICE",
    "database.port": "$PG_PORT",
    "database.user": "$PG_USER",
    "database.password": "$PG_PASSWORD",
    "database.dbname": "$PG_DATABASE",
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
    
    "config.storage.replication.factor": "$REPLICATION_FACTOR",
    "offset.storage.replication.factor": "$REPLICATION_FACTOR", 
    "status.storage.replication.factor": "$REPLICATION_FACTOR",
    
    "heartbeat.interval.ms": "5000",
    "max.queue.size": "8192",
    "max.batch.size": "1024",
    "poll.interval.ms": "1000"
  }
}
EOF
)

# 使用curl Pod发送连接器配置
kubectl run kafka-connect-create-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
  -X POST -H "Content-Type: application/json" -d "$PG_CONNECTOR_CONFIG" "${KAFKA_CONNECT_URL}/connectors" || print_error "创建Debezium PostgreSQL连接器失败"

print_success "Debezium PostgreSQL连接器创建成功"

# 等待连接器启动并创建主题
print_step "等待连接器启动并创建主题(10秒)..."
sleep 10

# 第4步: 确认Kafka主题是否已经创建
print_section "验证Kafka主题"

print_step "直接创建Kafka主题 $KAFKA_TOPIC..."

# 准备Kafka认证配置文件
cat > /tmp/client.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
EOF

# 准备JAAS配置
cat > /tmp/kafka-jaas.conf << EOF
KafkaClient {
  org.apache.kafka.common.security.plain.PlainLoginModule required
  username="user1"
  password="$KAFKA_PASSWORD";
};
EOF

# 复制配置文件到Kafka Pod
kubectl cp /tmp/client.properties $NAMESPACE/$KAFKA_POD:/tmp/client.properties
kubectl cp /tmp/kafka-jaas.conf $NAMESPACE/$KAFKA_POD:/tmp/kafka-jaas.conf

# 在Kafka Pod中创建主题
kubectl exec -it $KAFKA_POD -n "$NAMESPACE" -- bash -c "
  export KAFKA_OPTS='-Djava.security.auth.login.config=/tmp/kafka-jaas.conf'
  
  # 先尝试检查主题是否存在
  if kafka-topics.sh --list --bootstrap-server $KAFKA_SERVICE:9092 --command-config /tmp/client.properties | grep -q '$KAFKA_TOPIC'; then
    echo 'Kafka主题已存在'
  else
    echo '创建Kafka主题'
    kafka-topics.sh --create --bootstrap-server $KAFKA_SERVICE:9092 --replication-factor $REPLICATION_FACTOR --partitions 3 --topic $KAFKA_TOPIC --command-config /tmp/client.properties || echo 'Kafka主题创建失败，尝试继续执行'
  fi
"

print_success "Kafka主题配置完成"

# 第5步: 创建Quickwit索引
print_section "配置Quickwit"

# 先删除已存在的索引
print_step "检查并删除已存在的Quickwit索引..."
kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit index delete --index messages --yes 2>/dev/null || echo "没有找到索引或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 5

print_step "创建Quickwit索引..."
# 创建Quickwit索引配置
cat <<EOF > /tmp/quickwit-index-config.json
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
EOF

# 复制配置文件到Quickwit容器
kubectl cp /tmp/quickwit-index-config.json "$NAMESPACE/$QUICKWIT_POD:/tmp/index-config.json"

# 使用CLI创建索引
kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit index create --index-config /tmp/index-config.json --overwrite --yes || print_error "使用CLI创建索引失败"

print_success "Quickwit索引创建成功"

# 第6步: 配置Quickwit消息源
print_section "配置Quickwit消息源"

print_step "检查并删除已存在的Quickwit Kafka源..."
# 通过CLI删除Kafka源
kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit source delete --index messages --source kafka_source --yes 2>/dev/null || echo "没有找到现有Kafka源或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 5

print_step "配置Quickwit Kafka源..."
# 为环境配置Kafka源
QUICKWIT_SOURCE_CONFIG=$(cat <<EOF
{
  "version": "0.8",
  "source_id": "kafka_source",
  "source_type": "kafka",
  "num_pipelines": $REPLICATION_FACTOR,
  "params": {
    "topic": "$KAFKA_TOPIC",
    "client_params": {
      "bootstrap.servers": "${KAFKA_SERVICE}:9092",
      "security.protocol": "SASL_PLAINTEXT",
      "sasl.mechanism": "PLAIN",
      "sasl.username": "user1",
      "sasl.password": "$KAFKA_PASSWORD",
      "auto.offset.reset": "earliest"
    },
    "enable_backfill_mode": true
  }
}
EOF
)

# 使用CLI方式创建Kafka源
echo "$QUICKWIT_SOURCE_CONFIG" > /tmp/source-config.json
kubectl cp /tmp/source-config.json "$NAMESPACE/$QUICKWIT_POD:/tmp/source-config.json"

# 使用CLI创建Kafka源
kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit source create --index messages --source-config /tmp/source-config.json --yes || print_error "使用CLI创建Kafka源失败"

print_success "Quickwit Kafka源配置成功"

# 配置成功
print_section "配置完成"
echo -e "\033[1;32m数据流配置已完成: PostgreSQL -> Kafka Connect -> Kafka -> Quickwit\033[0m"
echo "部署模式: $DEPLOYMENT_MODE（复制因子: $REPLICATION_FACTOR）"
echo "可以在PostgreSQL中插入新数据，然后在Quickwit中查询:"

# 显示查询示例
echo -e "\n\033[1;34m插入新数据示例:\033[0m"
echo "kubectl run pg-insert-\$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace=\"$NAMESPACE\" -- \\"
echo "  psql \"$PG_CONN\" -c \\"
echo "  \"INSERT INTO public.messages (message, user_id) VALUES ('测试消息', 1001);\""

echo -e "\nQuickwit查询示例:"
echo "# 使用CLI查询文本内容(推荐):"
echo "kubectl exec -it $QUICKWIT_POD -- quickwit index search --index messages --query \"message:测试\" --max-hits 10"
echo ""
echo "# 或使用REST API查询:"
echo "kubectl exec -it $QUICKWIT_POD -- curl -s -X POST 'http://localhost:7280/api/v1/messages/search' -H 'Content-Type: application/json' -d '{\"query\": \"message:测试\", \"max_hits\": 5}'" 