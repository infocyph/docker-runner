#!/bin/bash

# Default to 3600 seconds (1 hour) if LOGROTATE_INTERVAL is not provided externally
SLEEP_INTERVAL="${LOGROTATE_INTERVAL:-3600}"

while true; do
    for config in /etc/logrotate.d/*; do
        if [[ $(basename "$config") == .* ]]; then
            continue
        fi

        if [ -f "$config" ]; then
            echo "[logrotate] Rotating logs using: $config"
            /usr/sbin/logrotate -s /tmp/logrotate.status -f "$config"
        fi
    done

    echo "[logrotate] Sleeping for ${SLEEP_INTERVAL} seconds"
    sleep "$SLEEP_INTERVAL"
done
