#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

assert_contains Dockerfile 'FROM alpine:latest'
assert_contains Dockerfile 'raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh'
assert_contains Dockerfile 'github.com/infocyph/Toolset/releases/latest/download/install.sh'
assert_contains Dockerfile '--prefix /usr/local/bin chromacat'

assert_not_contains Dockerfile 'Scriptomatic/master'
assert_not_contains Dockerfile 'SCRIPTOMATIC_REF'
assert_not_contains Dockerfile 'TOOLSET_VERSION'
assert_not_contains Dockerfile 'Toolset/main/'
assert_not_contains Dockerfile 'bash /tmp/toolset-install.sh --all'
assert_not_contains Dockerfile 'FROM alpine:'

# The exact expected base is allowed; reject any additional Alpine FROM line.
alpine_from_count="$(grep -Ec '^FROM[[:space:]]+alpine:' Dockerfile || true)"
[ "$alpine_from_count" -eq 1 ] || fail "expected exactly one Alpine FROM line"

pass "dependency contracts"
