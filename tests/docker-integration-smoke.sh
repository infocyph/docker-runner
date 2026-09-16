#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
TARGET="runner-target-${RANDOM}-$$"

cleanup() {
    docker rm -f "$TARGET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$TARGET" alpine:latest sleep 180 >/dev/null

output="$(docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint dexe \
    "$IMAGE" "$TARGET" sh -c 'printf "dexe:%s\n" "$1"' _ 'hello world')"
[[ "$output" == 'dexe:hello world' ]] || fail "real dexe non-TTY output mismatch"

# Provide a tiny PHP-shaped executable so pexe can be validated without pulling a PHP image.
docker exec "$TARGET" sh -ec 'cat > /usr/local/bin/php <<"EOF"
#!/bin/sh
printf "<%s>\n" "$@"
EOF
chmod 755 /usr/local/bin/php'

output="$(docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint pexe \
    "$IMAGE" "$TARGET" 'first arg' 'a;b')"
expected=$'<first arg>\n<a;b>'
[[ "$output" == "$expected" ]] || fail "real pexe argument forwarding mismatch"

set +e
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint dexe \
    "$IMAGE" "$TARGET" sh -c 'exit 23' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 23 ]] || fail "real dexe exit status did not propagate"

# Allocate a host PTY so dexe selects docker exec -it and validates the TTY path end-to-end.
if command -v script >/dev/null 2>&1; then
    tty_output="$(script -qefc "docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock --entrypoint dexe '$IMAGE' '$TARGET' sh -c 'printf tty-ok'" /dev/null | tr -d '\r')"
    [[ "$tty_output" == *tty-ok* ]] || fail "real dexe TTY execution failed"
fi

pass "real Docker helper integration smoke"
