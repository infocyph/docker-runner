# 🚀 Docker Runner

[![Docker Publish](https://github.com/infocyph/docker-runner/actions/workflows/docker.publish.yml/badge.svg)](https://github.com/infocyph/docker-runner/actions/workflows/docker.publish.yml)
[![Check](https://github.com/infocyph/docker-runner/actions/workflows/check.yml/badge.svg)](https://github.com/infocyph/docker-runner/actions/workflows/check.yml)
![Docker Pulls](https://img.shields.io/docker/pulls/infocyph/runner)
![Docker Image Size](https://img.shields.io/docker/image-size/infocyph/runner)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Base: Alpine](https://img.shields.io/badge/Base-Alpine-brightgreen.svg)](https://alpinelinux.org)

A small Alpine-based infrastructure image for **Supervisor + Cronie + logrotate**, with thin Docker `exec` helpers for environments that choose to provide Docker access.

Runner is primarily used by [LocalDevStack](https://github.com/infocyph/LocalDevStack), but standalone operation is a first-class contract.

## What Runner owns

Runner deliberately stays narrow:

- Supervisor as PID 1;
- Cronie for scheduled jobs;
- a resilient logrotate worker;
- `dexe` and `pexe` Docker exec wrappers;
- the existing interactive banner helper.

It does **not** bundle PHP, Node.js, databases, web servers, queue brokers, or a Docker daemon.

## Images

| Registry | Image |
| --- | --- |
| Docker Hub | `docker.io/infocyph/runner` |
| GHCR | `ghcr.io/infocyph/runner` |

Published images support:

- `linux/amd64`;
- `linux/arm64`.

`latest` is the moving integration channel and is refreshed from the latest published Runner release once per week against current moving upstream dependencies. Version tags are intended to remain immutable.

## Standalone usage

No Docker socket or external mount is required to start Runner:

```bash
docker run -d --name runner infocyph/runner:latest
```

The container becomes healthy when Runner's two core supervised services are running:

```text
cron
logrotate
```

Additional user-mounted Supervisor programs are intentionally **not** part of the container health decision.

Useful checks:

```bash
docker exec runner runner-healthcheck
docker exec runner supervisorctl -c /etc/supervisor/supervisord.conf status
```

## Docker Compose examples

A standalone-first Compose example is included at:

```text
examples/docker-compose.yml
```

Validate it without starting containers:

```bash
docker compose -f examples/docker-compose.yml config -q
```

Start it:

```bash
mkdir -p examples/supervisor examples/cron-jobs examples/logs
docker compose -f examples/docker-compose.yml up -d
```

The default example does **not** mount the Docker socket. If `dexe` or `pexe` must control sibling containers, add the supplied opt-in override:

```bash
docker compose \
  -f examples/docker-compose.yml \
  -f examples/docker-compose.docker.yml \
  up -d
```

The merged configuration can also be validated before use:

```bash
docker compose \
  -f examples/docker-compose.yml \
  -f examples/docker-compose.docker.yml \
  config -q
```

Repository CI validates both Compose forms on every supported working branch/PR.

## Optional mounts

A fuller standalone setup can mount only the features it needs:

```bash
docker run -d \
  --name runner \
  -e TZ=Asia/Dhaka \
  -v ./supervisor:/etc/supervisor/conf.d:ro \
  -v ./cron-jobs:/etc/cron.d:ro \
  -v ./logs/runner:/var/log/supervisor \
  -v ./logs:/global/log \
  -v ./logrotate-state:/var/lib/logrotate \
  infocyph/runner:latest
```

Mount the Docker socket only when `dexe` or `pexe` must control sibling containers:

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

> Mounting the Docker socket grants Runner powerful control over the Docker host. It is optional and should not be added merely for health, cron, Supervisor, or log rotation.

## LocalDevStack integration

LocalDevStack currently uses Runner as its background-process companion and mounts approximately:

```text
configuration/scheduler/supervisor -> /etc/supervisor/conf.d:ro
configuration/scheduler/cron-jobs  -> /etc/cron.d:ro
logs/runner                         -> /var/log/supervisor
logs/<service>                      -> /global/log/<service>
/var/run/docker.sock               -> /var/run/docker.sock
```

Runner does not bake LocalDevStack-specific networks, hostnames, container names, or host paths into the image.

## Supervisor

The default command is:

```text
supervisord -c /etc/supervisor/supervisord.conf
```

Supervisor remains PID 1 and starts:

- `cron`;
- `logrotate`.

Additional programs can be mounted read-only into `/etc/supervisor/conf.d`.

Example:

```ini
[program:worker]
command=/bin/sh -c 'while :; do echo tick; sleep 60; done'
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

Supervisor's internal size-based logfile rotation is disabled. `/var/log/supervisor/*.log` is owned by the external logrotate policy, which signals Supervisor to reopen its log files after rotation.

## Healthcheck

The image healthcheck calls:

```text
runner-healthcheck
```

It validates Supervisor connectivity and only the Runner-owned core programs:

```text
cron
logrotate
```

This means an intentionally stopped or failed application program mounted through `/etc/supervisor/conf.d` does not falsely mark the Runner container unhealthy.

Default Docker health settings:

- interval: `30s`;
- timeout: `3s`;
- start period: `10s`;
- retries: `3`.

## Cronie

Runner uses Cronie, not BusyBox cron. The supervised daemon command is:

```text
/usr/sbin/crond -f -P -p
```

`-P` preserves the daemon's inherited `PATH`; `-p` permits cron files that would otherwise fail Cronie's strict ownership/mode rules, which is important for cross-platform bind-mounted LocalDevStack scheduler files.

Mount jobs read-only:

```bash
-v ./cron-jobs:/etc/cron.d:ro
```

A system-style file includes the user field:

```cron
* * * * * root printf 'cron ran\n' >> /global/log/cron.log 2>&1
```

Keep cron files LF-only and end them with a final newline.

### Timezones in cron jobs

Setting container `TZ` configures the Runner environment, but Cronie builds a controlled environment for jobs. If a job itself requires a specific timezone, define it explicitly in the cron file:

```cron
TZ=Asia/Dhaka
* * * * * root date >> /global/log/time.log 2>&1
```

## Log rotation

The logrotate worker runs continuously under Supervisor.

### Environment variables

| Variable | Default | Meaning |
| --- | ---: | --- |
| `LOGROTATE_INTERVAL` | `3600` | Seconds between successful rotation passes |
| `LOGROTATE_FAILURE_INTERVAL` | `60` | Seconds before retry after a failed pass |
| `LOGROTATE_STATE_FILE` | `/var/lib/logrotate/status` | Rotation state path |
| `TZ` | unset | Container timezone |

Intervals must be positive integers. Invalid values fall back to their defaults instead of creating a tight loop.

A malformed logrotate fragment is reported but does not cause the worker to crash into a Supervisor restart storm. In fallback mode, remaining fragments are still attempted before the worker waits for the bounded failure retry interval.

### State persistence

`/var/lib/logrotate/status` persists while the same container exists. To preserve state across container replacement/recreation, mount `/var/lib/logrotate` to persistent storage:

```bash
-v runner-logrotate-state:/var/lib/logrotate
```

### `/global/log`

The bundled policy matches these explicit depths:

```text
/global/log/*.log
/global/log/*/*.log
/global/log/*/*/*.log
```

So files can be at the root, one directory deep, or two directories deep beneath `/global/log`; the config does not promise unlimited `**` recursion.

Current policy includes:

- daily rotation;
- `rotate 7`;
- `maxage 30`;
- `missingok`;
- `notifempty`;
- `copytruncate`;
- compression with delayed compression;
- date suffixes.

`copytruncate` is intentional because Runner cannot signal arbitrary sibling applications to reopen their own logs.

### Legacy move-to-oldlogs paths

For compatibility, Runner also keeps:

```text
/global/movelog
/global/oldlogs
```

The same explicit depth model is used for `/global/movelog`; rotated files are moved into `/global/oldlogs`.

These paths are retained for existing consumers even though current LocalDevStack does not rely on them.

### Supervisor logs

`/var/log/supervisor/*.log` is rotated daily by the bundled policy. Supervisor is then sent `SIGUSR2` so it closes and reopens its log descriptors and new writes continue to the active logfile.

## Docker exec helpers

### `dexe`

Execute any command in another container:

```bash
dexe <container> <command> [...args]
```

Example:

```bash
dexe my-app sh -c 'printf "hello\n"'
```

### `pexe`

Execute PHP in another container:

```bash
pexe <container> <php-args...>
```

Example:

```bash
pexe my-php-app artisan migrate
```

Both wrappers:

- forward arguments without `eval` or shell reconstruction;
- preserve the target Docker command's exit status;
- add `-it` automatically only when stdin and stdout are terminals.

They require access to a Docker endpoint. The default LocalDevStack integration supplies `/var/run/docker.sock`; standalone Runner does not.

## Moving dependency policy

Runner intentionally follows current upstream foundations:

- `alpine:latest`;
- `Scriptomatic/main` for the banner helper;
- latest stable Toolset release for `chromacat`.

These are deliberate moving dependencies. Compatibility is protected by repository CI/runtime smoke, arm64 validation, and the weekly fresh `latest` rebuild/publish gate rather than by freezing those inputs.

Published builds expose provenance/SBOM information and workflow summaries record the resolved Alpine, Toolset/chromacat, and Scriptomatic state used for the build.

## Release behavior

On a GitHub release:

1. the exact release tag is checked out;
2. fresh amd64 and arm64 candidates are built against current moving upstreams;
3. the full amd64 release gate and arm64 startup gate run before registry login/push;
4. the immutable version tag and `latest` are published to Docker Hub and GHCR;
5. the multi-architecture image includes amd64 + arm64;
6. SBOM/provenance and registry attestations are emitted.

Once per week, the latest stable published Runner source release is rebuilt against current moving upstreams and **only `latest`** is refreshed. Historical version tags are not republished by the scheduled refresh.

## Troubleshooting

### Container is unhealthy

Check the two core services:

```bash
docker exec runner runner-healthcheck
docker exec runner supervisorctl -c /etc/supervisor/supervisord.conf status cron logrotate
```

A non-core mounted Supervisor program can fail without affecting Runner health by design.

### Cron job does not run

Check:

```bash
docker exec runner ls -la /etc/cron.d
docker exec runner supervisorctl -c /etc/supervisor/supervisord.conf status cron
```

Common causes:

- CRLF line endings;
- missing final newline;
- malformed schedule;
- missing system-cron user field such as `root`;
- a command that writes to an unwritable path.

### Logrotate does not rotate

Check worker status and logs:

```bash
docker exec runner supervisorctl -c /etc/supervisor/supervisord.conf status logrotate
docker logs runner
```

Validate the primary config manually:

```bash
docker exec runner logrotate -d -s /tmp/logrotate-debug /etc/logrotate.d/daily
```

Force a test rotation only when you intentionally want to bypass normal state/timing:

```bash
docker exec runner logrotate -f -s /var/lib/logrotate/status /etc/logrotate.d/daily
```

### Windows line endings

Repository files are locked to LF through `.gitattributes`. Host-mounted scheduler/config files should also be LF-only.

A simple host-side conversion is:

```bash
sed -i 's/\r$//' ./cron-jobs/* ./supervisor/*.conf 2>/dev/null || true
```

## License

MIT © [infocyph](https://github.com/infocyph)
