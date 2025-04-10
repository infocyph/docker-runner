FROM alpine:latest
LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-runner"
LABEL org.opencontainers.image.description="RUNNER (SUPERVISOR)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"
RUN apk update && apk add --no-cache curl supervisor docker-cli logrotate bash cronie && \
    mkdir -p /var/log/supervisor /etc/supervisor/conf.d /etc/cron.d /global/log
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH"
COPY scripts/supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/logrotate-worker.sh /usr/local/bin/logrotate-worker.sh
COPY scripts/pexe.sh /usr/local/bin/pexe
COPY scripts/dexe.sh /usr/local/bin/dexe
COPY loggables/ /etc/logrotate.d/
RUN chmod +x /usr/local/bin/logrotate-worker.sh /usr/local/bin/pexe /usr/local/bin/dexe && \
    chmod 644 /etc/supervisor/supervisord.conf && \
    chmod 775 /var/log/supervisor && \
    chmod 777 /global/log
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
