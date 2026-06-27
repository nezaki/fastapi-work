import os

import boto3
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()

# 内部サービスの呼び先。ECS では Service Connect の DNS エイリアスを使う。
# ローカル検証時は環境変数で http://localhost:8001 などに上書きする。
INTERNAL_SERVICE_URL = os.getenv("INTERNAL_SERVICE_URL", "http://internal-api:8001")

# 送信先 SQS キュー URL。ECS ではタスク定義の環境変数で渡す。
# 未設定(ローカルなど)の場合 /enqueue は 503 を返す。
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")

# boto3 クライアントは region 未設定だと生成時に例外になるため、import 時ではなく
# 初回利用時に遅延生成する(認証/リージョン未設定のローカルでも import を壊さない)。
# 認証情報は ECS のタスクロールから自動取得、リージョンは AWS_REGION から解決する。
_sqs_client = None


def get_sqs_client():
    global _sqs_client
    if _sqs_client is None:
        _sqs_client = boto3.client("sqs")
    return _sqs_client


class EnqueueRequest(BaseModel):
    message: str = "hello from fastapi-ecs"


@app.get("/")
def read_root():
    return {"message": "Hello from fastapi-ecs-practice! verup"}


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/internal")
async def call_internal():
    # Service Connect 経由で内部サービスの /data を呼び、その応答を入れ子で返す。
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(f"{INTERNAL_SERVICE_URL}/data")
        resp.raise_for_status()
        return {
            "via": "service-connect",
            "target": INTERNAL_SERVICE_URL,
            "internal_response": resp.json(),
        }


@app.post("/enqueue")
def enqueue(req: EnqueueRequest):
    # SQS にメッセージを送信する(プロデューサー)。
    # 同期 def にして FastAPI のスレッドプールで実行し、同期 boto3 呼び出しで
    # event loop をブロックしないようにする。受信確認は AWS CLI / コンソールで行う。
    if not SQS_QUEUE_URL:
        raise HTTPException(status_code=503, detail="SQS_QUEUE_URL is not configured")
    resp = get_sqs_client().send_message(QueueUrl=SQS_QUEUE_URL, MessageBody=req.message)
    return {
        "queued": True,
        "message_id": resp["MessageId"],
        "queue_url": SQS_QUEUE_URL,
    }
