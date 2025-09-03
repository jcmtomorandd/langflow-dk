#!/usr/bin/env bash
set -euo pipefail

echo "===== Application Startup at $(date) ====="

# ---- Env（既存だけ使用）----
export LANGFLOW_STORE_ENVIRONMENT_VARIABLES=true
export LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT=COHERE_API_KEY
export LANGFLOW_REMOVE_API_KEYS=true

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 ; pwd -P)"
PORT_INTERNAL="${PORT:-7860}"

# ---- dirs ----
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/flows/_patched /data/kb /data/logs

# ---- kb sync ----
if [ -d "/kb" ] && [ -z "$(find /data/kb -type f -print -quit 2>/dev/null)" ]; then
  cp -a /kb/. /data/kb/ || true
fi
if [ -d "$SCRIPT_DIR/kb" ] && [ -z "$(find /data/kb -type f -print -quit 2>/dev/null)" ]; then
  cp -a "$SCRIPT_DIR/kb/." /data/kb/ || true
elif [ -d "$ROOT_DIR/kb" ] && [ -z "$(find /data/kb -type f -print -quit 2>/dev/null)" ]; then
  cp -a "$ROOT_DIR/kb/." /data/kb/ || true
fi

echo "[kb] list(/data/kb):"
find /data/kb -maxdepth 3 -type f -printf " - %p\n" 2>/dev/null || true
echo "[kb] list(/kb):"
find /kb -maxdepth 3 -type f -printf " - %p\n" 2>/dev/null || true

# ---- patch flows: Fileノードの実ファイルへ強制バインド（空参照除去）----
python3 - <<'PY'
import json, os, glob, pathlib

KB="/data/kb"; OUT="/data/flows/_patched"; os.makedirs(OUT, exist_ok=True)
ALLOWED={".pdf",".txt",".md",".csv",".docx",".json",".yaml",".yml",".xlsx"}

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
    if not isinstance(s,str): return None
    s=s.strip()
    if not s: return None
    s=s.replace("\\","/")
    if s.startswith(KB+"/"): 
        return s if os.path.exists(s) else None
    base=os.path.basename(s)
    cand=kb_index.get(base.lower())
    return cand[0] if cand and os.path.exists(cand[0]) else None

def force_file_node_bind(obj):
    if isinstance(obj, dict):
        for k,v in list(obj.items()):
            obj[k]=force_file_node_bind(v)
        lower={k.lower():k for k in obj.keys()}
        typ=str(obj.get("type","")); disp=str(obj.get("display_name","") or obj.get("name",""))
        if (typ.lower()=="file") or ("file" in disp.lower()):
            paths=[]
            for key in ["file_paths","paths","file_path","path"]:
                if key in lower:
                    val=obj[lower[key]]
                    if isinstance(val,str) and val.strip(): paths.append(val.strip())
                    elif isinstance(val,list):
                        paths += [x.strip() for x in val if isinstance(x,str) and x.strip()]
            mapped=[]
            for p in paths:
                rp=resolve_by_basename(p)
                if rp and os.path.exists(rp): mapped.append(rp)
            if not mapped and kb_files: mapped=kb_files[:5]
            if mapped:
                # dedup
                seen=set(); umap=[]
                for m in mapped:
                    if m not in seen: seen.add(m); umap.append(m)
                if "paths" in lower: obj[lower["paths"]]=umap
                elif "file_paths" in lower: obj[lower["file_paths"]]=umap
                elif "path" in lower: obj[lower["path"]]=umap[0]
                elif "file_path" in lower: obj[lower["file_path"]]=umap
                else: obj["paths"]=umap
                files_arr=[{"name": os.path.basename(p), "path": p} for p in umap]
                if "files" in lower and not obj.get(lower["files"]): obj[lower["files"]]=files_arr
                elif "files" not in lower: obj["files"]=files_arr
            else:
                for key in ["file_paths","paths","file_path","path","files"]:
                    if key in lower: obj.pop(lower[key], None)
        # APIキー類の直書きを除去
        for k in list(obj.keys()):
            if k.lower() in {"api_key","cohere_api_key","openai_api_key","huggingfacehub_api_token"}:
                obj.pop(k, None)
        return obj
    if isinstance(obj, list):
        return [force_file_node_bind(i) for i in obj]
    return obj

found=False
for base in [os.path.join(os.path.dirname(__file__),"flows"),
             os.path.join(os.path.dirname(os.path.dirname(__file__)),"flows")]:
    for src in glob.glob(os.path.join(base,"*.json")):
        found=True
        with open(src,"r",encoding="utf-8") as f: data=json.load(f)
        data=force_file_node_bind(data)
        dst=os.path.join(OUT, pathlib.Path(src).name)
        with open(dst,"w",encoding="utf-8") as f: json.dump(data,f,ensure_ascii=False,indent=2)
print("Patched flows ready (force File->/data/kb, empty refs removed)." if found else "No flow JSON found.")
PY

# ---- 追加補正: baseClasses をノード/エッジの両方で補完 ----
python3 - <<'PY'
import json, glob, os

DT_DEFAULTS = {
    "cohereembeddings": ["Embeddings"],
    "openaiembeddings": ["Embeddings"],
    "embed": ["Embeddings"],
    "splittext": ["TextSplitter"],
    "textsplitter": ["TextSplitter"],
    "file": ["Document"],
    "document": ["Document"],
    "vectorstore": ["VectorStore"],
    "faiss": ["VectorStore"],
}

def fill_baseclasses_in_obj(d):
    if isinstance(d, dict):
        need = ("baseClasses" not in d) or (not d.get("baseClasses")) or (not isinstance(d.get("baseClasses"), list))
        if need:
            if isinstance(d.get("_types"), list) and d["_types"]:
                d["baseClasses"] = list(d["_types"])
            else:
                dt = str(d.get("dataType","")).lower()
                for key, val in DT_DEFAULTS.items():
                    if key in dt:
                        d["baseClasses"] = list(val)
                        break
        for k,v in list(d.items()):
            d[k] = fill_baseclasses_in_obj(v)
        return d
    if isinstance(d, list):
        return [fill_baseclasses_in_obj(x) for x in d]
    return d

def patch_edge_handles(obj):
    # edges[].data.sourceHandle / targetHandle に baseClasses を付与
    edges = obj.get("edges")
    if not isinstance(edges, list): return obj
    for e in edges:
        data = e.get("data") or {}
        for key in ("sourceHandle","targetHandle"):
            h = data.get(key)
            if isinstance(h, dict):
                bc = h.get("baseClasses")
                if not isinstance(bc, list) or not bc:
                    # 1) output_types があればそれをそのまま使う（最優先）
                    if isinstance(h.get("output_types"), list) and h["output_types"]:
                        h["baseClasses"] = list(h["output_types"])
                    else:
                        # 2) dataType から推定
                        dt = str(h.get("dataType","")).lower()
                        for k,v in DT_DEFAULTS.items():
                            if k in dt:
                                h["baseClasses"] = list(v)
                                break
    return obj

for jf in glob.glob("/data/flows/_patched/*.json"):
    with open(jf,"r",encoding="utf-8") as f:
        obj=json.load(f)
    obj = fill_baseclasses_in_obj(obj)
    obj = patch_edge_handles(obj)
    with open(jf,"w",encoding="utf-8") as f:
        json.dump(obj,f,ensure_ascii=False,indent=2)
print("Patched flows: baseClasses normalized (nodes & edges).")
PY

# ---- verify ----
python3 - <<'PY'
import json, glob, os
print("[verify] scan patched flows ...")

def iter_paths(o):
    if isinstance(o, dict):
        for k,v in o.items():
            kl=k.lower()
            if kl=="files" and isinstance(v,list):
                for it in v:
                    if isinstance(it,dict):
                        p=it.get("path")
                        if isinstance(p,str) and p.strip():
                            yield p.strip()
            if kl in {"file_path","path"} and isinstance(v,str) and v.strip():
                yield v.strip()
            elif kl in {"file_paths","paths"} and isinstance(v,list):
                for i in v:
                    if isinstance(i,str) and i.strip(): 
                        yield i.strip()
            else:
                yield from iter_paths(v)
    elif isinstance(o,list):
        for i in o: 
            yield from iter_paths(i)

ok=ng=0
for jf in glob.glob("/data/flows/_patched/*.json"):
    with open(jf,"r",encoding="utf-8") as f: d=json.load(f)
    paths=list(dict.fromkeys(iter_paths(d)))
    print(f"[verify] {os.path.basename(jf)} : {len(paths)} ref(s)")
    for p in paths:
        if os.path.exists(p):
            print(f"  [OK] {p} ({os.path.getsize(p)} bytes)"); ok+=1
        else:
            print(f"  [NG] {p} (not found)"); ng+=1
print(f"[verify] summary: OK={ok}, NG={ng}")
PY

# ---- Langflow run (API mode) ----
langflow run --host 0.0.0.0 --port "$PORT_INTERNAL" --api &
LF_PID=$!

echo "[boot] waiting for Langflow to be healthy on :$PORT_INTERNAL ..."
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT_INTERNAL}/api/v1/health" >/dev/null 2>&1; then
    echo "[boot] healthy."; break
  fi
  sleep 2
  if [ "$i" -eq 60 ]; then
    echo "[boot] Langflow health check timed out" >&2
    kill $LF_PID || true; exit 1
  fi
done

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
    echo "[import] SUCCESS ($HTTP_CODE)"; IMPORTED=$((IMPORTED+1))
  else
    echo "[import] ERROR ($HTTP_CODE)"; cat /tmp/lf_import_out.txt || true
  fi
done
echo "[import] total imported: $IMPORTED"
wait $LF_PID
