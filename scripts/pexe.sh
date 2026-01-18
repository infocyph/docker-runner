#!/bin/sh
set -eu

cn="${1:-}"
[ -n "$cn" ] || { echo "Usage: pexe <container> <php-args...>" >&2; exit 2; }
shift

if [ "$#" -eq 0 ]; then
  echo "Usage: pexe <container> <php-args...>" >&2
  exit 2
fi

if [ -t 0 ] && [ -t 1 ]; then
  exec docker exec -it "$cn" php "$@"
fi

exec docker exec "$cn" php "$@"
