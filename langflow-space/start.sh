#!/usr/bin/env bash
set -euo pipefail

echo "===== Application Startup at $(date) ====="

# ---- 既存の HF Secrets/Variables のみ利用 ----
# COHERE_API_KEY … ノード側で Global Variable（緑リンク）として利用
# LANGFLOW_APPLICATION_TOKEN … API 認証に使用（x-api-key）
# LANGFLOW_AUTO_LOGIN … そのまま尊重
export LANGFLOW_STORE_ENVIRONMENT_VARIABLES=true
export LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT=COHERE_API_KEY
export LANGFLOW_REMOVE_API_KEYS=true

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 ; pwd -P)"
PORT_INTERNAL="${PORT:-7860}"

# ---- 永続領域 ----
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/flows/_patched /data/kb /data/logs

# ---- kb を /data/kb へ同期（langflow-space/kb 優先）----
if [ -d "$SCRIPT_DIR/kb" ]; then
  cp -a "$SCRIPT_DIR/kb/." /data/kb/ || true
elif [ -d "$ROOT_DIR/kb" ]; then
  cp -a "$ROOT_DIR/kb/." /data/kb/ || true
fi

# ---- フローJSONをサニタイズ＆FILEパス補正（APIキー項目の削除含む）----
python3 - <<'PY'
import json, os, glob, pathlib, sys
KB="/data/kb"; OUT="/data/flows/_patched"; os.makedirs(OUT, exist_ok=True)
cands=[os.path.join(os.path.dirname(__file__),"flows"),
       os.path.join(os.path.dirname(os.path.dirname(__file__)),"flows")]

def rewrite_path(v):
    if isinstance(v,str):
        bn=os.path.basename(v.replace("\\","/"))
        return os.path.join(KB,bn) if bn else v
    if isinstance(v,list): return [rewrite_path(i) for i in v]
    return v

def walk(x):
    if isinstance(x,dict):
        y={}
        for k,v in x.items():
            kl=k.lower()
            # JSON 内の API キー項目は削除（環境変数→Global Variable を使う）
            if kl in {"api_key","cohere_api_key","openai_api_key","huggingfacehub_api_token"}:
                continue
            # ファイル系パスは /data/kb へ付け替え
            if kl in {"file_path","file_paths","path","paths"}:
                v=rewrite_path(v)
            y[k]=walk(v)
        return y
    if isinstance(x,list): return [walk(i) for i in x]
    return x

found=False
for base in cands:
    for src in glob.glob(os.path.join(base,"*.json")):
        found=True
        with open(src,"r",encoding="utf-8") as f: data=json.load(f)
        data=walk(data)
        dst=os.path.join(OUT, pathlib.Path(src).name)
        with open(dst,"w",encoding="utf-8") as f: json.dump(data,f,ensure_ascii=False,indent=2)
if not found:
    print("No flow JSON found.", file=sys.stderr)
else:
    print("Patched flows ready.")
PY

# ---- Langflow 起動（バックグラウンド）----
langflow run --host 0.0.0.0 --port "$PORT_INTERNAL" &

# ---- ヘルスチェック待機 ----
echo "[boot] waiting for Langflow to be healthy on :$PORT_INTERNAL ..."
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/api/v1/health" >/dev/null 2>&1; then
    echo "[boot] healthy."
    break
  fi
  sleep 2
  if [ "$i" -eq 60 ]; then
    echo "[boot] Langflow health check timed out" >&2
    exit 1
  fi
done

# ---- REST API でフローを置換インポート ----
API_URL="http://127.0.0.1:${PORT_INTERNAL}/api/v1/flows/"
AUTH_HDR=()
if [ -n "${LANGFLOW_APPLICATION_TOKEN:-}" ]; then
  AUTH_HDR=(-H "x-api-key: ${LANGFLOW_APPLICATION_TOKEN}")
  echo "[auth] Using x-api-key (masked): ${LANGFLOW_APPLICATION_TOKEN:0:6}***"
else
  echo "[auth] LANGFLOW_APPLICATION_TOKEN not set; trying without auth header"
fi

shopt -s nullglob
IMPORTED=0
for f in /data/flows/_patched/*.json; do
  echo "[import] $f"
  HTTP_CODE=$(curl -sS -o /tmp/lf_import_out.txt -w "%{http_code}" \
    -X POST "$API_URL" "${AUTH_HDR[@]}" \
    -H "Content-Type: application/json" \
    --data-binary @"$f" || true)
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "[import] SUCCESS ($HTTP_CODE)"
    IMPORTED=$((IMPORTED+1))
  else
    echo "[import] ERROR ($HTTP_CODE)"
    cat /tmp/lf_import_out.txt || true
  fi
done
echo "[import] total imported: $IMPORTED"

# ---- フォアグラウンド維持 ----
wait
