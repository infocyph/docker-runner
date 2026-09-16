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
@reboot root /bin/sh -c 'path-probe > /cron-output/path; date +\%z > /cron-output/tz'
EOF
chmod 666 "$CRON_DIR/host-mounted"

# Explicitly assert the fixture has the final newline Cronie expects.
[[ "$(tail -c 1 "$CRON_DIR/standard" | od -An -t x1 | tr -d '[:space:]')" == "0a" ]] \
    || fail "standard cron fixture is missing final newline"
[[ "$(tail -c 1 "$CRON_DIR/host-mounted" | od -An -t x1 | tr -d '[:space:]')" == "0a" ]] \
    || fail "host-mounted cron fixture is missing final newline"

docker run -d \
    --name "$NAME" \
    -e TZ=Asia/Dhaka \
    -e PATH="/runner-probe:/usr/local/bin:/usr/bin:/bin" \
    -v "$CRON_DIR:/etc/cron.d:ro" \
    -v "$OUT_DIR:/cron-output" \
    -v "$BIN_DIR:/runner-probe:ro" \
    "$IMAGE" >/dev/null

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
grep -Fx '+0600' "$OUT_DIR/tz" >/dev/null || fail "cron job did not inherit Asia/Dhaka timezone"

# CRLF cron fragments are unsupported. Cronie's syntax test must reject them.
printf '@reboot root /bin/true\r\n' > "$TMP_DIR/crlf"
set +e
docker run --rm \
    -v "$TMP_DIR/crlf:/etc/cron.d/crlf:ro" \
    --entrypoint crond \
    "$IMAGE" -T >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "Cronie unexpectedly accepted CRLF cron fragment"

pass "Cronie scheduler smoke"
