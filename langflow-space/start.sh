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

# ---- 検証: Fileノードの参照ファイルを確認 ----
python3 - <<'PY'
import json, glob, os
print("[verify] scanning patched flows for File node paths...")
def iter_paths(d):
    for k,v in d.items():
        if k.lower() in {"file_path","path"} and isinstance(v,str):
            yield v
        elif k.lower() in {"file_paths","paths"} and isinstance(v,list):
            for x in v:
                if isinstance(x,str): yield x
        elif isinstance(v,dict):
            yield from iter_paths(v)
        elif isinstance(v,list):
            for i in v:
                if isinstance(i,dict): yield from iter_paths(i)

ok=ng=0
for f in glob.glob("/data/flows/_patched/*.json"):
    with open(f,"r",encoding="utf-8") as fp: data=json.load(fp)
    paths=list(iter_paths(data))
    print(f"[verify] {os.path.basename(f)} : {len(paths)} path(s)")
    for p in paths:
        if os.path.exists(p):
            print(f"  [OK] {p} ({os.path.getsize(p)} bytes)")
            ok+=1
        else:
            print(f"  [NG] {p} (not found)")
            ng+=1
print(f"[verify] summary: OK={ok}, NG={ng}")
PY


# ---- kb を /data/kb に同期（サブフォルダごと）----
if [ -d "$SCRIPT_DIR/kb" ]; then
  cp -a "$SCRIPT_DIR/kb/." /data/kb/ || true
elif [ -d "$ROOT_DIR/kb" ]; then
  cp -a "$ROOT_DIR/kb/." /data/kb/ || true
fi

# ---- /data/kb 内容をログ ----
echo "[kb] list:"
find /data/kb -maxdepth 3 -type f -printf " - %p\n" 2>/dev/null || true

# ---- フローJSONを最小補正（サブフォルダ保持・UI表示 files 生成）----
python3 - <<'PY'
import json, os, glob, pathlib, sys
KB="/data/kb"; OUT="/data/flows/_patched"; os.makedirs(OUT, exist_ok=True)
ALLOWED={".pdf",".txt",".md",".csv",".docx",".json",".yaml",".yml",".xlsx"}

# /data/kb を再帰走査して {basename:[フルパス,..]} を作成
kb_index={}
for root, _, files in os.walk(KB):
    for fn in files:
        full=os.path.join(root, fn)
        kb_index.setdefault(fn.lower(), []).append(full)

def resolve_to_kb_path(p:str)->str:
    p=str(p).replace("\\","/")
    if p.startswith(KB + "/") or p==KB:
        return p
    base=os.path.basename(p)
    if base.lower() in kb_index:
        return kb_index[base.lower()][0]
    return os.path.join(KB, base)

def rewrite_paths(v):
    if isinstance(v,str): return resolve_to_kb_path(v)
    if isinstance(v,list): return [rewrite_paths(i) for i in v]
    return v

def make_files_list(paths):
    items=[]
    cand=[paths] if isinstance(paths,str) else (paths if isinstance(paths,list) else [])
    for c in cand:
        p=resolve_to_kb_path(c)
        ext=os.path.splitext(p)[1].lower()
        if os.path.exists(p) and (not ALLOWED or ext in ALLOWED):
            items.append({"name": os.path.basename(p), "path": p})
    return items

def walk(x):
    if isinstance(x,dict):
        y={k:walk(v) for k,v in x.items()}
        # APIキー項目は削除（環境変数で供給）
        for k in list(y.keys()):
            if k.lower() in {"api_key","cohere_api_key","openai_api_key","huggingfacehub_api_token"}:
                y.pop(k,None)
        # パス系キーを実在フルパスへ
        src=None
        for k in list(y.keys()):
            if k.lower() in {"file_paths","paths","file_path","path"}:
                y[k]=rewrite_paths(y[k]); src=y[k]
        # UI用 files を補完
        fk=next((k for k in y if k.lower()=="files"), None)
        gen=make_files_list(src)
        if fk is None:
            if gen: y["files"]=gen
        elif not y.get(fk):
            if gen: y[fk]=gen
        return y
    if isinstance(x,list):
        return [walk(i) for i in x]
    return x

found=False
cands=[os.path.join(os.path.dirname(__file__),"flows"),
       os.path.join(os.path.dirname(os.path.dirname(__file__)),"flows")]
for base in cands:
    for src in glob.glob(os.path.join(base,"*.json")):
        found=True
        with open(src,"r",encoding="utf-8") as f: data=json.load(f)
        data=walk(data)
        dst=os.path.join(OUT, pathlib.Path(src).name)
        with open(dst,"w",encoding="utf-8") as f: json.dump(data,f,ensure_ascii=False,indent=2)
print("Patched flows ready (subfolders kept)." if found else "No flow JSON found.")
PY

# ===== ここからが重要：Langflow を必ず起動し、前面プロセスを維持 =====

# 1) Langflow 起動（バックグラウンド）
langflow run --host 0.0.0.0 --port "$PORT_INTERNAL" &
LF_PID=$!

# 2) ヘルスチェック（APIが立ち上がるまで待つ）
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

# 3) フローを REST API でインポート
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

# 4) フォアグラウンド維持（これが無いと Space が「未初期化」で落ちます）
wait $LF_PID
