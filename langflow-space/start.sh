#!/usr/bin/env bash
# start.sh — HF Spaces / Langflow backend-only, require external API_KEY (STAMP v5)
set -euo pipefail

# ===== Config =====
export PORT_INTERNAL=7870
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_BACKEND_ONLY=True
export LANGFLOW_ENABLE_SUPERUSER_CLI=True

# Superuser（作成のみ。ログインは使わない）
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"

FLOW_JSON_PATH="flows/TestBot_GitHub.json"

echo "===== START.SH STAMP v5 ====="

# ===== Boot (backend-only) =====
langflow run --backend-only --host "${LANGFLOW_HOST}" --port "${PORT_INTERNAL}" &

# ===== Health wait =====
echo "== waiting for Langflow health on :${PORT_INTERNAL} =="
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/health" >/dev/null 2>&1; then
    echo "health OK"; break
  fi
  sleep 1
done

# （冪等）superuser 作成だけは実行（UI操作用の保険）
langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}" >/dev/null 2>&1 || true

BASE="http://127.0.0.1:${PORT_INTERNAL}"

# ===== API_KEY を必須化 =====
if [ -z "${API_KEY:-}" ]; then
  echo "FATAL: API_KEY env not set."
  echo "HINT: Create a Langflow API key via UI or CLI and set API_KEY on HF Space."
  exit 1
fi
LANGFLOW_API_KEY="${API_KEY}"
echo "API key injected (env)."

# ===== Flow import (JSON → 失敗時 multipart) =====
if [ ! -f "${FLOW_JSON_PATH}" ]; then
  echo "ERROR: ${FLOW_JSON_PATH} not found"; exit 1
fi

extract_flow_id () { sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }

do_import_json () {
  curl -sS -L -X POST "${BASE}/api/v1/flows/" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${LANGFLOW_API_KEY}" \
    --data-binary @"${FLOW_JSON_PATH}" | extract_flow_id
}
do_import_upload () {
  curl -sS -L -X POST "${BASE}/api/v1/flows/upload" \
    -H "x-api-key: ${LANGFLOW_API_KEY}" \
    -F "file=@${FLOW_JSON_PATH}" | extract_flow_id
}

FLOW_ID="$(do_import_json)"
[ -z "${FLOW_ID}" ] && FLOW_ID="$(do_import_upload)"

if [ -z "${FLOW_ID}" ]; then
  echo "ERROR: flow import failed."; exit 1
fi

echo "== Auto-import OK: flow id=${FLOW_ID} =="
echo "LANGFLOW_API_KEY=${LANGFLOW_API_KEY}"
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"

# ===== Foreground =====
tail -f /dev/null
