# CLAUDE.md

このファイルは [Claude Code](https://claude.com/claude-code) がこのリポジトリで作業する際のガイドです。

## プロジェクト概要

FastAPI の最小 API(2 エンドポイント)を **ECS Fargate + ALB** に載せる学習用プロジェクト。アプリ本体は [main.py](main.py) のみで、主眼はデプロイ基盤(Docker / CloudFormation / GitHub Actions)にある。リージョンは **ap-northeast-1**、ECS・コンテナは **ARM64** で統一している。

## よく使うコマンド

```bash
# ローカル起動(ホットリロード)
uv run uvicorn main:app --reload

# 依存の追加 / 同期
uv add <package>
uv sync

# CloudFormation テンプレートの Lint
uv run cfn-lint cloudformation/template.yaml cloudformation/github-oidc.yaml

# Docker ビルド(必ず ARM64)
docker build --platform linux/arm64 -t fastapi-work .
```

デプロイ手順の一次情報は [cloudformation/README.md](cloudformation/README.md)。

## アーキテクチャの要点

- **CloudFormation** [cloudformation/template.yaml](cloudformation/template.yaml): VPC / Public サブネット 2AZ / ALB / ECS(Fargate)/ ECR / IAM / CloudWatch Logs を一括定義。NAT Gateway は使わない。
- **OIDC** [cloudformation/github-oidc.yaml](cloudformation/github-oidc.yaml): GitHub Actions が長期キーなしで AssumeRole するための最小権限ロール(ECR push + ECS デプロイ)。
- **CI/CD** [.github/workflows/build-and-push.yml](.github/workflows/build-and-push.yml): `workflow_dispatch`(手動実行)。ARM64 ビルド → ECR push →(`deploy=true` のとき)ECS デプロイ。
- **MCP** [.mcp.json](.mcp.json): AWS 操作用の MCP サーバー(aws-api / aws-documentation / aws-ecs)。既定は変更時に承認要求・読み取り寄りの安全設定。

## コーディング規約

- **コミットメッセージは日本語**で書く。
- Python は uv 管理の venv(Python 3.14)を使用する。
