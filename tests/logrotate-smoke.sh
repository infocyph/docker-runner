#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
TMP_DIR="$(mktemp -d)"
NAME="runner-logrotate-${RANDOM}-$$"
FAIL_NAME="runner-logrotate-fail-${RANDOM}-$$"

cleanup() {
    docker rm -f "$NAME" "$FAIL_NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# All bundled fragments must parse in the actual image.
docker run --rm --entrypoint sh "$IMAGE" -ec '
    for config in /etc/logrotate.d/daily /etc/logrotate.d/dailyold /etc/logrotate.d/supervisord; do
        logrotate -d -s /tmp/logrotate-status "$config" >/dev/null 2>&1
    done
' || fail "bundled logrotate config validation failed"

# Force the primary /global/log rotation policy against a nested service log.
LOG_DIR="$TMP_DIR/global-log"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$LOG_DIR/service" "$STATE_DIR"
printf 'first line\nsecond line\n' > "$LOG_DIR/service/app.log"

docker run --rm \
    -v "$LOG_DIR:/global/log" \
    -v "$STATE_DIR:/var/lib/logrotate" \
    --entrypoint sh \
    "$IMAGE" -ec 'logrotate -f -s /var/lib/logrotate/status /etc/logrotate.d/daily' \
    || fail "forced /global/log rotation failed"

[[ -f "$STATE_DIR/status" ]] || fail "logrotate state file was not created"
[[ ! -s "$LOG_DIR/service/app.log" ]] || fail "copytruncate did not truncate active log"
find "$LOG_DIR/service" -maxdepth 1 -type f -name 'app.log-*' -print -quit | grep -q . \
    || fail "dated rotated log was not created"

# Supervisor logs must rotate externally and PID 1 must reopen the new active file.
SUPERVISOR_DIR="$TMP_DIR/supervisor"
mkdir -p "$SUPERVISOR_DIR"
docker run -d \
    --name "$NAME" \
    -v "$SUPERVISOR_DIR:/var/log/supervisor" \
    "$IMAGE" >/dev/null

for ((i = 0; i < 20; i++)); do
    [[ -s "$SUPERVISOR_DIR/supervisord.log" ]] && break
    sleep 1
done
[[ -s "$SUPERVISOR_DIR/supervisord.log" ]] || fail "Supervisor log was not created"

docker exec "$NAME" logrotate -f -s /var/lib/logrotate/supervisor-smoke /etc/logrotate.d/supervisord \
    || fail "Supervisor log rotation failed"

find "$SUPERVISOR_DIR" -maxdepth 1 -type f -name 'supervisord.log-*' -print -quit | grep -q . \
    || fail "rotated Supervisor log was not created"
[[ -f "$SUPERVISOR_DIR/supervisord.log" ]] || fail "active Supervisor log was not recreated"

# Check the actual file descriptor rather than relying on an immediate follow-up log message.
# A successful reopen means PID 1 has an fd whose inode matches the new active logfile.
docker exec "$NAME" sh -ec '
    active_inode="$(stat -c %i /var/log/supervisor/supervisord.log)"
    for fd in /proc/1/fd/*; do
        target="$(readlink "$fd" 2>/dev/null || true)"
        [ "$target" = "/var/log/supervisor/supervisord.log" ] || continue
        fd_inode="$(stat -Lc %i "$fd")"
        [ "$fd_inode" = "$active_inode" ] && exit 0
    done
    exit 1
' || fail "Supervisor PID 1 did not reopen the active logfile"

# A bad fragment must not cause Supervisor to restart-loop the worker.
printf 'this is intentionally invalid logrotate syntax\n' > "$TMP_DIR/zz-invalid"
docker run -d \
    --name "$FAIL_NAME" \
    -e LOGROTATE_INTERVAL=2 \
    -e LOGROTATE_FAILURE_INTERVAL=2 \
    -v "$TMP_DIR/zz-invalid:/etc/logrotate.d/zz-invalid:ro" \
    "$IMAGE" >/dev/null

first_pid=''
for ((i = 0; i < 20; i++)); do
    first_pid="$(docker exec "$FAIL_NAME" supervisorctl -c /etc/supervisor/supervisord.conf pid logrotate 2>/dev/null || true)"
    if [[ "$first_pid" =~ ^[0-9]+$ ]] && [[ "$first_pid" -gt 0 ]]; then
        break
    fi
    sleep 1
done
if [[ ! "$first_pid" =~ ^[0-9]+$ ]] || [[ "$first_pid" -le 0 ]]; then
    fail "logrotate worker did not start"
fi
sleep 5
second_pid="$(docker exec "$FAIL_NAME" supervisorctl -c /etc/supervisor/supervisord.conf pid logrotate)"
[[ "$first_pid" == "$second_pid" ]] || fail "logrotate worker restarted after config failure"
docker logs "$FAIL_NAME" 2>&1 | grep -F 'Retrying in 2s' >/dev/null \
    || fail "bounded logrotate failure retry was not observed"

# Exercise the fallback path: one broken fragment must not prevent a later valid fragment.
FALLBACK_DIR="$TMP_DIR/fallback-config"
FALLBACK_WORK="$TMP_DIR/fallback-work"
mkdir -p "$FALLBACK_DIR" "$FALLBACK_WORK"
printf 'broken directive\n' > "$FALLBACK_DIR/01-invalid"
cat > "$FALLBACK_DIR/02-valid" <<'EOF'
/work/app.log {
    su root root
    size 1
    rotate 1
    missingok
    notifempty
    copytruncate
}
EOF
printf 'fallback rotation payload\n' > "$FALLBACK_WORK/app.log"

docker run --rm \
    -v "$FALLBACK_DIR:/etc/logrotate.d:ro" \
    -v "$FALLBACK_WORK:/work" \
    --entrypoint bash \
    "$IMAGE" -ec '
        mv /etc/logrotate.conf /etc/logrotate.conf.disabled
        LOGROTATE_INTERVAL=30 LOGROTATE_FAILURE_INTERVAL=30 logrotate-worker.sh &
        worker=$!
        for _ in $(seq 1 10); do
            if find /work -maxdepth 1 -type f -name "app.log.*" -print -quit | grep -q .; then
                kill -TERM "$worker"
                wait "$worker"
                exit 0
            fi
            sleep 1
        done
        kill -TERM "$worker" 2>/dev/null || true
        wait "$worker" || true
        exit 1
    ' || fail "fallback logrotate worker did not continue past invalid fragment"

# SIGTERM must interrupt the worker's long sleep promptly.
docker run --rm --entrypoint bash "$IMAGE" -ec '
    LOGROTATE_INTERVAL=60 LOGROTATE_FAILURE_INTERVAL=60 logrotate-worker.sh >/tmp/worker.log 2>&1 &
    worker=$!
    sleep 2
    kill -TERM "$worker"
    for _ in $(seq 1 5); do
        if ! kill -0 "$worker" 2>/dev/null; then
            wait "$worker"
            exit 0
        fi
        sleep 1
    done
    kill -KILL "$worker" 2>/dev/null || true
    exit 1
' || fail "logrotate worker did not stop promptly on SIGTERM"

pass "logrotate runtime smoke"
