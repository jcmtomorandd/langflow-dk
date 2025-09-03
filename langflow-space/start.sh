#!/usr/bin/env bash
set -euo pipefail

# ===== Settings =====
export PORT_INTERNAL=7870
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_ENABLE_SUPERUSER_CLI=True

# Superuser（管理用）
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"

# HF が期待する公開ポート
export PORT="${PORT:-7860}"   # HF側が使う env（触らない）
# Langflow は 7870 で起動し、HF の 7860 へは自前で何もバインドしない

# ===== Start Langflow (backend-only) =====
# 明示ポート指定（既定7860を避け、7870で待受）
langflow run --backend-only --host "${LANGFLOW_HOST}" --port "${PORT_INTERNAL}" &

# ===== Wait for health =====
echo "== waiting for Langflow health on :${PORT_INTERNAL} =="
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/health" >/dev/null; then
    echo "health OK"; break
  fi
  sleep 1
done

# ===== Ensure superuser (idempotent) =====
# 既に存在しても失敗しない想定で実行
langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}" || true

# ===== Create API Key via CLI =====
# 出力から sk-... を抽出
API_KEY_RAW="$(langflow api-key || true)"
LANGFLOW_API_KEY="$(printf '%s\n' "$API_KEY_RAW" | grep -oE 'sk-[A-Za-z0-9._-]+' | head -n1)"

if [ -z "${LANGFLOW_API_KEY:-}" ]; then
  echo "ERROR: API key creation failed"; exit 1
fi
echo "API key created."

# ===== Auto-import flow JSON =====
FLOW_JSON_PATH="flows/TestBot_GitHub.json"
if [ ! -f "$FLOW_JSON_PATH" ]; then
  echo "ERROR: ${FLOW_JSON_PATH} not found"; exit 1
fi

# POST /api/v1/flows/ （JSONボディ）— 要 x-api-key
CREATE_RESP="$(curl -fsS -X POST \
  "http://127.0.0.1:${PORT_INTERNAL}/api/v1/flows/" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${LANGFLOW_API_KEY}" \
  --data-binary @"${FLOW_JSON_PATH}")"

FLOW_ID="$(printf '%s\n' "$CREATE_RESP" | grep -oE '"id"\s*:\s*"[^"]+"' | head -n1 | cut -d':' -f2 | tr -d ' "')" || true

if [ -z "${FLOW_ID:-}" ]; then
  echo "ERROR: flow import failed"
  echo "$CREATE_RESP"
  exit 1
fi

echo "== Auto-import OK: flow id=${FLOW_ID} =="

# ===== Friendly logs =====
echo "LANGFLOW_API_KEY=${LANGFLOW_API_KEY}"
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"

# ===== Keep container foreground =====
# Langflowはすでにバックグラウンドで起動済み。前面でポート7860のダミー健康チェックを流すだけ。
python - <<'PY'
import time, http.client
while True:
    try:
        conn = http.client.HTTPConnection("127.0.0.1", 7870, timeout=2)
        conn.request("GET", "/health")
        conn.getresponse().read()
    except Exception:
        pass
    time.sleep(5)
PY
