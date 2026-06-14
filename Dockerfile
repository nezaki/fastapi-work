# syntax=docker/dockerfile:1

# ===== Builder: 依存解決と .venv 構築(uv はこのステージだけで使う) =====
# 再現性のためタグ + ダイジェストで固定(ダイジェストはマルチアーキの index 指定)
FROM python:3.14-slim@sha256:44dd04494ee8f3b538294360e7c4b3acb87c8268e4d0a4828a6500b1eff50061 AS builder

# uv バイナリを公式イメージからコピー(バージョン + ダイジェスト固定)
COPY --from=ghcr.io/astral-sh/uv:0.11.21@sha256:ff07b86af50d4d9391d9daf4ff89ce427bc544f9aae87057e69a1cc0aa369946 /uv /uvx /bin/

# Python 設定:
#  - パッケージはリンクではなくコピーで配置(ステージ間コピーで壊れないように)
#  - bytecode を事前コンパイルして起動を速くする
#  - uv に Python を別途ダウンロードさせず土台イメージのインタプリタを使う
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

# 依存関係のみ先にインストールしてレイヤーキャッシュを効かせる。
# uv キャッシュはマウントで持ち、最終イメージには残さない。
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# アプリケーションコードを配置してプロジェクト自体をインストール
COPY main.py ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# ===== Runtime: .venv だけを持つ最小実行イメージ(uv は同梱しない) =====
FROM python:3.14-slim@sha256:44dd04494ee8f3b538294360e7c4b3acb87c8268e4d0a4828a6500b1eff50061 AS runtime

# Python 設定:
#  - 標準出力をバッファリングしない(ログを即座に出す)
#  - bytecode は builder で生成済みのため実行時には書き込ませない(read-only FS 対応)
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

# 非 root ユーザーを先に作成し、所有者付きコピーで .venv 複製と root 所有を回避
RUN useradd --create-home --uid 1000 appuser
WORKDIR /app

# builder から venv とコードを所有者を付けてコピー
COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --chown=appuser:appuser main.py ./

USER appuser

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
