#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

BASE='examples/docker-compose.yml'
DOCKER_OVERRIDE='examples/docker-compose.docker.yml'

assert_file "$BASE"
assert_file "$DOCKER_OVERRIDE"

assert_contains "$BASE" 'image: infocyph/runner:latest'
assert_contains "$BASE" './supervisor:/etc/supervisor/conf.d:ro'
assert_contains "$BASE" './cron-jobs:/etc/cron.d:ro'
assert_contains "$BASE" 'runner-logrotate-state:/var/lib/logrotate'
assert_not_contains "$BASE" '/var/run/docker.sock'
assert_not_contains "$BASE" 'privileged:'

assert_contains "$DOCKER_OVERRIDE" '/var/run/docker.sock:/var/run/docker.sock'
assert_not_contains "$DOCKER_OVERRIDE" 'privileged:'

command -v docker >/dev/null 2>&1 || fail 'docker is required for Compose validation'
docker compose version >/dev/null 2>&1 || fail 'docker compose plugin is required for Compose validation'

docker compose -f "$BASE" config -q
docker compose -f "$BASE" -f "$DOCKER_OVERRIDE" config -q

pass "Docker Compose examples"
