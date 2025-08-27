# Base Langflow image
FROM logspace/langflow:latest

# Writable dirs
ENV HOME=/data
ENV XDG_CACHE_HOME=/data/.cache
ENV LANGFLOW_CACHE_DIR=/data/.cache/langflow

# ✅ ここがポイント：起動時に /data/flows の JSON を自動読み込み
ENV LANGFLOW_LOAD_FLOWS_PATH=/data/flows
ENV LANGFLOW_AUTO_LOGIN=true

# prepare dirs
RUN mkdir -p /data/.cache/langflow /data/logs && chmod -R 777 /data

WORKDIR /data

# GitHub の flows/ を Space 永続領域へ
COPY flows /data/flows

# Langflow を起動（ログは /data/logs へ）
CMD ["bash","-lc","langflow run --host 0.0.0.0 --port ${PORT:-7860} --log-file /data/logs/langflow.log"]

# build-bump: 2025-08-27T04:40Z
