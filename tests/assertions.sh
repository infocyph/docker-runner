#!/bin/sh
set -eu

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_executable() {
    [ -x "$1" ] || fail "expected executable: $1"
}

assert_contains() {
    file="$1"
    pattern="$2"
    grep -F -- "$pattern" "$file" >/dev/null 2>&1 || fail "$file does not contain: $pattern"
}

assert_not_contains() {
    file="$1"
    pattern="$2"
    if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
        fail "$file unexpectedly contains: $pattern"
    fi
}
