#!/bin/bash
set -e

export XDG_CACHE_HOME=/data/.cache
mkdir -p /data/flows /data/logs /data/.cache

export PORT_INTERNAL=7870
langflow run --host 0.0.0.0 --port $PORT_INTERNAL &

python3 - <<'PY'
import os, time, glob, json, requests
BASE = f"http://127.0.0.1:{os.environ.get('PORT_INTERNAL','7870')}"
KEY  = os.environ.get('API_KEY') or os.environ.get('HF_API_KEY') or ""
HEAD = {"x-api-key": KEY} if KEY else {}

for _ in range(60):
    try:
        r = requests.get(f"{BASE}/api/v1/health", timeout=3)
        if r.ok:
            print("[auto-import] Langflow internal is up")
            break
    except Exception:
        pass
    time.sleep(1)

flows = sorted(glob.glob("/data/flows/*.json"))
if not flows:
    print("[auto-import] no flow JSON found under /data/flows/")
else:
    for jf in flows:
        with open(jf,"r",encoding="utf-8") as f: data=json.load(f)
        try:
            cr = requests.post(f"{BASE}/api/v1/flows",
                               headers={**HEAD, "Content-Type":"application/json"},
                               data=json.dumps(data), timeout=30)
            if cr.ok:
                fid = cr.json().get("id") or cr.json().get("flow_id")
                print(f"[auto-import] created flow id={fid} from {os.path.basename(jf)}")
            else:
                print(f"[auto-import] failed: {cr.status_code} {cr.text[:200]}")
        except Exception as e:
            print(f"[auto-import] exception: {e}")

try:
    lr = requests.get(f"{BASE}/api/v1/flows", headers=HEAD, timeout=10)
    print("[flows] list:", lr.text[:500])
except Exception as e:
    print(f"[flows] list error: {e}")
PY

cat <<'PY' > relay.py
from fastapi import FastAPI, Request
import httpx, os

app = FastAPI()
BASE = f"http://127.0.0.1:{os.environ.get('PORT_INTERNAL','7870')}"
API_KEY = os.environ.get("API_KEY") or os.environ.get("HF_API_KEY") or ""

@app.api_route("/{path:path}", methods=["GET","POST","PUT","DELETE"])
async def proxy(path: str, request: Request):
    url = f"{BASE}/{path}"
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.request(
                request.method,
                url,
                headers={**request.headers, "x-api-key": API_KEY},
                content=await request.body()
            )
            return resp.text
        except Exception as e:
            return {"error": str(e)}
PY

exec uvicorn relay:app --host 0.0.0.0 --port ${PORT:-7860}
