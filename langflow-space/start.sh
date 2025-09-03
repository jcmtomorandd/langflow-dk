#!/usr/bin/env bash
set -euo pipefail

# ===== Settings =====
export PORT_INTERNAL=7870
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_BACKEND_ONLY=True
export LANGFLOW_ENABLE_SUPERUSER_CLI=True
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"   # ←強い値に変更
FLOW_JSON_PATH="flows/TestBot_GitHub.json"

# ===== Start Langflow (backend-only) =====
langflow run --backend-only --host "${LANGFLOW_HOST}" --port "${PORT_INTERNAL}" &

# ===== Wait for health (起動安定化) =====
echo "== waiting for Langflow health on :${PORT_INTERNAL} =="
for i in {1..90}; do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/health" >/dev/null; then
    echo "health OK"; break
  fi
  sleep 1
done

# 追加の安定待ち（DBマイグレーション/認証初期化対策）
sleep 2

# ===== Ensure superuser (冪等) =====
if langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}"; then
  echo "Superuser created."
else
  echo "Superuser ensured (maybe already exists)."
fi

# ===== Function: robust JSON field extract (Python) =====
json_get () {
  python - "$1" <<'PY' || true
import sys, json
key = sys.argv[1]
data = sys.stdin.read().strip()
if not data:
    print(""); sys.exit(0)
try:
    j = json.loads(data)
    v = j.get(key,"")
    if isinstance(v, str): print(v)
    else: print("")
except Exception:
    print("")
PY
}

# ===== Function: login (try /api/v1/login then /v1/login) =====
login_and_get_token () {
  local USER="$1" PASS="$2" BASE="http://127.0.0.1:${PORT_INTERNAL}"
  local BODY STATUS R AWK

  for EP in "/api/v1/login" "/v1/login"; do
    echo "Trying login endpoint: ${EP}"
    R="$(curl -sS -L -i -X POST "${BASE}${EP}" \
          -H "Content-Type: application/x-www-form-urlencoded" \
          -H "Accept: application/json" \
          --data "grant_type=password&username=${USER}&password=${PASS}" || true)"
    STATUS="$(printf '%s' "$R" | awk 'NR==1{print $2}')"
    BODY="$(printf '%s' "$R" | awk 'f{print} /^$/{f=1}')"  # ヘッダとボディ分離
    if [ "${STATUS}" = "200" ]; then
      printf '%s' "$BODY" | json_get "access_token"
      return 0
    else
      echo "[login ${EP}] HTTP ${STATUS}"
      echo "[login ${EP}] body: $(printf '%s' "$BODY" | head -c 200)"
    fi
  done
  return 1
}

# ===== (A) Login → access_token 取得（リトライ付） =====
ACCESS_TOKEN=""
for t in {1..10}; do
  ACCESS_TOKEN="$(login_and_get_token "${LANGFLOW_SUPERUSER}" "${LANGFLOW_SUPERUSER_PASSWORD}")" || true
  if [ -n "${ACCESS_TOKEN}" ]; then
    echo "Got access_token." ; break
  fi
  echo "login retry ${t}/10 ..."
  sleep 2
done
if [ -z "${ACCESS_TOKEN}" ]; then
  echo "ERROR: login failed after retries"; exit 1
fi

# ===== (B) API Key 作成（Bearer） =====
API_RESP="$(curl -fsS -L -X POST "http://127.0.0.1:${PORT_INTERNAL}/api/v1/api_key/" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -d '{"name":"hf-space-auto"}' || true)"
LANGFLOW_API_KEY="$(printf '%s' "$API_RESP" | json_get "api_key")"
if [ -z "${LANGFLOW_API_KEY}" ]; then
  # 互換キー名のフォールバック
  LANGFLOW_API_KEY="$(printf '%s' "$API_RESP" | json_get "key")"
fi
if [ -z "${LANGFLOW_API_KEY}" ]; then
  echo "ERROR: API key creation failed. resp=$(printf '%s' "$API_RESP" | head -c 300)"
  exit 1
fi
echo "API key created."

# ===== (C) フロー自動インポート（x-api-key） =====
if [ ! -f "${FLOW_JSON_PATH}" ]; then
  echo "ERROR: ${FLOW_JSON_PATH} not found"; exit 1
fi

CREATE_RESP="$(curl -fsS -L -X POST "http://127.0.0.1:${PORT_INTERNAL}/api/v1/flows/" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${LANGFLOW_API_KEY}" \
  --data-binary @"${FLOW_JSON_PATH}" || true)"

FLOW_ID="$(printf '%s' "$CREATE_RESP" | json_get "id")"
if [ -z "${FLOW_ID}" ]; then
  echo "ERROR: flow import failed. resp=$(printf '%s' "$CREATE_RESP" | head -c 400)"
  exit 1
fi

echo "== Auto-import OK: flow id=${FLOW_ID} =="
echo "LANGFLOW_API_KEY=${LANGFLOW_API_KEY}"
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"

# ===== Keep container foreground =====
tail -f /dev/null
