#!/bin/bash
set -euo pipefail

# ===== ディレクトリ準備 =====
export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/flows /data/logs /data/.cache

# ===== Langflow を内部ポートで無認証起動 =====
export PORT_INTERNAL="${PORT_INTERNAL:-7870}"
export LANGFLOW_DISABLE_AUTH="${LANGFLOW_DISABLE_AUTH:-true}"
langflow run --host 0.0.0.0 --port "${PORT_INTERNAL}" --no-auth &

# ===== APIリレー（外部公開用）を書き出し =====
cat > relay.py <<'PY'
from fastapi import FastAPI, Request
from fastapi.responses import Response, JSONResponse
import httpx, os

app = FastAPI()
BASE = f"http://127.0.0.1:{os.environ.get('PORT_INTERNAL','7870')}"
API_KEY = os.environ.get("API_KEY") or os.environ.get("HF_API_KEY") or ""

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.api_route("/{path:path}", methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS"])
async def proxy(path: str, request: Request):
    url = f"{BASE}/{path}"
    headers = dict(request.headers)
    # 内部LangflowへのAPIキー付与（無認証でも害なし）
    if API_KEY and "x-api-key" not in headers:
        headers["x-api-key"] = API_KEY
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.request(
                request.method,
                url,
                headers=headers,
                content=await request.body(),
                params=dict(request.query_params)
            )
            return Response(
                content=resp.content,
                status_code=resp.status_code,
                media_type=resp.headers.get("content-type")
            )
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=502)
PY

# ===== フローJSONを自動インポート =====
python3 - <<'PY'
import os, time, glob, json, requests

BASE = f"http://127.0.0.1:{os.environ.get('PORT_INTERNAL','7870')}"
KEY  = os.environ.get('API_KEY') or os.environ.get('HF_API_KEY') or ""
HEAD = {"accept":"application/json"}
if KEY:
    HEAD["x-api-key"] = KEY

# Langflow 起動待ち
for _ in range(90):
    try:
        r = requests.get(f"{BASE}/api/v1/health", timeout=3)
        if r.ok:
            print("[auto-import] Langflow internal is up", flush=True)
            break
    except Exception:
        pass
    time.sleep(1)

# 候補パス：/data と リポジトリ直下の flows
patterns = [
    "/data/flows/_patched/*.json",
    "/data/flows/*.json",
    "./flows/_patched/*.json",
    "./flows/*.json",
]
files = []
for p in patterns:
    files.extend(glob.glob(p))
files = sorted(set(files))

if not files:
    print("[auto-import] no flow JSON found under /data/flows or ./flows", flush=True)
else:
    for jf in files:
        try:
            with open(jf, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"[auto-import] skip {jf}: {e}", flush=True)
            continue
        try:
            # 作成API: POST /api/v1/flows/  （複数形＋末尾スラッシュ）
            cr = requests.post(
                f"{BASE}/api/v1/flows/",
                headers={**HEAD, "Content-Type":"application/json"},
                data=json.dumps(data),
                timeout=60
            )
            if cr.ok:
                try:
                    js = cr.json()
                except Exception:
                    js = {}
                fid = js.get("id") or js.get("flow_id")
                print(f"[auto-import] created flow id={fid} from {os.path.basename(jf)}", flush=True)
            else:
                print(f"[auto-import] failed: {cr.status_code} {cr.headers.get('content-type')} {cr.text[:400]}", flush=True)
        except Exception as e:
            print(f"[auto-import] exception: {e}", flush=True)

# 一覧をログ出力（Render の FLOW_ID 設定用）
try:
    lr = requests.get(f"{BASE}/api/v1/flows/", headers=HEAD, timeout=10)
    print("[flows] list status:", lr.status_code, flush=True)
    print("[flows] body:", lr.text[:800], flush=True)
except Exception as e:
    print(f"[flows] list error: {e}", flush=True)
PY

# ===== 外部公開: uvicorn でリレー起動（PORT未設定なら7860） =====
exec uvicorn relay:app --host 0.0.0.0 --port "${PORT:-7860}"
