#!/bin/sh
container_name="$1"
shift
docker exec "$container_name" php "$@"
