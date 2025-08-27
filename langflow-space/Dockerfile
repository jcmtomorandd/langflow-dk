# Base image: official Langflow runtime
FROM logspace/langflow:latest

# Persist all caches and logs under /data (writable)
ENV HOME=/data
ENV XDG_CACHE_HOME=/data/.cache
ENV LANGFLOW_CACHE_DIR=/data/.cache/langflow

# Prepare writable dirs
RUN mkdir -p /data/.cache/langflow /data/logs && chmod -R 777 /data

# Make /data the working directory (so "logs/" becomes /data/logs)
WORKDIR /data

# (Optional) Healthcheck against Langflow's health endpoint
# HEALTHCHECK --interval=30s --timeout=10s --retries=5 CMD curl -fsS http://localhost:7860/api/v1/health || exit 1

# 追加（flows フォルダの中身を /data/flows に配置）
COPY flows /data/flows

# Start Langflow on the Hugging Face assigned port (PORT env is provided by HF)
# Also pin the log file path to a writable location to avoid PermissionError
CMD bash -lc "langflow run --host 0.0.0.0 --port ${PORT:-7860} --log-file /data/logs/langflow.log"

# build-bump: 2025-08-27T03:20Z
