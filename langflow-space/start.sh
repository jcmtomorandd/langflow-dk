#!/usr/bin/env bash
# start.sh — HF Spaces / Langflow backend-only, require external API_KEY (STAMP v5.1)
# 特徴:
#  - /login を一切使わない（空ボディ問題を根絶）
#  - API_KEY を必須（UIまたはCLIで一度発行して環境変数に設定）
#  - 失敗時も exit しない（Runtime Errorループ回避）。理由を出して前面で待機。

set -uo pipefail   # ← -e は外す（失敗時でもプロセス継続）

# ===== Config =====
export PORT_INTERNAL=7870
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_BACKEND_ONLY=True
export LANGFLOW_ENABLE_SUPERUSER_CLI=True

# Superuser（UI操作用の保険。ログイン用途では使用しない）
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"

FLOW_JSON_PATH="flows/TestBot_GitHub.json"

echo "===== START.SH STAMP v5.1 ====="

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

# Superuser 作成（冪等）。失敗しても無視。
langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}" >/dev/null 2>&1 || true

BASE="http://127.0.0.1:${PORT_INTERNAL}"

# ===== API_KEY 必須（無ければ待機に入る） =====
if [ -z "${API_KEY:-}" ]; then
  echo "FATAL: API_KEY env not set."
  echo "HINT: Langflow UI (Settings → API Keys) でキーを発行し、HF Space の環境変数に API_KEY=sk-... を設定してください。"
  echo "Keeping process alive to avoid runtime error. Waiting..."
  tail -f /dev/null
fi
LANGFLOW_API_KEY="${API_KEY}"
echo "API key injected (env)."

# ===== Flow import helpers =====
extract_flow_id () { sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }

do_import_json () {
  curl -sS -L -X POST "${BASE}/api/v1/flows/" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${LANGFLOW_API_KEY}" \
    --data-binary @"${FLOW_JSON_PATH}" 2>/dev/null | extract_flow_id
}
do_import_upload () {
  curl -sS -L -X POST "${BASE}/api/v1/flows/upload" \
    -H "x-api-key: ${LANGFLOW_API_KEY}" \
    -F "file=@${FLOW_JSON_PATH}" 2>/dev/null | extract_flow_id
}

# ===== Flow import =====
if [ ! -f "${FLOW_JSON_PATH}" ]; then
  echo "FATAL: ${FLOW_JSON_PATH} not found. Keeping process alive."
  tail -f /dev/null
fi

FLOW_ID="$(do_import_json)"
[ -z "${FLOW_ID}" ] && FLOW_ID="$(do_import_upload)"

if [ -z "${FLOW_ID}" ]; then
  echo "FATAL: flow import failed (JSON & upload both)."
  echo "Check: API_KEY 正しいか / flows JSON の内容が壊れていないか。Keeping process alive."
  tail -f /dev/null
fi

echo "== Auto-import OK: flow id=${FLOW_ID} =="
echo "LANGFLOW_API_KEY=${LANGFLOW_API_KEY}"
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"

# ===== Foreground =====
tail -f /dev/null
