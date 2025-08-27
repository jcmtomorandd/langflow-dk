#!/bin/bash

echo "===== Application Startup at $(date) ====="

# 環境変数設定
export PORT_INTERNAL=${PORT:-7860}
export LANGFLOW_HOST=0.0.0.0
export LANGFLOW_PORT=$PORT_INTERNAL
export LANGFLOW_AUTO_LOGIN=true

echo "[boot] PORT_INTERNAL=$PORT_INTERNAL"

# flowsディレクトリ確認
ls -la /data/flows/
echo "[cfg] AUTO_LOGIN=True"

echo "[boot] waiting health..."

# Langflow起動（バックグラウンド）
langflow run --host 0.0.0.0 --port $PORT_INTERNAL &

# 起動待ち
sleep 15

echo "[boot] healthy."

# フロー自動インポート（修正版）
if [ -f "/data/flows/TestBot_GitHub.json" ]; then
    echo "[import] importing TestBot_GitHub.json..."
    sleep 10
    
    # Python経由で直接インポート
    python3 -c "
import json
import requests
import time
import os

# ファイル読み込み
with open('/data/flows/TestBot_GitHub.json', 'r') as f:
    flow_data = json.load(f)

# Langflow APIにPOST
try:
    url = 'http://localhost:$PORT_INTERNAL/api/v1/flows/upload'
    
    # multipart/form-data形式でアップロード
    files = {'file': ('TestBot_GitHub.json', json.dumps(flow_data), 'application/json')}
    
    response = requests.post(url, files=files, timeout=30)
    
    if response.status_code == 200:
        print('[import] SUCCESS: Flow imported')
    else:
        print(f'[import] ERROR: {response.status_code} - {response.text}')
        
except Exception as e:
    print(f'[import] EXCEPTION: {e}')
"
else
    echo "[import] No flow files found"
fi

# フォアグラウンドでプロセス維持
wait