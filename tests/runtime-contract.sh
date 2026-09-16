#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

assert_contains Dockerfile 'COPY scripts/runner-healthcheck.sh /usr/local/bin/runner-healthcheck'
assert_contains Dockerfile 'CMD ["runner-healthcheck"]'

assert_contains scripts/runner-healthcheck.sh 'status cron logrotate'
assert_not_contains scripts/runner-healthcheck.sh 'status >/dev/null'

assert_contains scripts/supervisord.conf 'logfile_maxbytes=0'
assert_contains scripts/supervisord.conf 'logfile_backups=0'
assert_contains scripts/supervisord.conf 'command=/usr/sbin/crond -f -P -p'

assert_contains scripts/logrotate-worker.sh 'DEFAULT_INTERVAL=3600'
assert_contains scripts/logrotate-worker.sh 'DEFAULT_FAILURE_INTERVAL=60'
assert_contains scripts/logrotate-worker.sh 'LOGROTATE_FAILURE_INTERVAL'
# shellcheck disable=SC2016 # Intentional literal source-code assertion.
assert_contains scripts/logrotate-worker.sh 'run_config "$config" || failed=1'
assert_contains scripts/logrotate-worker.sh 'trap shutdown TERM INT'
assert_not_contains scripts/logrotate-worker.sh 'set -euo pipefail'

assert_contains loggables/supervisord 'cat /run/supervisord.pid'
assert_contains loggables/supervisord 'kill -USR2 "$PID"'
assert_not_contains loggables/supervisord 'supervisorctl -c /etc/supervisor/supervisord.conf reopenlogs'

pass "runtime hardening contracts"
