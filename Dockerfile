FROM alpine:latest

LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-runner"
LABEL org.opencontainers.image.description="RUNNER (SUPERVISOR)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

# Install required packages: curl, supervisor, docker-cli, logrotate, bash, and cronie (cron daemon)
RUN apk update && apk add --no-cache curl supervisor docker-cli logrotate bash cronie && \
    mkdir -p /var/log/supervisor /etc/supervisor/conf.d /etc/cron.d

# Set PATH environment variable
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH"

# Download configuration and scripts
COPY scripts/supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/logrotate-worker.sh /usr/local/bin/logrotate-worker.sh
COPY scripts/pexe.sh /usr/local/bin/pexe

# Set execute permissions for scripts and adjust file/directory permissions
RUN chmod +x /usr/local/bin/logrotate-worker.sh /usr/local/bin/pexe && \
    chmod 644 /etc/supervisor/supervisord.conf && \
    chmod 775 /var/log/supervisor

CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
