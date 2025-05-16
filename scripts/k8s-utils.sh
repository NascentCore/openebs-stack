#!/bin/bash
# Kubernetes环境工具函数脚本
# 可以被其他脚本通过 source k8s-utils.sh 方式引用

# 获取当前命名空间
get_current_namespace() {
  local ns
  ns=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
  echo "${ns:-default}"
}

# 获取POD IP地址
get_pod_ip() {
  local pod_name_pattern=$1
  local namespace=${2:-$(get_current_namespace)}
  
  # 获取匹配模式的第一个POD
  local pod_name=$(kubectl get pods -n "$namespace" | grep -E "$pod_name_pattern" | head -1 | awk '{print $1}')
  
  if [ -z "$pod_name" ]; then
    echo "错误: 未找到匹配 '$pod_name_pattern' 的Pod" >&2
    return 1
  fi
  
  # 获取POD IP地址
  local pod_ip=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.podIP}')
  
  if [ -z "$pod_ip" ]; then
    echo "错误: 无法获取Pod '$pod_name' 的IP地址" >&2
    return 1
  fi
  
  echo "$pod_ip"
}

# 获取POD名称
get_pod_name() {
  local pod_name_pattern=$1
  local namespace=${2:-$(get_current_namespace)}
  
  # 获取匹配模式的第一个POD
  local pod_list=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -E "$pod_name_pattern" || true)
  
  if [ -z "$pod_list" ]; then
    echo "错误: 未找到匹配 '$pod_name_pattern' 的Pod" >&2
    return 1
  fi
  
  local pod_name=$(echo "$pod_list" | head -1 | awk '{print $1}')
  
  if [ -z "$pod_name" ]; then
    echo "错误: 未找到匹配 '$pod_name_pattern' 的Pod" >&2
    return 1
  fi
  
  echo "$pod_name"
}

# 获取指定服务的端口
get_service_port() {
  local service_name=$1
  local port_name=$2  # 可选，如果提供则获取指定名称的端口
  local namespace=${3:-$(get_current_namespace)}
  
  local port_query
  if [ -z "$port_name" ]; then
    # 获取第一个端口
    port_query='{.spec.ports[0].port}'
  else
    # 获取指定名称的端口
    port_query="{.spec.ports[?(@.name==\"$port_name\")].port}"
  fi
  
  local port=$(kubectl get service "$service_name" -n "$namespace" -o jsonpath="$port_query" 2>/dev/null)
  
  if [ -z "$port" ]; then
    echo "错误: 无法获取服务 '$service_name' 的端口" >&2
    return 1
  fi
  
  echo "$port"
}

# 获取服务ClusterIP
get_service_ip() {
  local service_name=$1
  local namespace=${2:-$(get_current_namespace)}
  
  local cluster_ip=$(kubectl get service "$service_name" -n "$namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  
  if [ -z "$cluster_ip" ]; then
    echo "错误: 无法获取服务 '$service_name' 的ClusterIP" >&2
    return 1
  fi
  
  echo "$cluster_ip"
}

# 构建服务URL
get_service_url() {
  local service_name=$1
  local protocol=${2:-http}
  local port_name=$3  # 可选参数
  local namespace=${4:-$(get_current_namespace)}
  
  local service_ip=$(get_service_ip "$service_name" "$namespace")
  if [ $? -ne 0 ]; then
    return 1
  fi
  
  local port=$(get_service_port "$service_name" "$port_name" "$namespace")
  if [ $? -ne 0 ]; then
    return 1
  fi
  
  echo "${protocol}://${service_ip}:${port}"
}

# 获取PVC状态
get_pvc_status() {
  local pvc_name=$1
  local namespace=${2:-$(get_current_namespace)}
  
  local status=$(kubectl get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
  
  if [ -z "$status" ]; then
    echo "错误: 无法获取PVC '$pvc_name' 的状态" >&2
    return 1
  fi
  
  echo "$status"
}

# 等待Pod准备就绪
wait_for_pod_ready() {
  local pod_name_pattern=$1
  local namespace=${2:-$(get_current_namespace)}
  local max_attempts=${3:-30}
  local wait_seconds=${4:-5}
  
  echo "等待Pod '$pod_name_pattern' 准备就绪..."
  
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    echo "尝试 $attempt/$max_attempts: 检查Pod状态..."
    
    # 获取Pod名称
    local pod_name=$(get_pod_name "$pod_name_pattern" "$namespace")
    if [ -z "$pod_name" ]; then
      echo "Pod '$pod_name_pattern' 尚未创建，等待${wait_seconds}秒..."
      sleep $wait_seconds
      attempt=$((attempt + 1))
      continue
    fi
    
    # 检查Pod状态
    local ready=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    
    if [ "$ready" = "true" ]; then
      echo "Pod '$pod_name' 已准备就绪!"
      return 0
    fi
    
    echo "Pod '$pod_name' 尚未准备就绪，等待${wait_seconds}秒..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
  done
  
  echo "错误: Pod '$pod_name_pattern' 在超时期限内未准备就绪"
  return 1
}

# 在Pod内执行命令
exec_in_pod() {
  local pod_name_pattern=$1
  local command=$2
  local namespace=${3:-$(get_current_namespace)}
  local container_name=$4  # 可选，如果Pod有多个容器
  
  # 获取Pod名称
  local pod_name=$(get_pod_name "$pod_name_pattern" "$namespace")
  if [ -z "$pod_name" ]; then
    return 1
  fi
  
  local exec_cmd="kubectl exec $pod_name -n $namespace"
  if [ -n "$container_name" ]; then
    exec_cmd="$exec_cmd -c $container_name"
  fi
  exec_cmd="$exec_cmd -- $command"
  
  # 执行命令
  eval "$exec_cmd"
}

# 获取Secret的值
get_secret_value() {
  local secret_name=$1
  local key=$2
  local namespace=${3:-$(get_current_namespace)}
  
  local value=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d)
  
  if [ -z "$value" ]; then
    echo "错误: 无法获取Secret '$secret_name' 中的键 '$key'" >&2
    return 1
  fi
  
  echo "$value"
}

# 等待Job完成
wait_for_job_complete() {
  local job_name=$1
  local namespace=${2:-$(get_current_namespace)}
  local max_attempts=${3:-30}
  local wait_seconds=${4:-5}
  
  echo "等待Job '$job_name' 完成..."
  
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    echo "尝试 $attempt/$max_attempts: 检查Job状态..."
    
    # 检查Job是否存在
    if ! kubectl get job "$job_name" -n "$namespace" > /dev/null 2>&1; then
      echo "Job '$job_name' 不存在，等待${wait_seconds}秒..."
      sleep $wait_seconds
      attempt=$((attempt + 1))
      continue
    fi
    
    # 检查Job状态
    local succeeded=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    
    if [ "$succeeded" = "1" ]; then
      echo "Job '$job_name' 已成功完成!"
      return 0
    fi
    
    # 检查是否失败
    local failed=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.failed}' 2>/dev/null)
    if [ -n "$failed" ] && [ "$failed" -gt 0 ]; then
      echo "警告: Job '$job_name' 执行失败"
      return 1
    fi
    
    echo "Job '$job_name' 尚未完成，等待${wait_seconds}秒..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
  done
  
  echo "错误: Job '$job_name' 在超时期限内未完成"
  return 1
}

# 检查K8S连接状态
check_k8s_connection() {
  if kubectl cluster-info &> /dev/null; then
    echo "Kubernetes集群连接成功!"
    return 0
  else
    echo "错误: 无法连接到Kubernetes集群"
    return 1
  fi
}

# 获取POD日志
get_pod_logs() {
  local pod_name_pattern=$1
  local namespace=${2:-$(get_current_namespace)}
  local tail_lines=${3:-100}  # 默认获取最后100行
  local container_name=$4     # 可选，如果Pod有多个容器
  
  # 获取Pod名称
  local pod_name=$(get_pod_name "$pod_name_pattern" "$namespace")
  if [ -z "$pod_name" ]; then
    return 1
  fi
  
  local cmd="kubectl logs $pod_name -n $namespace --tail=$tail_lines"
  if [ -n "$container_name" ]; then
    cmd="$cmd -c $container_name"
  fi
  
  eval "$cmd"
}

# 配置Kafka单机部署参数
configure_kafka_single_node() {
  local namespace=${1:-$(get_current_namespace)}
  local config_map="openebs-stack-kafka-controller-configuration"
  
  echo "配置Kafka单机模式参数..."
  
  # 获取当前配置
  local current_config
  current_config=$(kubectl get configmap $config_map -n $namespace -o jsonpath='{.data.server\.properties}' 2>/dev/null)
  
  if [ $? -ne 0 ]; then
    echo "错误: 无法获取Kafka配置ConfigMap '$config_map'" >&2
    return 1
  fi
  
  # 添加单机模式所需参数
  local new_config="$current_config"$'\n'"default.replication.factor=1"$'\n'"min.insync.replicas=1"$'\n'"offsets.topic.replication.factor=1"$'\n'"transaction.state.log.replication.factor=1"$'\n'"transaction.state.log.min.isr=1"$'\n'"auto.create.topics.enable=true"
  
  # 应用新配置
  echo "更新Kafka配置ConfigMap..."
  kubectl create configmap $config_map --from-literal=server.properties="$new_config" -o yaml --dry-run=client | kubectl apply -f - -n $namespace
  
  if [ $? -ne 0 ]; then
    echo "错误: 无法更新Kafka配置ConfigMap" >&2
    return 1
  fi
  
  # 重启Kafka控制器StatefulSet
  echo "重启Kafka控制器..."
  kubectl rollout restart statefulset openebs-stack-kafka-controller -n $namespace
  
  if [ $? -ne 0 ]; then
    echo "错误: 无法重启Kafka控制器StatefulSet" >&2
    return 1
  fi
  
  echo "Kafka单机模式参数配置完成，等待Kafka重启..."
  wait_for_pod_ready "openebs-stack-kafka-controller" "$namespace" 60 5
  
  echo "Kafka单机模式配置完成!"
  return 0
}

# 彩色输出函数 - 与utils.sh相同
print_green() {
  echo -e "\033[0;32m$1\033[0m"
}

print_red() {
  echo -e "\033[0;31m$1\033[0m"
}

print_yellow() {
  echo -e "\033[0;33m$1\033[0m"
}

print_blue() {
  echo -e "\033[0;34m$1\033[0m"
}

# 检查PostgreSQL连接 - K8s版本实现
check_pg_connection() {
  local service_name=${1:-"openebs-stack-postgresql"}
  local port=${2:-5432}
  local user=${3:-"postgres"}
  local password=${4:-"postgres"}
  local database=${5:-"yourdb"}
  local max_attempts=${6:-30}
  local wait_seconds=${7:-5}
  local namespace=${8:-$(get_current_namespace)}
  
  print_blue "检查PostgreSQL连接... (${service_name}:${port})"
  
  # 获取PostgreSQL服务IP
  local pg_service_ip=$(get_service_ip "$service_name" "$namespace")
  if [ $? -ne 0 ]; then
    print_red "错误: 无法获取PostgreSQL服务IP"
    return 1
  fi
  
  # 获取任意一个Pod执行PSQL命令
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    print_blue "尝试 $attempt/$max_attempts: 连接PostgreSQL..."
    
    # 使用kubectl run临时Pod执行psql命令
    if kubectl run pg-test-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$namespace" -- \
      psql "postgresql://${user}:${password}@${service_name}:${port}/${database}" -c "SELECT 1" &> /dev/null; then
      print_green "PostgreSQL连接成功!"
      return 0
    fi
    
    print_yellow "PostgreSQL尚未准备就绪，等待${wait_seconds}秒..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
  done
  
  print_red "错误: PostgreSQL在超时期限内无法连接"
  return 1
}

# 检查HTTP服务健康状态 - K8s版本实现
check_http_service() {
  local service_name=$1
  local port_name=$2  # 可选参数
  local endpoint=${3:-"/"}
  local max_attempts=${4:-30}
  local wait_seconds=${5:-10}
  local namespace=${6:-$(get_current_namespace)}
  
  # 构建服务URL
  local service_url=$(get_service_url "$service_name" "http" "$port_name" "$namespace")
  if [ $? -ne 0 ]; then
    print_red "错误: 无法构建服务URL"
    return 1
  fi
  
  local full_url="${service_url}${endpoint}"
  print_blue "检查${service_name}服务健康状态... (${full_url})"
  
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    print_blue "尝试 $attempt/$max_attempts: 连接${service_name}..."
    
    # 使用kubectl run临时Pod执行curl命令
    if kubectl run curl-test-$RANDOM --rm -i --restart=Never --image=curlimages/curl --namespace="$namespace" -- \
      -s -f "${full_url}" &> /dev/null; then
      print_green "${service_name}服务连接成功!"
      return 0
    fi
    
    print_yellow "${service_name}服务尚未准备就绪，等待${wait_seconds}秒..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
  done
  
  print_red "错误: ${service_name}服务在超时期限内无法连接"
  return 1
}

# 等待表是否存在 - K8s版本实现
wait_for_pg_table() {
  local service_name=${1:-"postgres"}
  local port=${2:-5432}
  local user=${3:-"postgres"}
  local password=${4:-"postgres"}
  local database=${5:-"postgres"}
  local schema=${6:-"public"}
  local table=$7
  local max_attempts=${8:-10}
  local wait_seconds=${9:-3}
  local namespace=${10:-$(get_current_namespace)}
  
  if [ -z "$table" ]; then
    print_red "错误: 未指定表名!"
    return 1
  fi
  
  print_blue "等待表 ${schema}.${table} 创建..."
  
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    print_blue "尝试 $attempt/$max_attempts: 检查表 ${schema}.${table}..."
    
    # 构建PSQL命令
    local psql_cmd="SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = '${schema}' AND table_name = '${table}');"
    
    # 使用kubectl run临时Pod执行psql命令
    local result=$(kubectl run pg-table-check-$RANDOM --rm -i --restart=Never --image=postgres:13 --namespace="$namespace" -- \
      psql "postgresql://${user}:${password}@${service_name}:${port}/${database}" -t -c "$psql_cmd" 2>/dev/null)
    
    if [ $? -eq 0 ] && [[ "$result" == *t* ]]; then
      print_green "表 ${schema}.${table} 存在!"
      return 0
    fi
    
    print_yellow "表 ${schema}.${table} 尚未创建，等待${wait_seconds}秒..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
  done
  
  print_red "错误: 表 ${schema}.${table} 在超时期限内未创建"
  return 1
}

# 执行PostgreSQL SQL语句 - K8s版本实现
execute_pg_sql() {
  local service_name=${1:-"postgres"}
  local port=${2:-5432}
  local user=${3:-"postgres"}
  local password=${4:-"postgres"}
  local database=${5:-"postgres"}
  local sql_statement=$6
  local namespace=${7:-$(get_current_namespace)}
  
  if [ -z "$sql_statement" ]; then
    print_red "错误: 未指定SQL语句!"
    return 1
  fi
  
  print_blue "执行SQL语句..."
  
  # 使用kubectl run临时Pod执行psql命令
  local pod_name="pg-exec-$RANDOM"
  kubectl run $pod_name --rm -i --restart=Never --image=postgres:13 --namespace="$namespace" -- \
    psql "postgresql://${user}:${password}@${service_name}:${port}/${database}" -c "$sql_statement"
  
  local result=$?
  if [ $result -ne 0 ]; then
    print_red "错误: 执行SQL语句失败!"
    return 1
  fi
  
  print_green "SQL语句执行成功!"
  return 0
}

# 执行PostgreSQL脚本文件 - K8s版本实现
execute_pg_script() {
  local service_name=${1:-"postgres"}
  local port=${2:-5432}
  local user=${3:-"postgres"}
  local password=${4:-"postgres"}
  local database=${5:-"postgres"}
  local sql_file=$6
  local namespace=${7:-$(get_current_namespace)}
  
  if [ -z "$sql_file" ]; then
    print_red "错误: 未指定SQL文件!"
    return 1
  fi
  
  if [ ! -f "$sql_file" ]; then
    print_red "错误: SQL文件不存在: $sql_file"
    return 1
  fi
  
  print_blue "执行SQL文件: ${sql_file}"
  
  # 创建临时ConfigMap存储SQL文件
  local cm_name="pg-script-$(date +%s)-$RANDOM"
  kubectl create configmap $cm_name --from-file=script.sql=$sql_file -n $namespace
  
  if [ $? -ne 0 ]; then
    print_red "错误: 无法创建ConfigMap存储SQL文件"
    return 1
  fi
  
  # 创建临时Pod执行SQL脚本
  local pod_manifest=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pg-script-runner
  labels:
    app: pg-script-runner
spec:
  containers:
  - name: pg-client
    image: postgres:13
    command: 
    - /bin/bash
    - -c
    - PGPASSWORD=$password psql -h $service_name -p $port -U $user -d $database -f /scripts/script.sql && echo "SQL执行完成"
    volumeMounts:
    - name: script-volume
      mountPath: /scripts
  volumes:
  - name: script-volume
    configMap:
      name: $cm_name
  restartPolicy: Never
EOF
)
  
  echo "$pod_manifest" | kubectl apply -f - -n $namespace
  
  if [ $? -ne 0 ]; then
    print_red "错误: 无法创建临时Pod执行SQL脚本"
    kubectl delete configmap $cm_name -n $namespace
    return 1
  fi
  
  # 等待Pod完成
  print_blue "等待SQL脚本执行完成..."
  kubectl wait --for=condition=Ready pod/pg-script-runner -n $namespace --timeout=30s
  
  # 获取执行日志
  kubectl logs pg-script-runner -n $namespace
  
  # 清理资源
  kubectl delete pod pg-script-runner -n $namespace
  kubectl delete configmap $cm_name -n $namespace
  
  print_green "SQL脚本执行完成!"
  return 0
}

# 安全获取资源第一个元素函数
safe_get_resource() {
  local resource_type=$1
  local label_selector=$2
  local jsonpath=$3
  local namespace=${4:-$(get_current_namespace)}
  
  # 检查是否有匹配的资源
  local resource_count=$(kubectl get $resource_type -l $label_selector -n $namespace --no-headers 2>/dev/null | wc -l)
  
  if [ "$resource_count" -eq 0 ]; then
    echo "错误: 未找到匹配 '$label_selector' 的 $resource_type 资源" >&2
    return 1
  fi
  
  # 安全获取资源信息
  kubectl get $resource_type -l $label_selector -n $namespace -o jsonpath="$jsonpath" 2>/dev/null
  return $?
}

# 向PostgreSQL表插入测试数据 - K8s版本实现
insert_pg_test_data() {
  local service_name=${1:-"postgres"}
  local port=${2:-5432}
  local user=${3:-"postgres"}
  local password=${4:-"postgres"}
  local database=${5:-"postgres"}
  local table=${6:-"messages"}
  local schema=${7:-"public"}
  local namespace=${8:-$(get_current_namespace)}
  
  print_blue "向 ${schema}.${table} 表插入测试数据..."
  
  # 构建SQL插入语句
  local sql_statement="
  INSERT INTO ${schema}.${table} (id, message, user_id, ts) VALUES
  (1, '这是一条测试消息', 1001, CURRENT_TIMESTAMP - interval '1 hour'),
  (2, '这是另一条测试消息', 1002, CURRENT_TIMESTAMP - interval '30 minutes'),
  (3, '重要通知: 系统维护', 1001, CURRENT_TIMESTAMP - interval '15 minutes'),
  (4, '欢迎使用我们的服务', 1003, CURRENT_TIMESTAMP - interval '5 minutes'),
  (5, '这是最新的消息', 1002, CURRENT_TIMESTAMP);
  "
  
  # 执行SQL语句
  execute_pg_sql "$service_name" "$port" "$user" "$password" "$database" "$sql_statement" "$namespace"
  return $?
} 