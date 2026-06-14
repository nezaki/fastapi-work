#!/usr/bin/env bash
# 課金リソース(ALB / TargetGroup / Listener / ECS サービス)を削除して固定費を停止する。
# Enabled=false で CloudFormation に削除させるため、ドリフトは発生しない。
# ネットワーク / ECR / IAM / クラスター / ログ / タスク定義は残す。再開は start.sh。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/common.sh
source ./common.sh

require_aws

current="$(stack_enabled || true)"
if [ "$current" = "false" ]; then
  log "すでに停止済みです (Enabled=false)。処理をスキップします。"
  exit 0
fi

log "停止します: ALB / TargetGroup / Listener / ECS サービスを削除します。"
warn "ALB を作り直すため、再開後はエンドポイントの DNS 名が変わります。"

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides Enabled=false DesiredCount=0 \
  --no-fail-on-empty-changeset

log "停止が完了しました。残る課金は ECR / ログ(いずれも僅少)のみです。"
log "再開するには: scripts/start.sh"
