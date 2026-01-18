FROM alpine:latest
LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-runner"
LABEL org.opencontainers.image.description="RUNNER (SUPERVISOR)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8"

RUN apk add --no-cache \
      bash \
      curl \
      ca-certificates \
      supervisor \
      docker-cli \
      logrotate \
      cronie \
      tzdata \
      figlet \
      ncurses \
      musl-locales \
      gawk \
  && update-ca-certificates \
  && mkdir -p \
      /var/log/supervisor \
      /etc/supervisor/conf.d \
      /etc/cron.d \
      /global/log \
      /global/movelog \
      /global/oldlogs \
      /var/lib/logrotate

COPY scripts/supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/logrotate-worker.sh /usr/local/bin/logrotate-worker.sh
COPY scripts/pexe.sh /usr/local/bin/pexe
COPY scripts/dexe.sh /usr/local/bin/dexe
COPY loggables/ /etc/logrotate.d/

# Required remote downloads (kept). Strongly recommended: pin to commit SHA or verify checksums.
ADD https://raw.githubusercontent.com/infocyph/Scriptomatic/master/bash/banner.sh /usr/local/bin/show-banner
ADD https://raw.githubusercontent.com/infocyph/Toolset/main/ChromaCat/chromacat /usr/local/bin/chromacat

RUN chmod +x \
      /usr/local/bin/logrotate-worker.sh \
      /usr/local/bin/pexe \
      /usr/local/bin/dexe \
      /usr/local/bin/show-banner \
      /usr/local/bin/chromacat \
  && chmod 644 /etc/supervisor/supervisord.conf \
  && chmod 775 /var/log/supervisor /global/oldlogs /var/lib/logrotate \
  && chmod 777 /global/log /global/movelog \
  && mkdir -p /etc/profile.d \
  && { \
      echo '#!/bin/sh'; \
      echo 'case "$-" in *i*) ;; *) exit 0 ;; esac'; \
      echo '[ -z "${BANNER_SHOWN-}" ] || exit 0'; \
      echo 'export BANNER_SHOWN=1'; \
      echo 'command -v show-banner >/dev/null 2>&1 || exit 0'; \
      echo 'show-banner "RUNNER (SUPERVISOR)"'; \
    } > /etc/profile.d/banner-hook.sh \
  && chmod +x /etc/profile.d/banner-hook.sh

# Healthcheck: supervisor must be up and responsive
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD supervisorctl -c /etc/supervisor/supervisord.conf status >/dev/null 2>&1 || exit 1

STOPSIGNAL SIGTERM

CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
