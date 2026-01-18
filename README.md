# 🚀 Docker Runner (Supervisor Service)

[![Docker Publish](https://github.com/infocyph/docker-runner/actions/workflows/docker.publish.yml/badge.svg)](https://github.com/infocyph/docker-runner/actions/workflows/docker.publish.yml)
![Docker Pulls](https://img.shields.io/docker/pulls/infocyph/runner)
![Docker Image Size](https://img.shields.io/docker/image-size/infocyph/runner)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Base: Alpine](https://img.shields.io/badge/Base-Alpine-brightgreen.svg)](https://alpinelinux.org)

A lightweight, Alpine-based Docker image designed to run and manage long-running processes using **Supervisor**, with built-in support for:

- `docker exec` wrappers (`pexe` & `dexe`) with TTY auto-detection
- Scheduled log rotation via `logrotate` (worker loop + persisted state)
- Cron support via `cronie` (logs to Docker stdout)
- Clean log management for scalable environments
- Built-in container **HEALTHCHECK** (Supervisor responsiveness)

---

## 📦 Available on Registries

| Registry         | Image Name                  |
|------------------|-----------------------------|
| Docker Hub       | `docker.io/infocyph/runner` |
| GitHub Container | `ghcr.io/infocyph/runner`   |

---

## ✨ What it runs by default

The container starts **Supervisor** as PID 1 which manages:

- `crond` (foreground, logs to Docker stdout)
- a `logrotate` worker loop that runs periodically

You can mount additional Supervisor programs via `/etc/supervisor/conf.d`.

---

## 🩺 Healthcheck

The image includes a healthcheck that verifies Supervisor is responsive:

- Interval: 30s
- Timeout: 3s
- Start period: 10s
- Retries: 3

If Supervisor becomes unresponsive, the container will be reported as **unhealthy**.

---

## 💪 Executables

### `dexe`

Run any command inside a container (TTY auto-detected):

```sh
dexe <container_name> <command> [...args]
````

Example:

```sh
dexe my-app echo "Hello from inside"
```

### `pexe`

Run PHP inside a container (TTY auto-detected):

```sh
pexe <container_name> <php_args...>
```

Example:

```sh
pexe my-php-app artisan migrate
```

> **Note:** `pexe` is a thin wrapper over `docker exec ... php ...`

---

## 🔄 Log Rotation

### Environment

* `LOGROTATE_INTERVAL` (seconds) — default: `3600`
* `LOGROTATE_STATE_FILE` — default: `/var/lib/logrotate/status`
* `TZ` — optional timezone for consistent scheduling/log timestamps

Example:

```bash
-e TZ=Asia/Dhaka \
-e LOGROTATE_INTERVAL=3600
```

### How rotation works

* Logrotate configs are loaded from: `/etc/logrotate.d/`
* The worker prefers `/etc/logrotate.conf` if present; otherwise it rotates each file in `/etc/logrotate.d/*`
* Log files are rotated **daily** by default (per configs)
* Rotation status is tracked in `LOGROTATE_STATE_FILE` to avoid repeated rotations across restarts

### Paths & behaviors

#### 1) Standard logs: `/global/log`

Mount any directory into `/global/log/*` and any `*.log` inside (including subdirs) will rotate daily.

```bash
-v $(pwd)/logs:/global/log/my-app
```

#### 2) Move-to-oldlogs: `/global/movelog` ➜ `/global/oldlogs`

Mount logs that you want rotated daily **and moved** into `/global/oldlogs`.

```bash
-v $(pwd)/movelogs:/global/movelog/my-app
-v $(pwd)/oldlogs:/global/oldlogs
```

#### 3) Supervisor logs: `/var/log/supervisor`

Supervisor’s own logs (and any program logs you write there) rotate daily.

```bash
-v $(pwd)/logs/runner:/var/log/supervisor
```

### Docker log messages on rotation

Your logrotate configs emit a post-rotate line into Docker logs (stdout of PID 1), e.g.:

* `[logrotate] rotated /global/log (daily) at ...`
* `[logrotate] rotated /global/movelog -> /global/oldlogs (daily) at ...`
* `[logrotate] rotated /var/log/supervisor (daily) at ...`

This is done by writing to `/proc/1/fd/1` to reliably land in `docker logs`.

---

## 🕒 Cron

Cron runs in the foreground with logging enabled:

* `crond -f -l 2 -L /dev/stdout`

To add cron jobs, mount `/etc/cron.d`:

```bash
-v ./cron-jobs:/etc/cron.d:ro
```

Example file: `my-cron`:

```cron
* * * * * root echo "Cron ran at $(date)" >> /global/log/my-cron.log 2>&1
```

---

## 🌐 Usage

### Single command running container

```bash
docker run -d \
  --name runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ./supervisor:/etc/supervisor/conf.d:ro \
  -v ./cron-jobs:/etc/cron.d:ro \
  -v ./logs/runner:/var/log/supervisor \
  -v $(pwd)/logs:/global/log \
  -v $(pwd)/movelogs:/global/movelog \
  -v $(pwd)/oldlogs:/global/oldlogs \
  infocyph/runner
```

### Add Supervisor processes

Mount `/etc/supervisor/conf.d` to add Supervisor programs.

Example: `my-task.conf`

```ini
[program:my-task]
command=/bin/sh -c 'echo Hello World && sleep 60'
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/my-task.err.log
stdout_logfile=/var/log/supervisor/my-task.out.log

[program:scheduler]
command=pexe MY_PHP_CONTAINER artisan schedule:run
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/scheduler.err.log
stdout_logfile=/var/log/supervisor/scheduler.out.log
```

> Tip: If you want scheduler to run periodically, prefer cron calling `pexe ... schedule:run`.

---

## 🧰 Troubleshooting

### Check container health

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
docker inspect --format '{{json .State.Health}}' runner | jq .
```

If the container is `unhealthy`, it means `supervisorctl status` failed (Supervisor not responding).

### Check Supervisor status inside container

```bash
docker exec -it runner supervisorctl -c /etc/supervisor/supervisord.conf status
```

### Where to look for logs

* Docker logs (recommended):

  ```bash
  docker logs -f runner
  ```

  You should see cron logs and logrotate worker logs here.
* Supervisor log file (if you mounted it):

    * `/var/log/supervisor/supervisord.log`

### Cron jobs not running?

Common causes:

* The file in `/etc/cron.d` has wrong permissions/format. Keep it simple:

    * one job per line
    * includes the user field (e.g. `root`)
* Ensure your cron job writes somewhere writable (example uses `/global/log/...`).

Quick validation:

```bash
docker exec -it runner ls -la /etc/cron.d
docker logs -f runner | grep -i cron
```

### Logrotate not rotating?

Things to check:

* Confirm the worker is running:

  ```bash
  docker exec -it runner supervisorctl -c /etc/supervisor/supervisord.conf status
  ```

* Confirm your logs match the patterns:

    * `/global/log/**/*.log`
    * `/global/movelog/**/*.log`
    * `/var/log/supervisor/*.log`

* Confirm state file exists (rotation is stateful):

  ```bash
  docker exec -it runner ls -la /var/lib/logrotate/status
  ```

* Force a single manual run (for testing only):

  ```bash
  docker exec -it runner /usr/sbin/logrotate -v -s /var/lib/logrotate/status /etc/logrotate.d/daily
  ```

### Permissions & Windows line endings (CRLF)

These two issues cause 80% of “cron/logrotate not working” reports:

1. **CRLF in mounted files** (especially from Windows)

* Symptoms: “bad minute”, “^M”, jobs ignored, scripts not executed.
* Fix on host:

  ```bash
  sed -i 's/\r$//' ./cron-jobs/* ./supervisor/*.conf 2>/dev/null || true
  ```

2. **Wrong permissions / ownership**

* `/etc/cron.d/*` should be readable by root.
* Your log dirs should be writable by the processes writing logs.

Quick checks:

```bash
docker exec -it runner sh -lc 'ls -la /etc/cron.d /etc/supervisor/conf.d /global/log /global/movelog /global/oldlogs /var/log/supervisor'
```

### “I mounted logs but nothing happens”

Most common mistake: mounting the wrong path.

Correct examples:

```bash
-v $(pwd)/logs:/global/log/my-app
-v $(pwd)/movelogs:/global/movelog/my-app
-v $(pwd)/oldlogs:/global/oldlogs
```

### My logrotate postrotate messages aren’t in `docker logs`

Your configs write to `/proc/1/fd/1`. If you run the container without Supervisor as PID 1 (custom entrypoint), this won’t work.

Make sure you’re using the default CMD:

```bash
supervisord -c /etc/supervisor/supervisord.conf
```

---

## 🔐 Notes

* Mounting `/var/run/docker.sock` allows `pexe` and `dexe` to exec into other containers.
* `/etc/supervisor/conf.d` and `/etc/cron.d` should typically be mounted read-only (`:ro`).

---

## 📑 License

MIT © [infocyph](https://github.com/infocyph)

---

## 🌐 Source & Issues

* GitHub: [https://github.com/infocyph/docker-runner](https://github.com/infocyph/docker-runner)
* Issues: [https://github.com/infocyph/docker-runner/issues](https://github.com/infocyph/docker-runner/issues)

