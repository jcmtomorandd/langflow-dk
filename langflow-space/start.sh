#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
export PORT_INTERNAL="${PORT:-7860}"
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_BACKEND_ONLY=True
export LANGFLOW_ENABLE_SUPERUSER_CLI=True
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"

FLOW_JSON_PATH="flows/TestBot_GitHub.json"

echo "===== START.SH STAMP v6.2 (auth-fixed, flows/upload) ====="

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

# Superuser（冪等）
langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}" >/dev/null 2>&1 || true

BASE="http://127.0.0.1:${PORT_INTERNAL}"

# ===== Create Langflow API Key (sk-...) via CLI =====
# backend-only では UI で作れないため CLI 必須
LF_API_KEY="$(langflow api-key 2>/dev/null | grep -o 'sk-[A-Za-z0-9._-]*' | head -n1 || true)"
if [ -z "${LF_API_KEY}" ]; then
  echo "FATAL: failed to create Langflow API key (sk-...) via CLI."
  exit 1
fi
echo "LANGFLOW_API_KEY=${LF_API_KEY}"   # ← ログに出す（Render から使用）

# 共通ヘッダ（x-api-key）
API_H1="x-api-key: ${LF_API_KEY}"
API_H2="accept: application/json"
CT_JSON="content-type: application/json"

# ===== Flow import / reuse =====
if [ -n "${FLOW_ID:-}" ]; then
  echo "== Reusing existing Flow ID: ${FLOW_ID} =="
else
  if [ ! -f "${FLOW_JSON_PATH}" ]; then
    echo "FATAL: ${FLOW_JSON_PATH} not found."
    exit 1
  fi

  # JSONから "id" を厳密抽出
  extract_id_py='import sys,json; print(json.load(sys.stdin).get("id",""))'

  # 1) /api/v1/flows/upload/ で登録（存在確認済みの公式エンドポイント）
  RESP="$(curl -sS -L -X POST "${BASE}/api/v1/flows/upload/" \
           -H "${API_H1}" -H "${API_H2}" \
           -F "file=@${FLOW_JSON_PATH}")"
  FLOW_ID="$(printf '%s' "$RESP" | python3 -c "$extract_id_py" || true)"

  # 2) 取得できない場合のフォールバック：/api/v1/flows/（作成）
  if [ -z "${FLOW_ID}" ]; then
    RESP="$(curl -sS -L -X POST "${BASE}/api/v1/flows/" \
             -H "${API_H1}" -H "${API_H2}" -H "${CT_JSON}" \
             --data-binary @"${FLOW_JSON_PATH}")"
    FLOW_ID="$(printf '%s' "$RESP" | python3 -c "$extract_id_py" || true)"
  fi

  if [ -z "${FLOW_ID}" ]; then
    echo "FATAL: flow import failed. last_response=${RESP:0:400}"
    exit 1
  fi
  echo "== Auto-import OK: flow id=${FLOW_ID} =="

  # 登録確認（200ならOK）
  curl -fsS -H "${API_H1}" -H "${API_H2}" "${BASE}/api/v1/flows/${FLOW_ID}" >/dev/null
  echo "Flow ${FLOW_ID} reachable."
fi

# ===== Summary =====
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"
echo "READY"
wait -n
