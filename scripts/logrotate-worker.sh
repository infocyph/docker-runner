#!/bin/bash

# Default to 3600 seconds (1 hour) if LOGROTATE_INTERVAL is not provided externally
SLEEP_INTERVAL="${LOGROTATE_INTERVAL:-3600}"

while true; do
    # This glob generally ignores dotfiles.
    for config in /etc/logrotate.d/*; do
        # Extra check: skip any file whose basename starts with a dot.
        if [[ $(basename "$config") == .* ]]; then
            echo "[logrotate] Ignoring dot file: $config"
            continue
        fi

        if [ -f "$config" ]; then
            echo "[logrotate] Rotating logs using: $config"
            /usr/sbin/logrotate -s /tmp/logrotate.status -f "$config"
        else
            echo "[logrotate] Skipping non-file: $config"
        fi
    done

    echo "[logrotate] Sleeping for ${SLEEP_INTERVAL} seconds"
    sleep "$SLEEP_INTERVAL"
done
