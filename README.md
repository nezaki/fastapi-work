# fastapi-work

FastAPI の最小 API を **Docker イメージ化 → Amazon ECR → ECS (Fargate) + ALB** で公開する、AWS デプロイ学習用プロジェクトです。インフラは **CloudFormation**(IaC)、ビルド/デプロイは **GitHub Actions**(OIDC 認証・長期キー不要)で構成しています。

> アプリ本体は [app/main.py](app/main.py)(公開)と [app/internal_main.py](app/internal_main.py)(内部 / Service Connect)。主眼は「最小アプリを本番志向のパイプラインで ECS に載せる」ことにあります。

## アーキテクチャ

```
   開発者
     │ ① Actions を手動実行 (workflow_dispatch)
     ▼
┌───────────────┐   OIDC AssumeRole(長期キーなし)
│ GitHub Actions │ ──────────────────────────┐
└──────┬────────┘                            │
       │ ② ARM64 でビルド & push             ▼
       │                                 (IAM Role)
       ▼
   ┌───────┐  ③ pull
   │  ECR  │◀───────────────┐
   └───────┘                │
                            │
 Internet ─▶ ALB(:80) ─▶ ECS Service (Fargate / ARM64)
                            └─ Task ─ Container (uvicorn :8000)
                                          └─▶ CloudWatch Logs
```

- **ネットワーク**: VPC + Public サブネット 2AZ。コスト抑制のため **NAT Gateway なし**(タスクは Public サブネット + Public IP で ECR / インターネットへ到達)。
- **ALB**: HTTP:80 を受けて Target Group(`/health` ヘルスチェック)へ転送。
- **ECS**: Fargate / **ARM64**。Circuit Breaker による自動ロールバック有効。
- **ECR**: イメージスキャン有効・`IMMUTABLE`・直近 3 世代のみ保持。
- **CI/CD**: GitHub Actions(手動実行)で ARM64 ビルド → ECR push →(任意で)ECS デプロイ。

## エンドポイント

| メソッド | パス | 用途 |
| --- | --- | --- |
| `GET` | `/` | 動作確認用メッセージを返す |
| `GET` | `/health` | ALB ヘルスチェック用。`{"status": "ok"}` を返す |
| `GET` | `/docs` | Swagger UI(FastAPI 自動生成) |

## ディレクトリ構成

```
.
├── app/
│   ├── main.py                  # 公開サービス(ALB 配下)
│   └── internal_main.py         # 内部サービス(Service Connect 経由のみ)
├── pyproject.toml / uv.lock     # 依存管理(uv)
├── Dockerfile                   # 公開イメージ(ARM64 / 非 root / uv・ダイジェスト固定)
├── Dockerfile.internal          # 内部イメージ
├── .dockerignore
├── deploy/                      # CD(GitHub Actions)が使う ECS タスク定義
│   ├── task-definition.json     # 公開
│   └── internal-task-definition.json # 内部
├── cloudformation/
│   ├── template.yaml            # VPC / ALB / ECS / ECR / IAM 一式
│   ├── github-oidc.yaml         # GitHub Actions 用 OIDC ロール
│   └── README.md                # ★ デプロイ手順の詳細(必読)
├── .github/workflows/
│   └── build-and-push.yml       # ビルド & push & デプロイ(手動実行)
└── .mcp.json                    # Claude Code 用 AWS MCP サーバー定義
```

## ローカル開発

[uv](https://docs.astral.sh/uv/) が必要です(Python 3.14)。

```bash
uv sync                                  # 依存をインストール
uv run uvicorn app.main:app --reload     # http://127.0.0.1:8000
```

- API ドキュメント: http://127.0.0.1:8000/docs
- CloudFormation テンプレートの Lint: `uv run cfn-lint cloudformation/*.yaml`

## Docker

イメージは **ARM64**(Fargate のアーキテクチャと統一)でビルドします。

```bash
docker build --platform linux/arm64 -t fastapi-work .
docker run --rm -p 8000:8000 fastapi-work     # → http://127.0.0.1:8000
```

> Apple Silicon ではネイティブ、Intel Mac / x86 環境ではエミュレーションで動作します。

## AWS へのデプロイ

手順の詳細は **[cloudformation/README.md](cloudformation/README.md)** にまとめています。おおまかな流れは:

1. **CloudFormation スタックを作成**(初回は `DesiredCount=0`。ECR・ALB・ECS などを先に用意)
2. **OIDC 用 IAM ロールを作成**([github-oidc.yaml](cloudformation/github-oidc.yaml))し、ロール ARN を GitHub の Variables `AWS_ROLE_ARN` に登録
3. **GitHub Actions を手動実行**(Actions → Build and Push to ECR → Run workflow)でビルド → push → デプロイ

ECR は `IMMUTABLE` 運用のため、イメージタグは毎回ユニーク(既定で commit SHA)になります。

## 技術スタック

| 領域 | 採用 |
| --- | --- |
| 言語 / FW | Python 3.14 / FastAPI / uvicorn |
| パッケージ管理 | uv |
| コンテナ | Docker(python:3.14-slim / ARM64 / 非 root) |
| IaC | AWS CloudFormation |
| 実行基盤 | ECS Fargate + ALB(ap-northeast-1) |
| CI/CD | GitHub Actions(OIDC) |

## 学習用プロジェクトとしての割り切り

本番運用するなら、以下は意図的に簡略化している点なので別途検討してください。

- **HTTPS 化**: 現状 ALB は HTTP:80 のみ。本番は ACM 証明書 + HTTPS:443 + HTTP→HTTPS リダイレクトを。
- **ネットワーク**: タスクが Public サブネット + Public IP。本番は Private サブネット + NAT Gateway もしくは VPC エンドポイント(ECR / S3 / Logs)を。
- **タスク定義の二重管理**: [cloudformation/template.yaml](cloudformation/template.yaml) と [deploy/task-definition.json](deploy/task-definition.json) の双方にタスク定義がある。どちらを「正」にするか方針を決めること(詳細は [cloudformation/README.md](cloudformation/README.md) の注記)。
