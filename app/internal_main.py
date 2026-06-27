import socket

from fastapi import FastAPI

# 内部通信専用サービス。ALB には公開せず、ECS Service Connect 経由
# (DNS エイリアス internal-api:8001)でのみ到達できる。
app = FastAPI()


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/data")
def get_data():
    # どのタスクが応答したか分かるよう hostname を含める(Service Connect の疎通確認用)
    return {
        "service": "internal",
        "message": "Hello from internal service via Service Connect",
        "hostname": socket.gethostname(),
    }
