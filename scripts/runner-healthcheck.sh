#!/bin/sh
set -eu

CONFIG="${SUPERVISOR_CONFIG:-/etc/supervisor/supervisord.conf}"

exec supervisorctl -c "$CONFIG" status cron logrotate >/dev/null 2>&1
