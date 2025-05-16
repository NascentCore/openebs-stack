#!/bin/bash
set -x

# 修改为你的私有仓库地址
REGISTRY=sxwl-registry.cn-beijing.cr.aliyuncs.com
PROJECT=sxwl-ai

# 登录（可选）
# docker login $REGISTRY

# 构建 Kafka Connect 镜像（含 Debezium）
docker buildx build --platform linux/amd64 -t $REGISTRY/$PROJECT/kafka-connect-debezium:latest -f Dockerfile.kafka-connect .

# 推送镜像
docker push $REGISTRY/$PROJECT/kafka-connect-debezium:latest

echo "✅ 镜像已成功推送到私有仓库：$REGISTRY/$PROJECT/kafka-connect-debezium:latest"
