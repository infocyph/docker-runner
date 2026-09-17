#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
NAME="runner-supervisor-${RANDOM}-$$"
TMP_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$TMP_DIR/sample.conf" <<'EOF'
[program:sample]
command=/bin/sh -c 'while :; do sleep 60; done'
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

wait_for_health() {
    local expected="$1"
    local attempts="${2:-20}"
    local state=""

    for ((i = 0; i < attempts; i++)); do
        state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || true)"
        [[ "$state" == "$expected" ]] && return 0
        sleep 1
    done

    docker logs "$NAME" >&2 || true
    fail "health did not become $expected (last: ${state:-unknown})"
}

docker run -d \
    --name "$NAME" \
    --health-interval=1s \
    --health-timeout=2s \
    --health-retries=1 \
    --health-start-period=0s \
    -v "$TMP_DIR:/etc/supervisor/conf.d:ro" \
    "$IMAGE" >/dev/null

wait_for_health healthy 20

docker exec "$NAME" supervisorctl -c /etc/supervisor/supervisord.conf status sample | grep -q RUNNING \
    || fail "sample Supervisor program did not start"

docker exec "$NAME" supervisorctl -c /etc/supervisor/supervisord.conf stop sample >/dev/null
sleep 2

[[ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" == "healthy" ]] \
    || fail "optional stopped program incorrectly made Runner unhealthy"

docker exec "$NAME" runner-healthcheck \
    || fail "core healthcheck failed while only optional program was stopped"

docker exec "$NAME" supervisorctl -c /etc/supervisor/supervisord.conf stop cron >/dev/null
wait_for_health unhealthy 10

set +e
docker exec "$NAME" runner-healthcheck >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "healthcheck should fail when cron is stopped"

pass "Supervisor core-health semantics smoke"
