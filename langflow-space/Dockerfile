FROM logspace/langflow:latest

ENV PORT=7860
EXPOSE 7860

ENV HOME=/data
ENV XDG_CACHE_HOME=/data/.cache
ENV LANGFLOW_CACHE_DIR=/data/.cache/langflow
RUN mkdir -p /data/.cache/langflow && chmod -R 777 /data

CMD bash -lc "langflow run --host 0.0.0.0 --port ${PORT}"
# build-bump: 2025-08-27T01:43Z

