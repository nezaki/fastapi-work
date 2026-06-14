#!/usr/bin/env bash
# ALB と ECS サービスを再作成してサービスを起動する。
# 使い方: ./start.sh [image_tag]
#   image_tag を省略すると ECR の最新(push 日時が新しい)タグを自動採用する。
# ECR は IMMUTABLE 運用で latest タグが存在しないため、有効なタグの明示が必須。
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/common.sh
source ./common.sh

require_aws

TAG="${1:-}"
if [ -z "$TAG" ]; then
  log "ECR から最新イメージタグを検出します..."
  TAG="$(detect_latest_tag || true)"
fi
if [ -z "$TAG" ] || [ "$TAG" = "None" ]; then
  die "イメージタグを特定できませんでした。先にイメージを push するか、引数で指定してください: ./start.sh <tag>"
fi
log "使用するイメージタグ: $TAG"

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides Enabled=true DesiredCount=1 ImageTag="$TAG" \
  --no-fail-on-empty-changeset

URL="$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue | [0]" --output text)"
log "起動が完了しました。エンドポイント: $URL"
log "確認: curl $URL/health"
