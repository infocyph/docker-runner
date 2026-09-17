#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
COMPOSE_FILE="${2:-}"

[[ -n "$COMPOSE_FILE" && -f "$COMPOSE_FILE" ]] \
    || fail "LocalDevStack companion compose file is required"

echo "Release gate image: $IMAGE"
echo "LocalDevStack contract: $COMPOSE_FILE"

bash tests/standalone-smoke.sh "$IMAGE"
bash tests/supervisor-smoke.sh "$IMAGE"
bash tests/cron-smoke.sh "$IMAGE"
bash tests/logrotate-smoke.sh "$IMAGE"
bash tests/docker-integration-smoke.sh "$IMAGE"
bash tests/localdevstack-contract.sh "$IMAGE" "$COMPOSE_FILE"

pass "final Runner release gate"
