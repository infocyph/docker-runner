#!/usr/bin/env bash
set -euo pipefail

SLEEP_INTERVAL="${LOGROTATE_INTERVAL:-3600}"
STATE_FILE="${LOGROTATE_STATE_FILE:-/var/lib/logrotate/status}"

mkdir -p "$(dirname "$STATE_FILE")"

while true; do
    echo "[logrotate] Running logrotate (state: $STATE_FILE)"

    # Preferred: run the main config if it exists (it includes /etc/logrotate.d/* typically)
    if [[ -f /etc/logrotate.conf ]]; then
        echo "[logrotate] Using /etc/logrotate.conf"
        /usr/sbin/logrotate -s "$STATE_FILE" /etc/logrotate.conf
    else
        echo "[logrotate] Using /etc/logrotate.d/* fallback"
        for config in /etc/logrotate.d/*; do
            [[ -f "$config" ]] || continue
            [[ "$(basename "$config")" == .* ]] && continue
            /usr/sbin/logrotate -s "$STATE_FILE" "$config"
        done
    fi

    echo "[logrotate] Sleeping for ${SLEEP_INTERVAL}s"
    sleep "$SLEEP_INTERVAL"
done
