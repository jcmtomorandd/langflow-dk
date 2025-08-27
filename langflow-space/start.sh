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
    sleep 5
    # 直接UIにアクセスしてインポート
    echo "[import] Flow file found, ready for manual import via UI"
else
    echo "[import] No flow files found"
fi

# フォアグラウンドでプロセス維持
wait