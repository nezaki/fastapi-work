# syntax=docker/dockerfile:1

# uv を使って依存関係を解決する FastAPI コンテナ
# 再現性のためタグ + ダイジェストで固定(ダイジェストはマルチアーキの index 指定)
FROM python:3.14-slim@sha256:44dd04494ee8f3b538294360e7c4b3acb87c8268e4d0a4828a6500b1eff50061

# uv バイナリを公式イメージからコピー(バージョン + ダイジェスト固定)
COPY --from=ghcr.io/astral-sh/uv:0.11.21@sha256:ff07b86af50d4d9391d9daf4ff89ce427bc544f9aae87057e69a1cc0aa369946 /uv /uvx /bin/

WORKDIR /app

# Python 設定:
#  - 標準出力をバッファリングしない(ログを即座に出す)
#  - パッケージはコピーではなくリンクで配置
#  - uv に Python を別途ダウンロードさせず土台イメージのインタプリタを使う
ENV PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=0

# 依存関係のみ先にインストールしてレイヤーキャッシュを効かせる
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev

# アプリケーションコードを配置してプロジェクト自体をインストール
COPY main.py ./
RUN uv sync --frozen --no-dev

# 仮想環境の実行ファイルへ PATH を通す
ENV PATH="/app/.venv/bin:$PATH"

# 非 root ユーザーを作成して権限を落とす(root 実行を避ける)
RUN useradd --create-home --uid 1000 appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
