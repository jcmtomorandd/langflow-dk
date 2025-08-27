# Base image: official Langflow runtime
FROM logspace/langflow:latest

# Writable locations under /data
ENV HOME=/data
ENV XDG_CACHE_HOME=/data/.cache
ENV LANGFLOW_CACHE_DIR=/data/.cache/langflow

# Prepare caches & logs
RUN mkdir -p /data/.cache/langflow /data/logs && chmod -R 777 /data

# Use /data as working directory
WORKDIR /data

# Copy default flows from repo into Space persistent dir
COPY flows /data/flows

# Startup script to launch Langflow and auto-import flows
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Entrypoint
CMD ["/bin/bash", "/start.sh"]

# build-bump: 2025-08-27T03:50Z
