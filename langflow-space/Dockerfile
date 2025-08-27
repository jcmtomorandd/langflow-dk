FROM logspace/langflow:latest

RUN mkdir -p /data/flows /data/logs && chmod -R 777 /data

WORKDIR /data
COPY flows /data/flows
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/bin/bash", "/start.sh"]

# build-bump: 2025-08-27TXX:XXZ
