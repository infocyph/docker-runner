#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
COMPOSE_FILE="${2:-}"
[[ -n "$COMPOSE_FILE" && -f "$COMPOSE_FILE" ]] || fail "LocalDevStack companion compose file is required"

# Lock the live LocalDevStack integration surface we are promising to support.
for expected in \
    'image: infocyph/runner:latest' \
    '../../configuration/scheduler/supervisor:/etc/supervisor/conf.d:ro' \
    '../../configuration/scheduler/cron-jobs:/etc/cron.d:ro' \
    '../../logs/runner:/var/log/supervisor' \
    '../../logs/apache:/global/log/apache' \
    '../../logs/mysql:/global/log/mysql' \
    '../../logs/nginx:/global/log/nginx' \
    '../../logs/redis:/global/log/redis' \
    '/var/run/docker.sock:/var/run/docker.sock'; do
    grep -F -- "$expected" "$COMPOSE_FILE" >/dev/null || fail "LocalDevStack compose contract changed: $expected"
done

NAME="runner-lds-${RANDOM}-$$"
TARGET="runner-lds-target-${RANDOM}-$$"
TMP_DIR="$(mktemp -d)"
SUPERVISOR_DIR="$TMP_DIR/supervisor"
CRON_DIR="$TMP_DIR/cron"
RUNNER_LOG_DIR="$TMP_DIR/runner-log"
LOG_ROOT="$TMP_DIR/logs"
mkdir -p "$SUPERVISOR_DIR" "$CRON_DIR" "$RUNNER_LOG_DIR" "$LOG_ROOT"

cleanup() {
    docker rm -f "$NAME" "$TARGET" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$SUPERVISOR_DIR/localdevstack.conf" <<'EOF'
[program:localdevstack-fixture]
command=/bin/sh -c 'while :; do sleep 60; done'
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
chmod 644 "$SUPERVISOR_DIR/localdevstack.conf"

cat > "$CRON_DIR/localdevstack" <<'EOF'
@reboot root /bin/sh -c 'printf "cron-ok\n" > /global/log/apache/cron-probe.log'
EOF
chmod 666 "$CRON_DIR/localdevstack"

services=(
    apache cloudbeaver elasticsearch kibana mariadb mongo-express mongodb mysql
    nginx postgresql redis redis-insight
)
mount_args=()
for service in "${services[@]}"; do
    mkdir -p "$LOG_ROOT/$service"
    mount_args+=( -v "$LOG_ROOT/$service:/global/log/$service" )
done

docker run -d --name "$TARGET" alpine:latest sleep 180 >/dev/null

docker run -d \
    --name "$NAME" \
    --health-interval=1s \
    --health-timeout=2s \
    --health-retries=3 \
    --health-start-period=0s \
    -e TZ=Asia/Dhaka \
    -v "$SUPERVISOR_DIR:/etc/supervisor/conf.d:ro" \
    -v "$CRON_DIR:/etc/cron.d:ro" \
    -v "$RUNNER_LOG_DIR:/var/log/supervisor" \
    "${mount_args[@]}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$IMAGE" >/dev/null

wait_for_healthy() {
    local state=""
    for ((i = 0; i < 25; i++)); do
        state="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || true)"
        [[ "$state" == "healthy" ]] && return 0
        sleep 1
    done
    docker logs "$NAME" >&2 || true
    fail "LocalDevStack-shaped Runner did not become healthy (last: ${state:-unknown})"
}

wait_for_healthy

docker exec "$NAME" supervisorctl -c /etc/supervisor/supervisord.conf status localdevstack-fixture | grep -q RUNNING \
    || fail "read-only LocalDevStack Supervisor mount was not loaded"

for ((i = 0; i < 20; i++)); do
    [[ -f "$LOG_ROOT/apache/cron-probe.log" ]] && break
    sleep 1
done
[[ -f "$LOG_ROOT/apache/cron-probe.log" ]] || fail "LocalDevStack cron mount did not execute"
grep -Fx 'cron-ok' "$LOG_ROOT/apache/cron-probe.log" >/dev/null || fail "LocalDevStack cron output mismatch"

output="$(docker exec "$NAME" dexe "$TARGET" sh -c 'printf lds-dexe-ok')"
[[ "$output" == 'lds-dexe-ok' ]] || fail "Docker-socket helper failed in LocalDevStack shape"

[[ "$(docker exec "$NAME" date +%z)" == '+0600' ]] || fail "LocalDevStack TZ propagation failed"
[[ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$NAME")" == 'false' ]] || fail "Runner unexpectedly requires privileged mode"
[[ "$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$NAME")" == 'null' ]] || fail "Runner unexpectedly requires added capabilities"

docker restart "$NAME" >/dev/null
wait_for_healthy
docker exec "$NAME" supervisorctl -c /etc/supervisor/supervisord.conf status localdevstack-fixture | grep -q RUNNING \
    || fail "LocalDevStack fixture did not recover after restart"

pass "LocalDevStack compatibility smoke"
