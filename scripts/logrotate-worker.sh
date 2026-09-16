#!/usr/bin/env bash
set -uo pipefail

DEFAULT_INTERVAL=3600
DEFAULT_FAILURE_INTERVAL=60
SLEEP_INTERVAL="${LOGROTATE_INTERVAL:-$DEFAULT_INTERVAL}"
FAILURE_INTERVAL="${LOGROTATE_FAILURE_INTERVAL:-$DEFAULT_FAILURE_INTERVAL}"
STATE_FILE="${LOGROTATE_STATE_FILE:-/var/lib/logrotate/status}"
RUNNING=true
SLEEP_PID=""

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

normalize_interval() {
    local value="$1" fallback="$2" name="$3"
    if is_positive_integer "$value"; then
        printf '%s' "$value"
        return 0
    fi

    printf '[logrotate] Invalid %s=%q; using %ss\n' "$name" "$value" "$fallback" >&2
    printf '%s' "$fallback"
}

shutdown() {
    RUNNING=false
    if [[ -n "$SLEEP_PID" ]]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
}

sleep_for() {
    local seconds="$1"
    [[ "$RUNNING" == true ]] || return 0

    sleep "$seconds" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
}

run_config() {
    local config="$1" rc

    if /usr/sbin/logrotate -s "$STATE_FILE" "$config"; then
        return 0
    else
        rc=$?
    fi

    printf '[logrotate] ERROR: config failed: %s (exit %d)\n' "$config" "$rc" >&2
    return "$rc"
}

run_rotation_pass() {
    local config failed=0 found=0

    printf '[logrotate] Running logrotate (state: %s)\n' "$STATE_FILE"

    if [[ -f /etc/logrotate.conf ]]; then
        printf '[logrotate] Using /etc/logrotate.conf\n'
        run_config /etc/logrotate.conf || failed=1
        return "$failed"
    fi

    printf '[logrotate] Using /etc/logrotate.d/* fallback\n'
    for config in /etc/logrotate.d/*; do
        [[ -f "$config" ]] || continue
        found=1
        run_config "$config" || failed=1
    done

    if ((found == 0)); then
        printf '[logrotate] No logrotate configuration files found\n'
    fi

    return "$failed"
}

trap shutdown TERM INT

SLEEP_INTERVAL="$(normalize_interval "$SLEEP_INTERVAL" "$DEFAULT_INTERVAL" LOGROTATE_INTERVAL)"
FAILURE_INTERVAL="$(normalize_interval "$FAILURE_INTERVAL" "$DEFAULT_FAILURE_INTERVAL" LOGROTATE_FAILURE_INTERVAL)"

if [[ -z "$STATE_FILE" ]]; then
    printf '[logrotate] ERROR: LOGROTATE_STATE_FILE cannot be empty\n' >&2
    exit 1
fi

STATE_DIR="$(dirname -- "$STATE_FILE")"
if ! mkdir -p -- "$STATE_DIR"; then
    printf '[logrotate] ERROR: cannot create state directory: %s\n' "$STATE_DIR" >&2
    exit 1
fi

if [[ ! -d "$STATE_DIR" || ! -w "$STATE_DIR" ]]; then
    printf '[logrotate] ERROR: state directory is not writable: %s\n' "$STATE_DIR" >&2
    exit 1
fi

while [[ "$RUNNING" == true ]]; do
    if run_rotation_pass; then
        delay="$SLEEP_INTERVAL"
    else
        delay="$FAILURE_INTERVAL"
        printf '[logrotate] Rotation pass failed; retrying in %ss\n' "$delay" >&2
    fi

    [[ "$RUNNING" == true ]] || break
    printf '[logrotate] Sleeping for %ss\n' "$delay"
    sleep_for "$delay"
done

printf '[logrotate] Stopped\n'
