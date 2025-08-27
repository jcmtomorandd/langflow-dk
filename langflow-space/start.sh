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

# ヘルスチェック（最大120秒）
echo "[boot] waiting health..."
for i in {1..60}; do
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "http://localhost:${PORT_INTERNAL}/health" >/dev/null 2>&1 \
    || curl -fsS "http://localhost:${PORT_INTERNAL}/api/v1/health" >/dev/null 2>&1; then
      echo "[boot] healthy."
      break
    fi
  fi
  sleep 2
done

# ==== 認証情報（デバッグ表示 / 先頭のみ出力）========================
TOK="${LANGFLOW_APPLICATION_TOKEN:-}"
if [ -n "$TOK" ]; then
  echo "[auth] token_len=${#TOK}, head=${TOK:0:6}***"
else
  echo "[auth] token_absent"
fi

# ==== インポート先候補（バージョン差異吸収）==========================
IMPORT_ENDPOINTS=(
  "/api/v1/flows/upload/"
  "/api/v1/flows/import/"
  "/api/v1/flows/upload"
)

# ==== ヘッダ候補（Bearer / x-api-key 両対応）=========================
# 1) Authorization: Bearer <token>
# 2) x-api-key: <token>
make_headers() {
  case "$1" in
    bearer)
      if [ -n "$TOK" ]; then
        echo "-H Authorization: Bearer\ $TOK -H accept: application/json -H Content-Type: multipart/form-data"
      else
        echo "-H accept: application/json -H Content-Type: multipart/form-data"
      fi
      ;;
    xapikey)
      if [ -n "$TOK" ]; then
        echo "-H x-api-key:$TOK -H accept: application/json -H Content-Type: multipart/form-data"
      else
        echo "-H accept: application/json -H Content-Type: multipart/form-data"
      fi
      ;;
  esac
}

AUTH_MODES=(bearer xapikey)

# ==== flows をインポート =============================================
shopt -s nullglob
flow_files=("${FLOWS_DIR}"/*.json)
if (( ${#flow_files[@]} == 0 )); then
  echo "[import] no JSON in ${FLOWS_DIR}, skip."
else
  for f in "${flow_files[@]}"; do
    echo "[import] try import: ${f}"
    imported="no"
    for ep in "${IMPORT_ENDPOINTS[@]}"; do
      for mode in "${AUTH_MODES[@]}"; do
        url="http://localhost:${PORT_INTERNAL}${ep}"
        headers=$(make_headers "$mode")
        echo "[import] POST ${url} (auth=${mode})"
        # shellcheck disable=SC2086
        http_code=$(curl -sS -o /tmp/upload_resp.json -w "%{http_code}" \
          -X POST ${headers} -F "file=@${f};type=application/json" "${url}" || echo "000")
        head=$(head -c 140 /tmp/upload_resp.json 2>/dev/null || true)
        echo "[import] HTTP ${http_code} (auth=${mode}) resp: ${head}"
        if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
          echo "[import] SUCCESS via ${ep} (auth=${mode})"
          imported="yes"
          break 2
        fi
      done
    done
    if [ "${imported}" != "yes" ]; then
      echo "[import] FAILED to import ${f} (all endpoints/auth tried)."
    fi
  done
fi

# 前面維持
wait "$LF_PID"
