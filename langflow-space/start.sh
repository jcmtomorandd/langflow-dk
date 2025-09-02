#!/usr/bin/env bash
set -euo pipefail

echo "===== Application Startup at $(date) ====="

# ---- Secrets/Variables （既存のものだけ使用）----
# COHERE_API_KEY / LANGFLOW_APPLICATION_TOKEN / LANGFLOW_AUTO_LOGIN
export LANGFLOW_STORE_ENVIRONMENT_VARIABLES=true
export LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT=COHERE_API_KEY
export LANGFLOW_REMOVE_API_KEYS=true

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 ; pwd -P)"
PORT_INTERNAL="${PORT:-7860}"

# ---- 永続領域 ----
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/flows/_patched /data/kb /data/logs

# ---- kb を /data/kb に同期（サブフォルダごと）----
if [ -d "$SCRIPT_DIR/kb" ]; then
  cp -a "$SCRIPT_DIR/kb/." /data/kb/ || true
elif [ -d "$ROOT_DIR/kb" ]; then
  cp -a "$ROOT_DIR/kb/." /data/kb/ || true
fi

# ---- /data/kb 内容をログ ----
echo "[kb] list:"
find /data/kb -maxdepth 3 -type f -printf " - %p\n" 2>/dev/null || true

# ---- フローJSONを補正（サブフォルダ保持・basenameで/data/kbにマッピング）----
python3 - <<'PY'
import json, os, glob, pathlib

KB="/data/kb"; OUT="/data/flows/_patched"; os.makedirs(OUT, exist_ok=True)
ALLOWED={".pdf",".txt",".md",".csv",".docx",".json",".yaml",".yml",".xlsx"}

# /data/kb の再帰インデックス {basename: [fullpaths...]}
kb_index={}
for root, _, files in os.walk(KB):
    for fn in files:
        full=os.path.join(root, fn)
        kb_index.setdefault(fn.lower(), []).append(full)

def resolve_by_basename(s: str):
    if not isinstance(s, str):
        return s
    if s.startswith(KB + "/"):
        return s
    base=os.path.basename(s.replace("\\","/"))
    if base.lower() in kb_index:
        return kb_index[base.lower()][0]
    return s

def rewrite_any(value):
    if isinstance(value, dict):
        out={}
        for k,v in value.items():
            kl=k.lower()
            nv=rewrite_any(v)
            # files フィールド（UI用）
            if kl=="files" and isinstance(nv, list):
                arr=[]
                for it in nv:
                    if isinstance(it, dict) and "path" in it:
                        it["path"]=resolve_by_basename(it["path"])
                    arr.append(it)
                out[k]=arr
                continue
            # パス系
            if kl in {"file_path","file_paths","path","paths"}:
                if isinstance(nv, str):
                    nv=resolve_by_basename(nv)
                elif isinstance(nv, list):
                    nv=[resolve_by_basename(x) if isinstance(x,str) else x for x in nv]
            out[k]=nv
        return out
    if isinstance(value, list):
        return [rewrite_any(i) for i in value]
    if isinstance(value, str):
        return resolve_by_basename(value)
    return value

found=False
for src in glob.glob(os.path.join(os.path.dirname(__file__),"flows","*.json")) + \
           glob.glob(os.path.join(os.path.dirname(os.path.dirname(__file__)),"flows","*.json")):
    found=True
    with open(src,"r",encoding="utf-8") as f: data=json.load(f)
    data=rewrite_any(data)
    dst=os.path.join(OUT, pathlib.Path(src).name)
    with open(dst,"w",encoding="utf-8") as f: json.dump(data,f,ensure_ascii=False,indent=2)

print("Patched flows ready (aggressive mapping)." if found else "No flow JSON found.")
PY

# ---- verify: 補正済みJSONをスキャンして実体確認 ----
python3 - <<'PY'
import json, glob, os
print("[verify] scan patched flows ...")

def iter_paths(o):
    if isinstance(o, dict):
        for k,v in o.items():
            kl=k.lower()
            if kl=="files" and isinstance(v,list):
                for it in v:
                    if isinstance(it,dict) and isinstance(it.get("path"),str):
                        yield it["path"]
            if kl in {"file_path","path"} and isinstance(v,str):
                yield v
            elif kl in {"file_paths","paths"} and isinstance(v,list):
                for i in v:
                    if isinstance(i,str): yield i
            else:
                yield from iter_paths(v)
    elif isinstance(o,list):
        for i in o: yield from iter_paths(i)

ok=ng=0
for jf in glob.glob("/data/flows/_patched/*.json"):
    with open(jf,"r",encoding="utf-8") as f: d=json.load(f)
    paths=list(dict.fromkeys(iter_paths(d)))
    print(f"[verify] {os.path.basename(jf)} : {len(paths)} ref(s)")
    for p in paths:
        if os.path.exists(p):
            print(f"  [OK] {p} ({os.path.getsize(p)} bytes)")
            ok+=1
        else:
            print(f"  [NG] {p} (not found)")
            ng+=1
print(f"[verify] summary: OK={ok}, NG={ng}")
PY

# ---- Langflow 起動 ----
langflow run --host 0.0.0.0 --port "$PORT_INTERNAL" &
LF_PID=$!

# ---- ヘルスチェック ----
echo "[boot] waiting for Langflow to be healthy on :$PORT_INTERNAL ..."
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/api/v1/health" >/dev/null 2>&1; then
    echo "[boot] healthy."
    break
  fi
  sleep 2
  if [ "$i" -eq 60 ]; then
    echo "[boot] Langflow health check timed out" >&2
    kill $LF_PID || true
    exit 1
  fi
done

# ---- フローを REST API でインポート ----
API_URL="http://127.0.0.1:${PORT_INTERNAL}/api/v1/flows/"
AUTH_HDR=()
if [ -n "${LANGFLOW_APPLICATION_TOKEN:-}" ]; then
  AUTH_HDR=(-H "x-api-key: ${LANGFLOW_APPLICATION_TOKEN}")
  echo "[auth] Using x-api-key (masked): ${LANGFLOW_APPLICATION_TOKEN:0:6}***"
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
wait $LF_PID

