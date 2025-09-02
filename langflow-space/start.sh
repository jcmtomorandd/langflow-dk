#!/usr/bin/env bash
set -euo pipefail

echo "===== Application Startup at $(date) ====="

# ---- Secrets/Variables（既存のものだけ使用）----
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

# ---- kb の配置（優先順位: /data/kb → /kb → リポジトリ内の kb）----
# 1) Dockerfile で COPY kb/ /data/kb/ している想定。無ければ /kb やリポジトリから補完。
if [ -d "/kb" ] && [ -z "$(find /data/kb -type f -print -quit 2>/dev/null)" ]; then
  cp -a /kb/. /data/kb/ || true
fi
if [ -d "$SCRIPT_DIR/kb" ] && [ -z "$(find /data/kb -type f -print -quit 2>/dev/null)" ]; then
  cp -a "$SCRIPT_DIR/kb/." /data/kb/ || true
elif [ -d "$ROOT_DIR/kb" ] && [ -z "$(find /data/kb -type f -print -quit 2>/dev/null)" ]; then
  cp -a "$ROOT_DIR/kb/." /data/kb/ || true
fi

# ---- /data/kb と /kb をログ表示（存在確認）----
echo "[kb] list(/data/kb):"
find /data/kb -maxdepth 3 -type f -printf " - %p\n" 2>/dev/null || true
echo "[kb] list(/kb):"
find /kb -maxdepth 3 -type f -printf " - %p\n" 2>/dev/null || true

# ---- フローJSONを補正（Fileノードを必ず /data/kb/** にバインド）----
python3 - <<'PY'
import json, os, glob, pathlib

KB="/data/kb"; OUT="/data/flows/_patched"; os.makedirs(OUT, exist_ok=True)
ALLOWED={".pdf",".txt",".md",".csv",".docx",".json",".yaml",".yml",".xlsx"}

# /data/kb の実ファイル一覧（再帰）とインデックス
kb_files=[]
for r,_,fs in os.walk(KB):
    for fn in fs:
        p=os.path.join(r,fn)
        if os.path.splitext(p)[1].lower() in ALLOWED:
            kb_files.append(p)
kb_index={}
for p in kb_files:
    kb_index.setdefault(os.path.basename(p).lower(), []).append(p)

def resolve_by_basename(s: str):
    if not isinstance(s,str): return s
    s=s.replace("\\","/")
    if s.startswith(KB+"/"): return s
    base=os.path.basename(s)
    cand=kb_index.get(base.lower())
    return cand[0] if cand else s

def force_file_node_bind(obj):
    """
    Fileノードを検出して、必ず /data/kb/** を参照させる。
    - path/paths/file_path/file_paths を basename から実在パスへ解決
    - 参照が無ければ /data/kb 内の先頭数件を自動で files/paths に投入
    - UI 用 'files' も [{name,path}] で埋める
    """
    if isinstance(obj, dict):
        for k,v in list(obj.items()):
            obj[k]=force_file_node_bind(v)

        lower={k.lower():k for k in obj.keys()}
        typ = str(obj.get("type",""))
        disp= str(obj.get("display_name","") or obj.get("name",""))

        is_file_node = (typ.lower()=="file") or ("file" in disp.lower())

        if is_file_node:
            # 既存参照の収集
            paths=[]
            for key in ["file_paths","paths","file_path","path"]:
                if key in lower:
                    val=obj[lower[key]]
                    if isinstance(val,str): paths.append(val)
                    elif isinstance(val,list): paths += [x for x in val if isinstance(x,str)]

            # basename→/data/kb に解決
            mapped=[resolve_by_basename(p) for p in paths]
            mapped=[p for p in mapped if isinstance(p,str) and p]

            # 何も無ければ kb_files を採用（最大5件）
            if not mapped and kb_files:
                mapped = kb_files[:5]

            if mapped:
                # 重複排除
                seen=[]; umap=[]
                for m in mapped:
                    if m not in seen:
                        seen.append(m); umap.append(m)
                # path/paths に反映
                if "paths" in lower:
                    obj[lower["paths"]] = umap
                elif "file_paths" in lower:
                    obj[lower["file_paths"]] = umap
                elif "path" in lower:
                    obj[lower["path"]] = umap[0]
                elif "file_path" in lower:
                    obj[lower["file_path"]] = umap
                else:
                    obj["paths"] = umap
                # UI 用 files
                files_arr=[{"name": os.path.basename(p), "path": p} for p in umap]
                if "files" in lower and not obj.get(lower["files"]):
                    obj[lower["files"]] = files_arr
                elif "files" not in lower:
                    obj["files"] = files_arr

        # APIキー系は削除（環境変数で供給）
        for k in list(obj.keys()):
            if k.lower() in {"api_key","cohere_api_key","openai_api_key","huggingfacehub_api_token"}:
                obj.pop(k, None)
        return obj

    if isinstance(obj, list):
        return [force_file_node_bind(i) for i in obj]
    return obj

found=False
cands=[os.path.join(os.path.dirname(__file__),"flows"),
       os.path.join(os.path.dirname(os.path.dirname(__file__)),"flows")]
for base in cands:
    for src in glob.glob(os.path.join(base,"*.json")):
        found=True
        with open(src,"r",encoding="utf-8") as f: data=json.load(f)
        data=force_file_node_bind(data)
        dst=os.path.join(OUT, pathlib.Path(src).name)
        with open(dst,"w",encoding="utf-8") as f: json.dump(data,f,ensure_ascii=False,indent=2)
print("Patched flows ready (force File->/data/kb)." if found else "No flow JSON found.")
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
        if p and os.path.exists(p):
            print(f"  [OK] {p} ({os.path.getsize(p)} bytes)")
            ok+=1
        else:
            print(f"  [NG] {p if p else '(empty)'} (not found)")
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
