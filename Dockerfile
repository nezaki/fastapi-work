# syntax=docker/dockerfile:1

# uv を使って依存関係を解決する FastAPI コンテナ
FROM python:3.14-slim

# uv バイナリを公式イメージからコピー
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Python 設定:
#  - 標準出力をバッファリングしない(ログを即座に出す)
#  - パッケージはコピーではなくリンクで配置
ENV PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

# 依存関係のみ先にインストールしてレイヤーキャッシュを効かせる
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev

# アプリケーションコードを配置してプロジェクト自体をインストール
COPY main.py ./
RUN uv sync --frozen --no-dev

# 仮想環境の実行ファイルへ PATH を通す
ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
