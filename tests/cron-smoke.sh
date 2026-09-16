#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

IMAGE="${1:-infocyph/runner:ci}"
NAME="runner-cron-${RANDOM}-$$"
TMP_DIR="$(mktemp -d)"
CRON_DIR="$TMP_DIR/cron"
OUT_DIR="$TMP_DIR/out"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$CRON_DIR" "$OUT_DIR" "$BIN_DIR"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$BIN_DIR/path-probe" <<'EOF'
#!/bin/sh
printf 'path-ok\n'
EOF
chmod 755 "$BIN_DIR/path-probe"

cat > "$CRON_DIR/standard" <<'EOF'
@reboot root /bin/sh -c 'printf "standard\n" > /cron-output/standard'
EOF
chmod 644 "$CRON_DIR/standard"

cat > "$CRON_DIR/host-mounted" <<'EOF'
TZ=Asia/Dhaka
CRON_TZ=Asia/Dhaka
@reboot root /bin/sh -c 'path-probe > /cron-output/path; date +\%z > /cron-output/tz'
EOF
chmod 666 "$CRON_DIR/host-mounted"

# Cronie requires final newlines. Runner's supported scheduler fragments are LF-only.
for cron_file in "$CRON_DIR/standard" "$CRON_DIR/host-mounted"; do
    [[ "$(tail -c 1 "$cron_file" | od -An -t x1 | tr -d '[:space:]')" == "0a" ]] \
        || fail "$cron_file is missing its final newline"
    if grep -q $'\r' "$cron_file"; then
        fail "$cron_file unexpectedly contains CRLF"
    fi
done

docker run -d \
    --name "$NAME" \
    -e TZ=Asia/Dhaka \
    -e PATH="/runner-probe:/usr/local/bin:/usr/bin:/bin" \
    -v "$CRON_DIR:/etc/cron.d:ro" \
    -v "$OUT_DIR:/cron-output" \
    -v "$BIN_DIR:/runner-probe:ro" \
    "$IMAGE" >/dev/null

cron_pid=''
for ((i = 0; i < 20; i++)); do
    cron_pid="$(docker exec "$NAME" supervisorctl -c /etc/supervisor/supervisord.conf pid cron 2>/dev/null || true)"
    if [[ "$cron_pid" =~ ^[0-9]+$ ]] && [[ "$cron_pid" -gt 0 ]]; then
        break
    fi
    sleep 1
done
if [[ ! "$cron_pid" =~ ^[0-9]+$ ]] || [[ "$cron_pid" -le 0 ]]; then
    fail "Cronie daemon did not start"
fi

docker exec "$NAME" sh -ec "tr '\\000' '\\n' </proc/$cron_pid/environ | grep -Fx 'TZ=Asia/Dhaka' >/dev/null" \
    || fail "Cronie daemon did not inherit container TZ"
[[ "$(docker exec "$NAME" date +%z)" == '+0600' ]] \
    || fail "container TZ did not resolve to Asia/Dhaka"

for ((i = 0; i < 20; i++)); do
    if [[ -f "$OUT_DIR/standard" && -f "$OUT_DIR/path" && -f "$OUT_DIR/tz" ]]; then
        break
    fi
    sleep 1
done

[[ -f "$OUT_DIR/standard" ]] || {
    docker logs "$NAME" >&2 || true
    fail "standard cron job did not execute"
}
[[ -f "$OUT_DIR/path" ]] || fail "host-mounted permissive cron file did not execute"
[[ -f "$OUT_DIR/tz" ]] || fail "cron timezone probe did not execute"

grep -Fx 'standard' "$OUT_DIR/standard" >/dev/null || fail "standard cron output mismatch"
grep -Fx 'path-ok' "$OUT_DIR/path" >/dev/null || fail "Cronie -P did not preserve custom PATH"
grep -Fx '+0600' "$OUT_DIR/tz" >/dev/null \
    || fail "explicit cron-table TZ did not reach the job"

pass "Cronie scheduler smoke"
