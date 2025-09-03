#!/usr/bin/env bash
# start.sh — HF Spaces / Langflow backend-only, robust auto-import (STAMP v4)
set -euo pipefail

# =========================
# Config (edit as needed)
# =========================
export PORT_INTERNAL=7870                 # Langflow listens here
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_BACKEND_ONLY=True
export LANGFLOW_ENABLE_SUPERUSER_CLI=True

# Superuser (change password!)
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"

# Flow JSON path in repo
FLOW_JSON_PATH="flows/TestBot_GitHub.json"

echo "===== START.SH STAMP v4 ====="

# =========================
# Boot Langflow (backend)
# =========================
langflow run --backend-only --host "${LANGFLOW_HOST}" --port "${PORT_INTERNAL}" &

# =========================
# Wait for health
# =========================
echo "== waiting for Langflow health on :${PORT_INTERNAL} =="
HEALTH_OK=0
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/health" >/dev/null 2>&1; then
    echo "health OK"; HEALTH_OK=1; break
  fi
  sleep 1
done
if [ "$HEALTH_OK" -ne 1 ]; then
  echo "ERROR: health check timeout"; exit 1
fi
# small settle time for auth/db
sleep 2

# =========================
# Ensure superuser (idempotent)
# =========================
if langflow superuser --username "${LANGFLOW_SUPERUSER}" --password "${LANGFLOW_SUPERUSER_PASSWORD}" >/dev/null 2>&1; then
  echo "Superuser created."
else
  echo "Superuser ensured."
fi

BASE="http://127.0.0.1:${PORT_INTERNAL}"

# =========================
# Helper: extract JSON field (pure shell)
# =========================
json_extract () {
  # $1: key name
  # reads stdin, tries to extract "key":"value"
  local key="$1"
  sed -n 's/.*"'"$key"'":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# =========================
# Login to get access_token (try endpoints with retry)
# =========================
ACCESS_TOKEN=""
login_try () {
  local EP="$1"
  local RESP STATUS BODY
  RESP="$(curl -sS -L -i -X POST "${BASE}${EP}" \
          -H "Content-Type: application/x-www-form-urlencoded" \
          -H "Accept: application/json" \
          --data "grant_type=password&username=${LANGFLOW_SUPERUSER}&password=${LANGFLOW_SUPERUSER_PASSWORD}" || true)"
  STATUS="$(printf '%s' "$RESP" | awk 'NR==1{print $2}')"
  BODY="$(printf '%s' "$RESP" | awk 'f{print} /^$/{f=1}')"
  ACCESS_TOKEN="$(printf '%s' "$BODY" | json_extract "access_token")"
  if [ "$STATUS" = "200" ] && [ -n "$ACCESS_TOKEN" ]; then
    echo "Got access_token via ${EP}."
    return 0
  else
    echo "[login ${EP}] HTTP ${STATUS} body: $(printf '%s' "$BODY" | head -c 200)"
    return 1
  fi
}

echo "== login =="
for t in $(seq 1 12); do
  echo "Login try ${t}/12"
  if login_try "/api/v1/login" || login_try "/v1/login"; then
    break
  fi
  sleep 2
done
if [ -z "${ACCESS_TOKEN}" ]; then
  echo "ERROR: login failed after retries"; exit 1
fi

# =========================
# API Key — prefer env API_KEY, else create via REST
# =========================
LANGFLOW_API_KEY="${API_KEY:-}"

create_key_try () {
  local EP="$1"
  local RESP KEY
  RESP="$(curl -sS -L -X POST "${BASE}${EP}" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -d '{"name":"hf-space-auto"}' || true)"
  # support api_key / key / token
  KEY="$(printf '%s' "$RESP" | json_extract "api_key")"
  [ -z "$KEY" ] && KEY="$(printf '%s' "$RESP" | json_extract "key")"
  [ -z "$KEY" ] && KEY="$(printf '%s' "$RESP" | json_extract "token")"
  if [ -n "$KEY" ]; then
    LANGFLOW_API_KEY="$KEY"
    echo "API key created via ${EP}."
    return 0
  else
    echo "[api_key ${EP}] resp: $(printf '%s' "$RESP" | head -c 300)"
    return 1
  fi
}

if [ -z "${LANGFLOW_API_KEY}" ]; then
  echo "== create API key =="
  create_key_try "/api/v1/api_key/" || create_key_try "/v1/api_key/" || true
fi

if [ -z "${LANGFLOW_API_KEY}" ]; then
  echo "ERROR: API key creation failed."
  echo "TIP: Issue an API key once in UI and set env 'API_KEY' to use it here."
  exit 1
fi
echo "API key ready."

# =========================
# Flow import — JSON first, fallback to multipart; try both /api/v1 and /v1
# =========================
if [ ! -f "${FLOW_JSON_PATH}" ]; then
  echo "ERROR: ${FLOW_JSON_PATH} not found"; exit 1
fi

extract_flow_id () {
  sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

do_import_json () {
  local EP="$1" RESP
  RESP="$(curl -sS -L -X POST "${BASE}${EP}" \
          -H "accept: application/json" \
          -H "Content-Type: application/json" \
          -H "x-api-key: ${LANGFLOW_API_KEY}" \
          --data-binary @"${FLOW_JSON_PATH}" || true)"
  printf '%s' "$RESP" | extract_flow_id
}

do_import_upload () {
  local EP="$1" RESP
  RESP="$(curl -sS -L -X POST "${BASE}${EP}" \
          -H "x-api-key: ${LANGFLOW_API_KEY}" \
          -F "file=@${FLOW_JSON_PATH}" || true)"
  printf '%s' "$RESP" | extract_flow_id
}

FLOW_ID=""
# JSON endpoints
FLOW_ID="$(do_import_json "/api/v1/flows/")"
[ -z "$FLOW_ID" ] && FLOW_ID="$(do_import_json "/v1/flows/")"
# Fallback: upload
if [ -z "$FLOW_ID" ]; then
  echo "[flows/ JSON] failed, fallback to /flows/upload"
  FLOW_ID="$(do_import_upload "/api/v1/flows/upload")"
  [ -z "$FLOW_ID" ] && FLOW_ID="$(do_import_upload "/v1/flows/upload")"
fi

if [ -z "${FLOW_ID}" ]; then
  echo "ERROR: flow import failed (both JSON & upload)."
  exit 1
fi

echo "== Auto-import OK: flow id=${FLOW_ID} =="
echo "LANGFLOW_API_KEY=${LANGFLOW_API_KEY}"
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"

# =========================
# Keep container foreground
# =========================
tail -f /dev/null
