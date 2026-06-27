# CLAUDE.md

このファイルは [Claude Code](https://claude.com/claude-code) がこのリポジトリで作業する際のガイドです。

## プロジェクト概要

FastAPI の最小 API を **ECS Fargate + ALB** に載せる学習用プロジェクト。主眼はデプロイ基盤(Docker / CloudFormation / GitHub Actions)にある。リージョンは **ap-northeast-1**、ECS・コンテナは **ARM64** で統一している。

アプリは2つ:
- 公開サービス [app/main.py](app/main.py): ALB 配下。`/internal` で内部サービスを呼ぶ。
- 内部サービス [app/internal_main.py](app/internal_main.py): ALB 非公開。**ECS Service Connect** で `internal-api:8001` として公開し、サービス間通信を実演する。

## よく使うコマンド

```bash
# ローカル起動(2サービス。内部を起動してから公開を起動し呼び先をローカルに向ける)
uv run uvicorn app.internal_main:app --port 8001 &
INTERNAL_SERVICE_URL=http://localhost:8001 uv run uvicorn app.main:app --port 8000
# curl localhost:8000/internal で疎通確認

# 依存の追加 / 同期
uv add <package>
uv sync

# CloudFormation テンプレートの Lint
uv run cfn-lint cloudformation/template.yaml cloudformation/github-oidc.yaml

# Docker ビルド(必ず ARM64。公開 / 内部の2イメージ)
docker build --platform linux/arm64 -f Dockerfile          -t fastapi-work          .
docker build --platform linux/arm64 -f Dockerfile.internal -t fastapi-work-internal .

# 停止 / 起動 / 状態確認(ALB と ECS サービスを Enabled フラグで切替)
./scripts/stop.sh     # ALB と ECS サービスを削除して固定費を止める
./scripts/start.sh    # ALB と ECS サービスを再作成(ECR の最新タグを自動採用)
./scripts/status.sh   # 現在の停止/起動状態を表示(読み取りのみ)
```

デプロイ手順の一次情報は [cloudformation/README.md](cloudformation/README.md)。

## アーキテクチャの要点

- **CloudFormation** [cloudformation/template.yaml](cloudformation/template.yaml): VPC / Public サブネット 2AZ / ALB / ECS(Fargate)/ ECR x2 / IAM / CloudWatch Logs を一括定義。NAT Gateway は使わない。
- **Service Connect**: Cloud Map `HttpNamespace` で公開・内部サービスを接続。内部サービスは `internal-api:8001` で名前解決され、ALB を持たず実質内部限定。公開・内部は別 ECR(`fastapi-ecs` / `fastapi-ecs-internal`)・別タスク定義で、`ImageTag`/`DesiredCount`/`Enabled` を共有する。
- **OIDC** [cloudformation/github-oidc.yaml](cloudformation/github-oidc.yaml): GitHub Actions が長期キーなしで AssumeRole するための最小権限ロール(両 ECR push + 両サービスの ECS デプロイ)。
- **CI/CD** [.github/workflows/build-and-push.yml](.github/workflows/build-and-push.yml): `workflow_dispatch`(手動実行)。ARM64 で公開・内部の2イメージをビルド → ECR push →(`deploy=true` のとき)両サービスへ ECS デプロイ。
- **MCP** [.mcp.json](.mcp.json): AWS 操作用の MCP サーバー(aws-api / aws-documentation / aws-ecs)。既定は変更時に承認要求・読み取り寄りの安全設定。

## コーディング規約

- **コミットメッセージは日本語**で書く。
- Python は uv 管理の venv(Python 3.14)を使用する。
