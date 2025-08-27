#!/usr/bin/env bash
set -u

PORT_INTERNAL="${PORT:-7860}"
LOG_DIR="/data/logs"
FLOWS_DIR="/data/flows"

mkdir -p "$LOG_DIR"

echo "[boot] PORT_INTERNAL=$PORT_INTERNAL"
ls -la "$FLOWS_DIR" || true

# Langflow 起動（APIのみ）
langflow run --backend-only --host 0.0.0.0 --port "${PORT_INTERNAL}" --log-file "${LOG_DIR}/langflow.log" &
LF_PID=$!

# ヘルスチェック待機（最大120秒）
echo "[boot] waiting health..."
for i in {1..60}; do
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "http://localhost:${PORT_INTERNAL}/api/v1/health" >/dev/null 2>&1 \
    || curl -fsS "http://localhost:${PORT_INTERNAL}/health" >/dev/null 2>&1; then
      echo "[boot] healthy."
      break
    fi
  fi
  sleep 2
done

# 認証ヘッダ
AUTH_HEADER=""
if [ -n "${LANGFLOW_APPLICATION_TOKEN:-}" ]; then
  AUTH_HEADER="-H Authorization: Bearer ${LANGFLOW_APPLICATION_TOKEN}"
fi

# インポート先候補（バージョン差異を吸収）
IMPORT_ENDPOINTS=(
  "/api/v1/flows/upload/"
  "/api/v1/flows/import/"
  "/api/v1/flows/upload"
)

shopt -s nullglob
flow_files=("${FLOWS_DIR}"/*.json)
if (( ${#flow_files[@]} == 0 )); then
  echo "[import] no JSON in ${FLOWS_DIR}, skip."
else
  for f in "${flow_files[@]}"; do
    echo "[import] try import: ${f}"
    imported="no"
    for ep in "${IMPORT_ENDPOINTS[@]}"; do
      url="http://localhost:${PORT_INTERNAL}${ep}"
      echo "[import] POST ${url}"
      http_code=$(curl -sS -o /tmp/upload_resp.json -w "%{http_code}" \
        -X POST \
        -H "accept: application/json" \
        -H "Content-Type: multipart/form-data" \
        $AUTH_HEADER \
        -F "file=@${f};type=application/json" \
        "${url}" || echo "000")
      echo "[import] HTTP ${http_code} on ${ep}"
      head=$(head -c 200 /tmp/upload_resp.json 2>/dev/null || true)
      echo "[import] resp: ${head}"
      if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
        echo "[import] SUCCESS via ${ep}"
        imported="yes"
        break
      elif [ "${http_code}" = "401" ] || [ "${http_code}" = "403" ]; then
        echo "[import] AUTH required. Check LANGFLOW_APPLICATION_TOKEN."
        # 認証エラーなら他エンドポイントに変えても意味が薄いが一応続行
      fi
      # 404 は次のエンドポイントを試す
    done
    if [ "${imported}" != "yes" ]; then
      echo "[import] FAILED to import ${f} (all endpoints tried)."
    fi
  done
fi

# 前面維持
wait "$LF_PID"
