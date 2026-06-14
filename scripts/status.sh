#!/usr/bin/env bash
# 現在の停止/起動状態と主要リソースを表示する(読み取りのみ)。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/common.sh
source ./common.sh

require_aws

enabled="$(stack_enabled || echo '不明')"
log "Enabled パラメータ: $enabled  (true=起動 / false=停止)"

echo "--- ECS サービス ---"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$AWS_REGION" \
  --query "services[?status=='ACTIVE'].{Status:status,Desired:desiredCount,Running:runningCount,TaskDef:taskDefinition}" \
  --output table 2>/dev/null || true

echo "--- ALB ---"
aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?LoadBalancerName=='${PROJECT}-alb'].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}" \
  --output table 2>/dev/null || true
