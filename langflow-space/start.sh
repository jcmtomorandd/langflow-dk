#!/usr/bin/env bash
set -euo pipefail

PORT_INTERNAL="${PORT:-7860}"

# 1) Langflow をバックグラウンド起動
langflow run --host 0.0.0.0 --port "${PORT_INTERNAL}" --log-file /data/logs/langflow.log &

# 2) /health が 200 になるまで待機
for i in {1..60}; do
  if curl -fsS "http://localhost:${PORT_INTERNAL}/api/v1/health" >/dev/null; then
    break
  fi
  sleep 2
done

# 3) /data/flows/*.json を一括インポート
shopt -s nullglob
for f in /data/flows/*.json; do
  echo "Importing $f"
  curl -fsS -X POST \
    -H "Content-Type: application/json" \
    --data-binary "@$f" \
    "http://localhost:${PORT_INTERNAL}/api/v1/flows/import" || true
done

# 4) フォアグラウンド化
wait -n
