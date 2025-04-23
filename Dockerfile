FROM alpine:latest
LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-runner"
LABEL org.opencontainers.image.description="RUNNER (SUPERVISOR)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"
RUN apk update && \
    apk add --no-cache curl supervisor docker-cli logrotate bash cronie tzdata figlet ncurses musl-locales gawk && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/* && \
    mkdir -p /var/log/supervisor /etc/supervisor/conf.d /etc/cron.d /global/log /global/movelog /global/oldlogs
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/games:$PATH"
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8
COPY scripts/supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/logrotate-worker.sh /usr/local/bin/logrotate-worker.sh
COPY scripts/pexe.sh /usr/local/bin/pexe
COPY scripts/dexe.sh /usr/local/bin/dexe
COPY loggables/ /etc/logrotate.d/
ADD https://raw.githubusercontent.com/infocyph/Scriptomatic/master/bash/banner.sh /usr/local/bin/show-banner
ADD https://raw.githubusercontent.com/infocyph/Toolset/main/ChromaCat/chromacat /usr/local/bin/chromacat
RUN chmod +x /usr/local/bin/logrotate-worker.sh /usr/local/bin/pexe /usr/local/bin/dexe /usr/local/bin/show-banner /usr/local/bin/chromacat && \
    chmod 644 /etc/supervisor/supervisord.conf && \
    chmod 775 /var/log/supervisor /global/oldlogs && \
    chmod 777 /global/log /global/movelog && \
    mkdir -p /etc/profile.d && \
    { \
      echo '#!/bin/sh'; \
      echo 'if [ -n "$PS1" ] && [ -z "${BANNER_SHOWN-}" ]; then'; \
      echo '  export BANNER_SHOWN=1'; \
      echo '  show-banner "RUNNER (SUPERVISOR)"'; \
      echo 'fi'; \
    } > /etc/profile.d/banner-hook.sh && \
    chmod +x /etc/profile.d/banner-hook.sh && \
    { \
      echo 'if [ -n "$PS1" ] && [ -z "${BANNER_SHOWN-}" ]; then'; \
      echo '  export BANNER_SHOWN=1'; \
      echo '  show-banner "RUNNER (SUPERVISOR)"'; \
      echo 'fi'; \
    } >> /root/.bashrc
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
