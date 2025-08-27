#!/usr/bin/env bash
set -euo pipefail

PORT_INTERNAL="${PORT:-7860}"

# Langflow 起動
langflow run --host 0.0.0.0 --port "${PORT_INTERNAL}" --log-file /data/logs/langflow.log &

# APIが立ち上がるまで待機
for i in {1..60}; do
  if curl -fsS "http://localhost:${PORT_INTERNAL}/api/v1/health" >/dev/null; then
    break
  fi
  sleep 2
done

# flows をインポート
for f in /data/flows/*.json; do
  echo "Importing $f"
  curl -fsS -X POST -H "accept: application/json" -H "Content-Type: multipart/form-data" \
    -F "file=@${f};type=application/json" \
    "http://localhost:${PORT_INTERNAL}/api/v1/flows/upload/"
done

wait -n
