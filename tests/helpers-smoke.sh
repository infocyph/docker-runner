#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/docker" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_DOCKER_LOG:?}"
printf '<%s>\n' "$@" > "$FAKE_DOCKER_LOG"
exit "${FAKE_DOCKER_EXIT:-0}"
SH
chmod +x "$TMP_DIR/docker"

run_with_fake_docker() {
    FAKE_DOCKER_LOG="$TMP_DIR/argv.log" PATH="$TMP_DIR:$PATH" "$@"
}

set +e
sh scripts/dexe.sh >/dev/null 2>"$TMP_DIR/dexe.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "dexe missing container should exit 2"
grep -F 'Usage: dexe' "$TMP_DIR/dexe.err" >/dev/null || fail "dexe usage missing"

set +e
sh scripts/pexe.sh target >/dev/null 2>"$TMP_DIR/pexe.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "pexe missing php args should exit 2"
grep -F 'Usage: pexe' "$TMP_DIR/pexe.err" >/dev/null || fail "pexe usage missing"

run_with_fake_docker sh scripts/dexe.sh 'app-1' printf '%s %s' 'hello world' 'a;b'
cat > "$TMP_DIR/expected" <<'EOF'
<exec>
<app-1>
<printf>
<%s %s>
<hello world>
<a;b>
EOF
cmp -s "$TMP_DIR/expected" "$TMP_DIR/argv.log" || fail "dexe argv forwarding changed"

run_with_fake_docker sh scripts/pexe.sh 'php_84' artisan queue:work '--queue=high priority'
cat > "$TMP_DIR/expected" <<'EOF'
<exec>
<php_84>
<php>
<artisan>
<queue:work>
<--queue=high priority>
EOF
cmp -s "$TMP_DIR/expected" "$TMP_DIR/argv.log" || fail "pexe argv forwarding changed"

set +e
FAKE_DOCKER_EXIT=37 run_with_fake_docker sh scripts/dexe.sh app false
rc=$?
set -e
[ "$rc" -eq 37 ] || fail "dexe must propagate docker exit status"

pass "Docker exec helper smoke tests"
