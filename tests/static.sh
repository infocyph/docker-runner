#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

for file in scripts/dexe.sh scripts/pexe.sh; do
    assert_file "$file"
    sh -n "$file"
done

for file in scripts/logrotate-worker.sh scripts/runner-healthcheck.sh tests/*.sh; do
    assert_file "$file"
    bash -n "$file"
done

assert_file scripts/supervisord.conf
assert_file loggables/daily
assert_file loggables/dailyold
assert_file loggables/supervisord

if grep -IRn $'\r' Dockerfile scripts loggables tests .github 2>/dev/null; then
    fail "CRLF detected in source/config files"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck scripts/*.sh tests/*.sh
fi

pass "static repository checks"
