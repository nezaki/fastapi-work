#!/usr/bin/env bash
# 停止/起動スクリプトの共通設定とヘルパー。stop.sh / start.sh / status.sh から source する。
# 直接実行するものではない。
set -euo pipefail

# 環境変数で上書き可能(既定はこのリポジトリの構成に合わせている)
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-fastapi-ecs}"
STACK="${STACK:-$PROJECT}"
CLUSTER="${CLUSTER:-$PROJECT-cluster}"
SERVICE="${SERVICE:-$PROJECT-service}"

# リポジトリ直下を基準に template.yaml の絶対パスを解決する
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_ROOT/cloudformation/template.yaml"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# aws CLI と認証情報の存在を確認する
require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI が見つかりません"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS 認証情報が無効です。aws configure を確認してください"
}

# ECR から push 日時が最新のタグを1つ取得する(タグ無しイメージは除外)
detect_latest_tag() {
  aws ecr describe-images --repository-name "$PROJECT" --region "$AWS_REGION" \
    --query "reverse(sort_by(imageDetails[?imageTags!=null], &imagePushedAt))[0].imageTags[0]" \
    --output text 2>/dev/null
}

# スタックの Enabled パラメータの現在値("true"/"false"/空)を返す
stack_enabled() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$AWS_REGION" \
    --query "Stacks[0].Parameters[?ParameterKey=='Enabled'].ParameterValue | [0]" \
    --output text 2>/dev/null
}
