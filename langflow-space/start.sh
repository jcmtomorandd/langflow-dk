#!/usr/bin/env bash
set -euo pipefail

echo "===== Application Startup at $(date) ====="

# ---- 既存の HF Secrets/Variables のみ利用 ----
# COHERE_API_KEY → Global Variable として適用（緑リンク）
# LANGFLOW_APPLICATION_TOKEN → 認証
# LANGFLOW_AUTO_LOGIN → true

export LANGFLOW_STORE_ENVIRONMENT_VARIABLES=true
export LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT=COHERE_API_KEY
export LANGFLOW_REMOVE_API_KEYS=true

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 ; pwd -P)"

# ---- 永続ディレクトリ ----
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/flows/_patched /data/kb /data/logs

# ---- kb を /data/kb へ同期（langflow-space/kb 優先）----
if [ -d "$SCRIPT_DIR/kb" ]; then
  cp -a "$SCRIPT_DIR/kb/." /data/kb/ || true
elif [ -d "$ROOT_DIR/kb" ]; then
  cp -a "$ROOT_DIR/kb/." /data/kb/ || true
fi

# ---- フローJSONをサニタイズ＆FILEパス補正 ----
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
            # JSON 内のAPIキーは削除（→ 環境変数で供給）
            if kl in {"api_key","cohere_api_key","openai_api_key","huggingfacehub_api_token"}:
                continue
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

# ---- フロー置換インポート ----
langflow import /data/flows/_patched --yes

# ---- Langflow 起動（UIありデモ用）----
exec langflow run --host 0.0.0.0 --port ${PORT:-7860}
