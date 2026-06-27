import os

import httpx
from fastapi import FastAPI

app = FastAPI()

# 内部サービスの呼び先。ECS では Service Connect の DNS エイリアスを使う。
# ローカル検証時は環境変数で http://localhost:8001 などに上書きする。
INTERNAL_SERVICE_URL = os.getenv("INTERNAL_SERVICE_URL", "http://internal-api:8001")


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
