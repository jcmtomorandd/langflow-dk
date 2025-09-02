FROM logspace/langflow:latest

USER root

# 必要なツールを入れる
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# キャッシュを /data/.cache に移す
ENV XDG_CACHE_HOME=/data/.cache

# 作業ディレクトリ準備
RUN mkdir -p /data/flows /data/logs /data/.cache && chmod -R 777 /data

WORKDIR /data

# flows 配置
COPY flows /data/flows

# kb 配置 ← ここを追加
COPY kb/ /data/kb/

# 起動スクリプト
COPY start.sh /start.sh
RUN sed -i 's/\r$//' /start.sh && chmod +x /start.sh

ENTRYPOINT ["/bin/bash", "/start.sh"]

# build-bump: 2025-08-27T16:45:00Z
