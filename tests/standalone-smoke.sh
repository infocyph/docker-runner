#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
NAME="runner-standalone-${RANDOM}-$$"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_health() {
    local expected="$1"
    local attempts="${2:-20}"
    local state=""

    for ((i = 0; i < attempts; i++)); do
        state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || true)"
        if [[ "$state" == "$expected" ]]; then
            return 0
        fi
        sleep 1
    done

    docker logs "$NAME" >&2 || true
    fail "standalone health did not become $expected (last: ${state:-unknown})"
}

docker run -d \
    --name "$NAME" \
    --health-interval=1s \
    --health-timeout=2s \
    --health-retries=3 \
    --health-start-period=0s \
    "$IMAGE" >/dev/null

wait_for_health healthy 20

docker exec "$NAME" sh -ec '
    case "$(tr "\000" " " </proc/1/cmdline)" in
        *supervisord*) ;;
        *) exit 1 ;;
    esac
    supervisorctl -c /etc/supervisor/supervisord.conf status cron logrotate >/dev/null
    runner-healthcheck
    test ! -e /var/run/docker.sock
' || fail "standalone runtime contract failed"

start_epoch="$(date +%s)"
docker stop -t 10 "$NAME" >/dev/null
stop_seconds="$(( $(date +%s) - start_epoch ))"

[[ "$stop_seconds" -le 12 ]] || fail "standalone shutdown took ${stop_seconds}s"
[[ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" -eq 0 ]] || fail "standalone shutdown exit code was non-zero"

pass "standalone Runner smoke"
