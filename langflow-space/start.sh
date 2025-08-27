#!/usr/bin/env bash
# 安定版 start.sh - HF Space 用
set -u

PORT_INTERNAL="${PORT:-7860}"
LOG_DIR="/data/logs"
FLOWS_DIR="/data/flows"

mkdir -p "$LOG_DIR"

echo "[boot] PORT_INTERNAL=$PORT_INTERNAL"
echo "[boot] listing ${FLOWS_DIR}:"
ls -la "${FLOWS_DIR}" || true

# Langflow 起動（バックグラウンドで）
langflow run --backend-only --host 0.0.0.0 --port "${PORT_INTERNAL}" --log-file "${LOG_DIR}/langflow.log" &
LF_PID=$!

# Langflow が立ち上がるのを待つ（最大 120 秒）
echo "[boot] Waiting for Langflow health..."
for i in {1..60}; do
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "http://localhost:${PORT_INTERNAL}/api/v1/health" >/dev/null; then
      echo "[boot] Langflow is healthy."
      break
    fi
  fi
  sleep 2
done

# 認証ヘッダ（Secrets に LANGFLOW_APPLICATION_TOKEN があれば付与）
AUTH_HEADER=""
if [ -n "${LANGFLOW_APPLICATION_TOKEN:-}" ]; then
  AUTH_HEADER="-H Authorization: Bearer ${LANGFLOW_APPLICATION_TOKEN}"
fi

# flows をインポート
shopt -s nullglob
flow_files=("${FLOWS_DIR}"/*.json)
if (( ${#flow_files[@]} == 0 )); then
  echo "[import] No flow JSONs found in ${FLOWS_DIR}. Skipping import."
else
  for f in "${flow_files[@]}"; do
    echo "[import] Importing ${f}"
    http_code=$(curl -sS -o /tmp/upload_resp.json -w "%{http_code}" \
      -X POST \
      -H "accept: application/json" \
      -H "Content-Type: multipart/form-data" \
      $AUTH_HEADER \
      -F "file=@${f};type=application/json" \
      "http://localhost:${PORT_INTERNAL}/api/v1/flows/upload/" || true)
    echo "[import] Upload HTTP ${http_code} for ${f}"
    cat /tmp/upload_resp.json || true
  done
fi

# Langflow を前面に維持
wait "$LF_PID"
