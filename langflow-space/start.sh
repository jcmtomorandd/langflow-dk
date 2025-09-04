#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
export PORT_INTERNAL="${PORT:-7860}"
export LANGFLOW_HOST="0.0.0.0"
export LANGFLOW_BACKEND_ONLY=True
export LANGFLOW_ENABLE_SUPERUSER_CLI=True
export LANGFLOW_SUPERUSER="admin"
export LANGFLOW_SUPERUSER_PASSWORD="change-this-strong!"
export LANGFLOW_API_KEY="${API_KEY}"

FLOW_JSON_PATH="flows/TestBot_GitHub.json"

echo "===== START.SH STAMP v6.1c (clean FLOW_ID + x-api-key) ====="

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

# ===== 共通ヘッダ（x-api-key） =====
API_H1="x-api-key: ${LANGFLOW_API_KEY}"
API_H2="accept: application/json"
CT_JSON="content-type: application/json"

# JSONから "id" を抽出
extract_id_py='import sys,json,re
s=sys.stdin.read().strip()
try:
    j=json.loads(s)
    if isinstance(j, dict) and "id" in j: 
        print(j["id"]); raise SystemExit
    if isinstance(j, dict) and "flow" in j and isinstance(j["flow"], dict) and "id" in j["flow"]:
        print(j["flow"]["id"]); raise SystemExit
    if isinstance(j, list) and j and isinstance(j[0], dict) and "id" in j[0]:
        print(j[0]["id"]); raise SystemExit
except Exception:
    pass
m=re.search(r"[0-9a-fA-F-]{36}", s)
print(m.group(0) if m else "")'

check_flow() { curl -sS -o /dev/null -w "%{http_code}" -H "${API_H1}" -H "${API_H2}" "${BASE}/api/v1/flows/${1}"; }

import_flow() {
  [ -f "${FLOW_JSON_PATH}" ] || { echo "FATAL: ${FLOW_JSON_PATH} not found." >&2; exit 1; }

  # 1) upload（失敗してもOK。後続でfallback）
  RESP="$(curl -sS -L -X POST "${BASE}/api/v1/flows/upload/" -H "${API_H1}" -H "${API_H2}" -F "file=@${FLOW_JSON_PATH}" || true)"
  NEW_ID="$(printf '%s' "$RESP" | python3 -c "$extract_id_py" || true)"

  # 2) fallback create
  if [ -z "${NEW_ID}" ]; then
    RESP="$(curl -sS -L -X POST "${BASE}/api/v1/flows/" -H "${API_H1}" -H "${API_H2}" -H "${CT_JSON}" --data-binary @"${FLOW_JSON_PATH}")"
    NEW_ID="$(printf '%s' "$RESP" | python3 -c "$extract_id_py" || true)"
  fi

  [ -n "${NEW_ID}" ] || { echo "FATAL: flow import failed. last_response=${RESP:0:400}" >&2; exit 1; }

  if [ "$(check_flow "${NEW_ID}")" != "200" ]; then
    echo "FATAL: flow not reachable after import: id=${NEW_ID}" >&2; exit 1
  fi

  echo "== Auto-import OK: flow id=${NEW_ID} ==" >&2
  printf '%s' "${NEW_ID}"   # ← 標準出力はIDのみ
}

# ===== Reuse or Restore =====
if [ -n "${FLOW_ID:-}" ]; then
  echo "== Candidate Flow ID (env): ${FLOW_ID} =="
  CODE="$(check_flow "${FLOW_ID}")" || CODE="000"
  if [ "${CODE}" = "200" ]; then
    echo "Flow ${FLOW_ID} reachable."
  else
    echo "Flow ${FLOW_ID} not found (HTTP ${CODE}). Re-importing..."
    FLOW_ID="$(import_flow)"; export FLOW_ID
    echo "== Recovered new Flow ID: ${FLOW_ID} =="
  fi
else
  echo "No FLOW_ID provided. Importing..."
  FLOW_ID="$(import_flow)"; export FLOW_ID
fi

# ===== Summary =====
echo "FLOW_ID=${FLOW_ID}"
echo "BASE=https://jcmtomorandd-langflow-dk.hf.space"
echo "READY"
wait -n
