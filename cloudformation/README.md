# FastAPI on ALB + ECS(Fargate)

[template.yaml](template.yaml) は、FastAPI アプリを **ALB + ECS(Fargate)** で公開するための CloudFormation テンプレートです。

## 構成リソース

```
Internet
   │
   ▼
 ALB (HTTP:80, Public Subnet x2)
   │  forward
   ▼
 Target Group (HTTP:8000, target=ip, healthcheck=/health)
   │
   ▼
 ECS Service: 公開 (Fargate)
   └─ Task (uvicorn app.main:app :8000)  ──pull──▶ ECR(公開)
        │  Service Connect (client)
        │  http://internal-api:8001/data
        ▼
 ECS Service: 内部 (Fargate, ALB 非公開)
   └─ Task (uvicorn app.internal_main:app :8001)  ──pull──▶ ECR(内部)
        Service Connect alias = internal-api:8001
```

- **VPC** + **Public サブネット 2AZ**（NAT Gateway なし＝コスト抑制構成）
- **ECR リポジトリ x2**（公開 `fastapi-ecs` / 内部 `fastapi-ecs-internal`。イメージスキャン有効 / 直近3世代のみ保持）
- **ECS クラスター / タスク定義 x2 / サービス x2**（Fargate。公開 + 内部)
- **ALB**（HTTP:80）+ **Target Group**（ヘルスチェック `/health`、公開サービスのみ）
- **Service Connect**（Cloud Map `HttpNamespace`。内部サービスを `internal-api:8001` で名前解決)
- **CloudWatch Logs**（`/ecs/<ProjectName>`。公開は stream `ecs` / 内部は stream `internal`）
- **IAM ロール**（タスク実行ロール / タスクロール。両サービスで共有。タスクロールには SQS 送信権限 `sqs:SendMessage` のみ付与）
- **SQS**（メインキュー `<ProjectName>-queue` + DLQ `<ProjectName>-dlq`。Standard・SSE-SQS 有効・ロングポーリング 20秒・`maxReceiveCount=3` で DLQ へ退避。公開サービスが `POST /enqueue` で送信する。リクエスト課金のみで固定費が無いため停止/起動の対象外＝常設)

> NAT Gateway を使わないため、タスクは Public サブネットに配置し `AssignPublicIp=ENABLED` で ECR / インターネットへ到達します。

## 主なパラメータ

| パラメータ | デフォルト | 説明 |
| --- | --- | --- |
| `ProjectName` | `fastapi-ecs` | リソース名の接頭辞 / ECR リポジトリ名 |
| `ImageTag` | `latest` | タスクが参照する ECR イメージのタグ（公開 / 内部 共通） |
| `ContainerPort` | `8000` | 公開コンテナの待ち受けポート |
| `InternalContainerPort` | `8001` | 内部コンテナの待ち受けポート（Service Connect の公開ポート） |
| `DesiredCount` | `1` | ECS サービスの希望タスク数（公開 / 内部 共通） |
| `TaskCpu` / `TaskMemory` | `256` / `512` | Fargate の CPU / メモリ |

## デプロイ手順

ECR を同テンプレートで作成するため、**初回はイメージが存在せずタスク起動に失敗します**。
これを避けるため、`DesiredCount=0` でスタックを作成 → イメージ push → `DesiredCount` を増やす、の順で進めます。

```bash
# ---- 共通の変数 ----
export AWS_REGION=ap-northeast-1
export PROJECT=fastapi-ecs
export STACK=$PROJECT
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT
export ECR_URI_INTERNAL=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$PROJECT-internal
```

### 1. スタックを 0 タスクで作成（ECR などを先に用意）

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file cloudformation/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName="$PROJECT" DesiredCount=0
```

### 2. イメージをビルドして ECR に push

```bash
# リポジトリの直下(Dockerfile のある場所)で実行
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Fargate(ARM64) 向けにビルド。Colima / Apple Silicon 環境ではネイティブビルド可能。
# 公開イメージと内部イメージを同じタグで push する(start.sh の最新タグ検出と整合させるため)。
docker build --platform linux/arm64 -f Dockerfile          -t "$ECR_URI:latest"          .
docker push "$ECR_URI:latest"
docker build --platform linux/arm64 -f Dockerfile.internal -t "$ECR_URI_INTERNAL:latest" .
docker push "$ECR_URI_INTERNAL:latest"
```

### 3. タスク数を増やして起動

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file cloudformation/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName="$PROJECT" DesiredCount=1
```

### 4. 動作確認

```bash
# エンドポイント URL を取得
URL=$(aws cloudformation describe-stacks --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" --output text)

curl "$URL/"         # {"message":"Hello from fastapi-ecs-practice! verup"}
curl "$URL/health"   # {"status":"ok"}
curl "$URL/internal" # 公開サービスが Service Connect 経由で内部サービスを呼んだ結果
```

## サービス間通信（ECS Service Connect）

公開サービス（`app/main.py`）と、ALB に公開しない内部サービス（`app/internal_main.py`）を **ECS Service Connect** で接続しています。

- 内部サービスは Cloud Map の `HttpNamespace`（`<ProjectName>.internal`）に `internal-api:8001` という DNS エイリアスで登録され、**クラスター内からのみ**到達できます（ALB / Target Group は持たない）。
- 公開サービスは Service Connect の **クライアント**として参加し、`http://internal-api:8001/data` を呼びます。呼び先は環境変数 `INTERNAL_SERVICE_URL` で上書き可能です。
- 疎通確認: `curl "$URL/internal"` で、内部サービスの `/data` 応答（`service: internal` と応答タスクの `hostname`）が入れ子で返れば成功です。
- 確認の補助:
  - `./scripts/status.sh` … 公開 / 内部の両サービスの Running 数を表示。
  - ECS コンソール → 該当サービス → **Service Connect** タブで `internal-api` エイリアスを確認。
  - CloudWatch Logs `/ecs/<ProjectName>` の stream prefix `internal` に内部サービスのログが出る。

> [!NOTE]
> 内部サービスも Public サブネット + `AssignPublicIp=ENABLED` で配置します（NAT なしで ECR から pull するため）。ただし SG は ECS SG 内からの 8001 のみ許可し、外部からの inbound は一切無いため実質内部限定です。
> 公開タスクには Service Connect の Envoy プロキシ（サイドカー）が自動注入されます。OOM が出る場合は `TaskMemory` を `1024` 以上へ引き上げてください。

## SQS へのメッセージ送信（プロデューサー）

公開サービス（`app/main.py`）の `POST /enqueue` が **boto3** で SQS にメッセージを送信します。送信先キュー URL は環境変数 `SQS_QUEUE_URL`（タスク定義で `!Ref AppQueue` を注入）で渡し、認証はタスクロール（`sqs:SendMessage` のみ）で行います。**受信するコンシューマーは用意していない**ため、確認は AWS CLI / コンソールで行います。

```bash
# 送信(ALB 経由)。message は省略可
curl -X POST "$URL/enqueue" -H 'content-type: application/json' -d '{"message":"hello from alb"}'
# => {"queued":true,"message_id":"...","queue_url":"https://sqs.../fastapi-ecs-queue"}

# キュー URL を取得
QURL=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AppQueueUrl'].OutputValue" --output text)

# 受信確認(実行者自身の認証情報で。ロングポーリング 20秒)
aws sqs receive-message --region "$AWS_REGION" --queue-url "$QURL" --wait-time-seconds 20
```

- **DLQ**: 受信したまま削除せず可視性タイムアウト（30秒）を `maxReceiveCount`（3）回超えたメッセージは `<ProjectName>-dlq` に移送されます。挙動を観察したいときは `receive-message` を削除せず繰り返してください。
- **常設**: SQS はリクエスト課金のみで固定費が無いため `stop.sh`（`Enabled=false`）でも残ります。停止中でもキュー自体は存在します。
- **ローカル**: `SQS_QUEUE_URL`（+ AWS 認証情報 / `AWS_REGION`）を渡さない場合、`POST /enqueue` は `503` を返します。

## アプリ更新時（2回目以降）

ECR は `IMMUTABLE` 運用のため、**同じタグの上書き push はできません**。毎回ユニークなタグ（例: commit SHA）を使います。

```bash
# Fargate(ARM64) 向けにビルド。
export TAG=$(git rev-parse --short HEAD)
docker build --platform linux/arm64 -t "$ECR_URI:$TAG" .
docker push "$ECR_URI:$TAG"

# 新しいタグを参照させて再デプロイ
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file cloudformation/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName="$PROJECT" ImageTag="$TAG" DesiredCount=1
```

> 通常はこの手動手順ではなく GitHub Actions（後述）で更新します。CD は稼働中のタスク定義を取得して `image` だけ差し替えるため、タグや `ImageTag` を意識する必要はありません。

## コスト削減: 停止と起動

使わない時間帯はリソースを止めて費用を抑えられます。アイドル時の固定費は **Fargate タスクより ALB の方が大きい**ため、停止スクリプトは **ALB と ECS サービスの両方**を削除します。

| リソース | 課金 | 停止後 |
| --- | --- | --- |
| ALB | 起動中ずっと固定課金(月 ~$16〜20 + LCU) | 削除され停止 |
| Fargate タスク | 稼働時間課金 | `DesiredCount=0` で削除され停止 |
| VPC / ECR / IAM / クラスター / ログ / タスク定義 | 無料〜僅少 | 残す(再開を速くするため) |

仕組み: [template.yaml](template.yaml) の `Enabled` パラメータ(Condition `IsEnabled`)で、ALB / TargetGroup / Listener / ECS サービスの作成有無を切り替えます。CLI で直接削除せず **CloudFormation に作成/削除させる**ため、スタックのドリフトは発生しません。

```bash
# 停止(ALB と ECS サービスを削除して固定費を止める)
./scripts/stop.sh

# 起動(ALB と ECS サービスを再作成。ECR の最新タグを自動採用)
./scripts/start.sh
# タグを明示する場合: ./scripts/start.sh <commit-sha>

# 現在の状態を確認(読み取りのみ)
./scripts/status.sh
```

> [!IMPORTANT]
> - **再開のたびに ALB を作り直すため、エンドポイントの DNS 名が変わります。** 固定したい場合は別途 Route 53 などで名前を当ててください。
> - ECR は `IMMUTABLE` 運用で `latest` タグが無いため、`start.sh` は ECR の最新イメージタグを自動検出して `ImageTag` に渡します(イメージが1つも無いと失敗します)。
> - **停止中(`Enabled=false`)は ECS サービスが存在しない**ため、GitHub Actions の `deploy=true` は失敗します。停止中にイメージだけ更新したい場合は `deploy=false` で push し、再開後に最新タグで `start.sh` してください。
> - スクリプトは region=`ap-northeast-1` / project=`fastapi-ecs` を既定とします。異なる場合は環境変数 `AWS_REGION` / `PROJECT` で上書きできます。

## 後片付け

```bash
# ECR はイメージが残っていると削除に失敗するため先に空にする(公開 / 内部の両方)
for repo in "$PROJECT" "$PROJECT-internal"; do
  aws ecr batch-delete-image --region "$AWS_REGION" --repository-name "$repo" \
    --image-ids "$(aws ecr list-images --region "$AWS_REGION" --repository-name "$repo" --query 'imageIds[*]' --output json)" || true
done

aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$STACK"
```

> ECR リポジトリ(公開 / 内部)は `DeletionPolicy: Retain` のためスタック削除後も残ります。不要なら手動で削除してください。
> （`aws ecr delete-repository --repository-name "$PROJECT" --force --region "$AWS_REGION"` / 同様に `"$PROJECT-internal"`）

---

# GitHub Actions による ECR への push

[../.github/workflows/build-and-push.yml](../.github/workflows/build-and-push.yml) は、**手動実行**で Docker イメージをビルドし ECR へ push するワークフローです。AWS への認証は **OIDC**（長期アクセスキー不要）で行い、[github-oidc.yaml](github-oidc.yaml) が作成する IAM ロールを AssumeRole します。

## 1. OIDC 用 IAM ロールを作成

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$PROJECT-github-oidc" \
  --template-file cloudformation/github-oidc.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName="$PROJECT" \
    GitHubOrg="<github-org-or-user>" \
    GitHubRepo="<github-repo>"
```

> アカウントに既に GitHub の OIDC プロバイダ（`token.actions.githubusercontent.com`）がある場合は、
> `CreateOidcProvider=false ExistingOidcProviderArn=<既存ARN>` を追加してください
> （無いと `EntityAlreadyExists` で失敗します）。
> 既定では **main ブランチのみ** AssumeRole を許可します。全 ref へ広げたい場合は `GitHubRefPattern="*"` を指定します（デプロイ権限を持つロールのため、広げる際は影響を理解した上で）。

作成したロールの ARN を取得します。

```bash
aws cloudformation describe-stacks --region "$AWS_REGION" \
  --stack-name "$PROJECT-github-oidc" \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubActionsRoleArn'].OutputValue" --output text
```

## 2. GitHub リポジトリに変数を設定

リポジトリの **Settings → Secrets and variables → Actions → Variables** に以下を登録します。

| 名前 | 値 |
| --- | --- |
| `AWS_ROLE_ARN` | 手順1で取得したロール ARN |

> リージョンや ECR リポジトリ名を変えている場合は、[../.github/workflows/build-and-push.yml](../.github/workflows/build-and-push.yml) の `env`（`AWS_REGION` / `ECR_REPOSITORY`）も合わせて変更してください。

## 3. ワークフローを手動実行

GitHub の **Actions → Build and Push to ECR → Run workflow** から実行します。

| 入力 | 既定 | 説明 |
| --- | --- | --- |
| `image_tag` | （空） | 付与するタグ。空なら commit SHA を使用。ECR は IMMUTABLE のため毎回ユニークにすること |
| `deploy` | `true` | push 後に ECS へデプロイするか。`false` で push のみ |

`deploy=true` の場合、push に続けて以下を自動で行います（[../deploy/task-definition.json](../deploy/task-definition.json) / [../deploy/internal-task-definition.json](../deploy/internal-task-definition.json) を使用）。

1. 各タスク定義の `${AWS_ACCOUNT_ID}` / `${AWS_REGION}` を実値に展開
2. `image` を今 push したイメージ URI（commit SHA タグ）に差し替え
3. 新しいタスク定義リビジョンを登録し、**公開・内部の両 ECS サービス**を更新（安定するまで待機）

> 公開・内部の両イメージは同じタグで push されます。内部タスク定義の `portMappings` には Service Connect が要求する名前付きポート（`"name": "internal"` / `"appProtocol": "http"`）が含まれており、これを欠くと再デプロイ時に Service Connect 設定が壊れるため削除しないでください。

> 初回はサービス（`fastapi-ecs-service`）が存在している必要があります。先に [このREADME上部](#1-スタックを-0-タスクで作成ecr-などを先に用意)の CloudFormation スタックを作成してください。
> push のみ行いたい場合は `deploy=false`、または `aws ecs update-service --force-new-deployment` で手動反映もできます。

## CD 用タスク定義（deploy/task-definition.json）と CloudFormation の関係

`deploy/` 配下の [../deploy/task-definition.json](../deploy/task-definition.json) は、CD（GitHub Actions）が `aws-actions/amazon-ecs-render-task-definition` / `amazon-ecs-deploy-task-definition` で使うタスク定義です。内容は [template.yaml](template.yaml) の `TaskDefinition` と揃えてあります。

> [!IMPORTANT]
> **同じタスク定義を CloudFormation と CD の2か所で管理することになります。**
> CD が新リビジョンを登録してサービスを更新したあとに `aws cloudformation deploy` を再実行すると、CloudFormation はサービスを **自身がインライン定義する `TaskDefinition`（＝CD で上げた変更を含まない）** に戻し、ドリフトが発生します。
>
> 運用方針の例:
> - **CD をタスク定義の正にする**: `template.yaml` から `TaskDefinition` とサービスの `LoadBalancers`/`TaskDefinition` 参照を外し、CFn はネットワーク・ALB・ECR・IAM・クラスターまで、タスク定義とサービスの更新は CD が担う（推奨）。
> - **CFn をタスク定義の正にする**: アプリ更新も `ImageTag` を変えて `aws cloudformation deploy` で行い、CD は push のみ（`deploy=false`）にする。
> - CPU/メモリ・ポート・ログ設定などを変えるときは、両ファイルを揃えておくと取り違えを防げます。

> [!NOTE]
> ECS デプロイ権限は OIDC ロールに追加済みです（`ecs:RegisterTaskDefinition` / `ecs:UpdateService` / 対象2ロールへの `iam:PassRole` など）。
> **既に github-oidc スタックを作成済みの場合は、手順1の `aws cloudformation deploy` を再実行して権限を反映してください。**

---

# MCP で AWS を操作する

リポジトリ直下の [../.mcp.json](../.mcp.json) に、AWS 公式（awslabs）の MCP サーバーを3つ定義しています。Claude Code から AWS の状態確認・操作・ドキュメント参照を直接行えます。

| サーバー | パッケージ | 用途 | 書き込み |
| --- | --- | --- | --- |
| `aws-api` | `awslabs.aws-api-mcp-server` | AWS CLI 経由で AWS 全般を操作 | 可（変更前に承認を要求） |
| `aws-documentation` | `awslabs.aws-documentation-mcp-server` | 最新の AWS ドキュメント参照 | 不可（認証不要） |
| `aws-ecs` | `awslabs-ecs-mcp-server` | ECS のデプロイ・運用・障害調査 | 既定は読み取りのみ |

## 前提

- `uvx`（uv）がインストール済みであること（各サーバーは `uvx` で起動します）。
- AWS 認証情報が設定済みであること。既定では **`default` プロファイル / `ap-northeast-1`** を使用します。

```bash
aws configure   # default プロファイルに認証情報を設定
```

> プロファイル名やリージョンが異なる場合は [../.mcp.json](../.mcp.json) の `env`
> （`AWS_API_MCP_PROFILE_NAME` / `AWS_PROFILE` / `AWS_REGION`）を各自の環境に合わせて変更してください。

## 有効化

Claude Code を再読込すると `.mcp.json` が読み込まれます。`/mcp` で各サーバーの接続状態を確認し、初回はプロジェクト MCP サーバーの利用を承認してください。

## 安全設定（既定値）

操作の安全性を優先した既定にしています。必要に応じて [../.mcp.json](../.mcp.json) の `env` を変更してください。

- `aws-api`: `REQUIRE_MUTATION_CONSENT=true`（変更系操作の前に承認を要求）。完全に読み取り専用にするなら `READ_OPERATIONS_ONLY=true`。
- `aws-ecs`: `ALLOW_WRITE=false`（読み取りのみ） / `ALLOW_SENSITIVE_DATA=false`。デプロイ等の変更を許可するなら `ALLOW_WRITE=true` にします。
- `aws-documentation`: 認証不要・読み取り専用のため変更の心配はありません。
