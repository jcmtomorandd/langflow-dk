#!/usr/bin/env bash
set -euo pipefail

# ==== Settings ====
export PORT_INTERNAL=7870
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_ENABLE_SUPERUSER_CLI=True
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"  # ←必ず変更
FLOW_JSON_PATH="flows/TestBot_GitHub.json"

# ==== Start Langflow (backend-only) ====
langflow run --backend-only --host "${LANGFLOW_HOST}" --port "${PORT_INTERNAL}" &

# ==== Wait for health ====
for i in {1..90}; do
  curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/health" >/dev/null && break
  sleep 1
done
echo "health OK"

# ==== Ensure superuser (冪等) ====
langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}" || true
echo "Superuser ensured."

# ==== (A) Login → access_token 取得 ====
ACCESS_TOKEN="$(
  curl -fsS -X POST "http://127.0.0.1:${PORT_INTERNAL}/api/v1/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=password&username=${LANGFLOW_SUPERUSER}&password=${LANGFLOW_SUPERUSER_PASSWORD}" \
  | python - <<'PY'
import sys, json
print(json.load(sys.stdin).get("access_token",""))
PY
)"
if [ -z "${ACCESS_TOKEN}" ]; then
  echo "ERROR: login failed"; exit 1
fi
echo "Got access_token."

# ==== (B) API Key 作成（Authorization: Bearer） ====
LANGFLOW_API_KEY="$(
  curl -fsS -X POST "http://127.0.0.1:${PORT_INTERNAL}/api/v1/api_key/" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d '{"name":"hf-space-auto"}' \
  | python - <<'PY'
import sys, json
j=json.load(sys.stdin)
# レスポンスのどちらかに合わせて抽出（互換）
print(j.get("api_key") or j.get("key") or j.get("token",""))
PY
)"
if [ -z "${LANGFLOW_API_KEY}" ]; then
  echo "ERROR: API key creation failed"; exit 1
fi
echo "API key created."

# ==== (C) フロー自動インポート（x-api-key） ====
if [ ! -f "${FLOW_JSON_PATH}" ]; then
  echo "ERROR: ${FLOW_JSON_PATH} not found"; exit 1
fi

CREATE_RESP="$(
  curl -fsS -X POST "http://127.0.0.1:${PORT_INTERNAL}/api/v1/flows/" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${LANGFLOW_API_KEY}" \
    --data-binary @"${FLOW_JSON_PATH}"
)"
FLOW_ID="$(
  printf '%s' "$CREATE_RESP" | python - <<'PY'
import sys, json, re
s=sys.stdin.read()
try:
    j=json.loads(s); print(j.get("id","")); 
except Exception:
    import re
    m=re.search(r'"id"\s*:\s*"([^"]+)"', s); print(m.group(1) if m else "")
PY
)"
if [ -z "${FLOW_ID}" ]; then
  echo "ERROR: flow import failed"
  echo "$CREATE_RESP"
  exit 1
fi

echo "== Auto-import OK: flow id=${FLOW_ID} =="
echo "LANGFLOW_API_KEY=${LANGFLOW_API_KEY}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"

# ==== 前面維持 ====
tail -f /dev/null
