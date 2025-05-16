#!/bin/bash
# 数据流配置脚本: PostgreSQL -> Kafka Connect -> Kafka -> Quickwit
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

# 设置默认参数
NAMESPACE=$(get_current_namespace)
PG_SERVICE="openebs-stack-postgresql"
PG_PORT=5432
PG_USER="postgres"
PG_PASSWORD="yourpassword"
PG_DATABASE="postgres"
KAFKA_SERVICE="openebs-stack-kafka"
KAFKA_CONNECT_SERVICE="kafka-connect"
QUICKWIT_SERVICE="openebs-stack-quickwit"

# 获取Kafka密码
KAFKA_PASSWORD=$(get_secret_value "openebs-stack-kafka-user-passwords" "client-passwords" "$NAMESPACE" 2>/dev/null || echo 'temporaryPassword123')

# 显示配置信息
print_section "配置信息"
echo "命名空间: $NAMESPACE"
echo "PostgreSQL服务: $PG_SERVICE"
echo "Kafka服务: $KAFKA_SERVICE"
echo "Kafka Connect服务: $KAFKA_CONNECT_SERVICE"
echo "Quickwit服务: $QUICKWIT_SERVICE"

if [ ! -f "$SCRIPT_DIR/.kafka_single_node_configured" ]; then
  configure_kafka_single_node
  touch "$SCRIPT_DIR/.kafka_single_node_configured"
fi

# 等待所有组件准备就绪
print_section "等待组件准备就绪"

print_step "等待PostgreSQL准备就绪..."
wait_for_pod_ready "$PG_SERVICE" "$NAMESPACE" 30 10 || print_error "PostgreSQL未准备就绪"
print_success "PostgreSQL准备就绪"

print_step "等待Kafka准备就绪..."
wait_for_pod_ready "$KAFKA_SERVICE" "$NAMESPACE" 30 10 || print_error "Kafka未准备就绪"
print_success "Kafka准备就绪"

print_step "等待Kafka Connect准备就绪..."
wait_for_pod_ready "$KAFKA_CONNECT_SERVICE" "$NAMESPACE" 30 10 || print_error "Kafka Connect未准备就绪"
print_success "Kafka Connect准备就绪"

print_step "等待Quickwit准备就绪..."
wait_for_pod_ready "$QUICKWIT_SERVICE" "$NAMESPACE" 30 10 || print_error "Quickwit未准备就绪"
print_success "Quickwit准备就绪"

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
  psql "postgresql://${PG_USER}:${PG_PASSWORD}@${PG_SERVICE}:${PG_PORT}/${PG_DATABASE}" -c "$MESSAGES_TABLE_SQL" || print_error "创建消息表失败"
print_success "消息表创建成功"

print_step "插入测试数据..."
kubectl run pg-insert-data-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "postgresql://${PG_USER}:${PG_PASSWORD}@${PG_SERVICE}:${PG_PORT}/${PG_DATABASE}" -c \
  "INSERT INTO public.messages (message, user_id, ts) VALUES 
   ('这是一条测试消息', 1001, '2025-05-15T05:20:06.246314Z'),
   ('这是另一条测试消息', 1002, '2025-05-15T05:50:06.246314Z'),
   ('重要通知: 系统维护', 1001, '2025-05-15T06:05:06.246314Z'),
   ('欢迎使用我们的服务', 1003, '2025-05-15T06:15:06.246314Z'),
   ('这是最新的消息', 1002, '2025-05-15T06:20:06.246314Z')
   ON CONFLICT DO NOTHING;" || print_error "插入测试数据失败"
print_success "测试数据插入成功"

# 第2步: 配置Kafka Connect
print_section "配置Kafka Connect"

# 获取Kafka Connect URL
KAFKA_CONNECT_URL=$(get_service_url "$KAFKA_CONNECT_SERVICE" "http" "" "$NAMESPACE")

# 检查并删除已存在的连接器
print_step "检查并删除已存在的Debezium PostgreSQL连接器..."
kubectl run kafka-connect-delete-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
  curl -s -X DELETE "${KAFKA_CONNECT_URL}/connectors/postgres-source" || echo "没有找到现有连接器或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 3

print_step "删除PostgreSQL复制槽(如果存在)..."
kubectl run pg-drop-slot-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "postgresql://${PG_USER}:${PG_PASSWORD}@${PG_SERVICE}:${PG_PORT}/${PG_DATABASE}" -c \
  "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'debezium';" || echo "未找到复制槽或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 3

print_step "创建Debezium PostgreSQL连接器..."
# 构建PostgreSQL连接器配置（添加了ExtractNewRecordState转换器）
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
    "transforms.unwrap.drop.tombstones": "false"
  }
}
EOF
)

# 使用kubectl创建临时Pod发送连接器配置
kubectl run kfk-connect-config-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
  -X POST -H "Content-Type: application/json" -d "$PG_CONNECTOR_CONFIG" "${KAFKA_CONNECT_URL}/connectors" || print_error "创建Debezium PostgreSQL连接器失败"

print_success "Debezium PostgreSQL连接器创建成功"

# 第3步: 创建Quickwit索引
print_section "配置Quickwit"
QUICKWIT_URL=$(get_service_url "$QUICKWIT_SERVICE" "http" "" "$NAMESPACE")

# 先获取并删除已存在的索引
print_step "检查并列出已存在的Quickwit索引..."
INDEXES_RESPONSE=$(kubectl run quickwit-list-index-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
  curl -s "${QUICKWIT_URL}/api/v1/index" || echo "获取索引列表失败")

if echo "$INDEXES_RESPONSE" | grep -q "messages"; then
  print_step "删除已存在的Quickwit索引..."
  kubectl run quickwit-delete-index-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
    curl -s -X DELETE "${QUICKWIT_URL}/api/v1/index/messages" || echo "删除索引失败，但将继续创建..."
fi

# 等待几秒钟确保删除操作完成
sleep 3

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
QUICKWIT_POD=$(kubectl get pods -n "$NAMESPACE" | grep quickwit | awk '{print $1}' | head -n 1)
if [ -z "$QUICKWIT_POD" ]; then
  print_error "未找到Quickwit Pod"
fi

kubectl cp /tmp/quickwit-index-config.json "$NAMESPACE/$QUICKWIT_POD:/tmp/index-config.json"

# 使用CLI创建索引
kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit index create --index-config /tmp/index-config.json --overwrite --yes || print_error "使用CLI创建索引失败"

# 获取index_uid
INDEX_INFO=$(kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit index list --output json)
INDEX_UID=$(echo "$INDEX_INFO" | grep -o '"[^"]*messages[^"]*"' | tr -d '"' | head -n 1)

if [[ -z "$INDEX_UID" ]]; then
  print_step "无法从响应中提取index_uid，尝试直接使用索引ID..."
  INDEX_UID="messages"
else
  print_success "成功获取index_uid: $INDEX_UID"
fi

# 直接尝试多种可能的API路径格式
if [ "$INDEX_UID" != "messages" ]; then
  API_PATHS=(
    "/api/v1/indexes/messages"
    "/api/v1/index/messages"
    "/api/v1/indexes/$INDEX_UID"
    "/api/v1/index/$INDEX_UID"
  )
else
  API_PATHS=(
    "/api/v1/indexes/messages"
    "/api/v1/index/messages"
  )
fi

SEARCH_URL=""
for path in "${API_PATHS[@]}"; do
  TEST_RESPONSE=$(kubectl run quickwit-test-path-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$NAMESPACE" -- \
    curl -s "${QUICKWIT_URL}${path}/search?query=*" || echo "路径不可访问")
  
  if ! echo "$TEST_RESPONSE" | grep -q "Route not found"; then
    print_success "找到有效的API路径: ${path}"
    SEARCH_URL="${QUICKWIT_URL}${path}"
    break
  fi
done

if [ -z "$SEARCH_URL" ]; then
  print_step "未能找到有效的API路径，继续使用CLI命令..."
  SEARCH_URL="${QUICKWIT_URL}/api/v1/index/$INDEX_UID"
fi

# 第4步: 配置Quickwit消息源
print_section "配置Quickwit消息源"

print_step "检查并删除已存在的Quickwit Kafka源..."
# 通过CLI删除Kafka源
kubectl exec -it "$QUICKWIT_POD" -n "$NAMESPACE" -- quickwit source delete --index messages --source kafka_source --yes || echo "没有找到现有Kafka源或删除失败，继续创建..."

# 等待几秒钟确保删除操作完成
sleep 3

print_step "配置Quickwit Kafka源..."
# 移除transform脚本，因为现在我们在Kafka Connect层面进行转换
QUICKWIT_SOURCE_CONFIG=$(cat <<EOF
{
  "version": "0.8",
  "source_id": "kafka_source",
  "source_type": "kafka",
  "num_pipelines": 1,
  "params": {
    "topic": "postgres.public.messages",
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

# 第5步: 创建PostgreSQL publication和复制槽
print_section "配置PostgreSQL CDC"

print_step "创建PostgreSQL publication..."
PG_PUBLICATION_SQL="
DROP PUBLICATION IF EXISTS dbz_publication;
CREATE PUBLICATION dbz_publication FOR TABLE public.messages;
"
kubectl run pg-create-pub-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$NAMESPACE" -- \
  psql "postgresql://${PG_USER}:${PG_PASSWORD}@${PG_SERVICE}:${PG_PORT}/${PG_DATABASE}" -c "$PG_PUBLICATION_SQL" || print_error "创建PostgreSQL publication失败"
print_success "PostgreSQL publication创建成功"

# 配置成功
print_section "配置完成"
echo -e "\033[1;32m数据流配置已完成: PostgreSQL -> Kafka Connect -> Kafka -> Quickwit\033[0m"
echo "可以在PostgreSQL中插入新数据，然后在Quickwit中查询:"

# 显示查询示例
echo -e "\n\033[1;34m插入新数据示例:\033[0m"
echo "kubectl run pg-insert-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace=\"$NAMESPACE\" -- \\"
echo "  psql \"postgresql://${PG_USER}:${PG_PASSWORD}@${PG_SERVICE}:${PG_PORT}/${PG_DATABASE}\" -c \\"
echo "  \"INSERT INTO public.messages (message, user_id) VALUES ('测试消息', 1001);\""

echo -e "\nQuickwit查询示例:"
echo "# 使用CLI查询文本内容(推荐):"
echo "kubectl exec -it \$(kubectl get pods | grep quickwit | awk '{print \$1}') -- quickwit index search --index messages --query \"message:测试\" --max-hits 10"
echo ""
echo "# 或使用REST API查询:"
echo "kubectl run quickwit-query-\$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace=\"$NAMESPACE\" -- \\"
echo "  curl -s -X POST '${QUICKWIT_URL}/api/v1/messages/search' -H 'Content-Type: application/json' -d '{\"query\": \"message:测试\", \"max_hits\": 5}'"
echo ""
echo "# 查询特定用户ID:"
echo "kubectl exec -it \$(kubectl get pods | grep quickwit | awk '{print \$1}') -- quickwit index search --index messages --query \"user_id:1001\" --max-hits 10" 