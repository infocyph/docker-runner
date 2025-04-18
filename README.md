# 🚀 Docker Runner (Supervisor Service)

[![Docker Publish](https://github.com/infocyph/docker-runner/actions/workflows/docker.publish.yml/badge.svg)](https://github.com/infocyph/docker-runner/actions/workflows/docker.publish.yml)

A lightweight, Alpine-based Docker image designed to run and manage containers or long-running processes using **Supervisor**, with built-in support for:

- `docker exec` wrappers (`pexe` & `dexe`)
- Scheduled log rotation via `logrotate`
- Cron support via `cronie`
- Clean log management for scalable environments

---

## 📦 Available on Registries

| Registry         | Image Name                  |
|------------------|-----------------------------|
| Docker Hub       | `docker.io/infocyph/runner` |
| GitHub Container | `ghcr.io/infocyph/runner`   |

---

## 💪 Executables

### `dexe`

Run any command inside a container:

```sh
$ dexe <container_name> <command> [...args]
```

Example:

```sh
$ dexe my-app echo "Hello from inside"
```

### `pexe`

Run PHP inside a container:

```sh
$ pexe <container_name> <php_script.php> [...args]
```

Example:

```sh
$ pexe my-php-app artisan migrate
```

---

## 🔄 Log Rotation

> Set the `TZ` environment variable (for your desired timezone)
> ```bash
> TZ=Your_Desired_Timezone
> ```

You can mount **any directory inside `/global/log`** to have its `.log` files automatically rotated by the system.

```bash
-v $(pwd)/my-custom-logs:/global/log/my-app
```

### ✅ Log rotations are automatically handled

- Runs every `${LOGROTATE_INTERVAL}` seconds (default: `3600`, manageble using environment variable `LOGROTATE_INTERVAL`)
- Configs loaded from `/etc/logrotate.d/`
- Rotates all files in `/global/log/` (and subdirectories) that end with `.log`
- Mount your logs to `/global/log` to get rotated daily
- Mount your logs to `/global/movelog` to get rotated daily long with old logs getting moved to `/global/oldlogs`
- Rotated logs go to `/global/oldlogs` — make sure to persist this if you want to retain historical logs:
```bash
-v $(pwd)/oldlogs:/global/oldlogs
```

---

## 🌐 Usage
- Single command running container:
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
- Mount `/etc/supervisor/conf.d` to add Supervisor processes
> Example file: `my-task.conf`
> ```ini
> [program:my-task]
> command=/bin/sh -c 'echo Hello World && sleep 60'
> autostart=true
> autorestart=true
> stderr_logfile=/var/log/supervisor/my-task.err.log
> stdout_logfile=/var/log/supervisor/my-task.out.log
> 
> [program:schedular]
> command=pexe MY_PHP_CONTAINER artisan schedule:run
> autostart=true
> autorestart=true
> stderr_logfile=/var/log/supervisor/my-task.err.log
> stdout_logfile=/var/log/supervisor/my-task.out.log
> ```

- Mount `/etc/cron.d` to add cron jobs
> Example file: `my-cron`
>```cron
>* * * * * root echo "Cron ran at $(date)" >> /global/log/my-cron.log 2>&1
>```
- `/var/run/docker.sock` allows `pexe` and `dexe` to run commands inside other containers
---

## 📑 License

MIT © [infocyph](https://github.com/infocyph)

---

## 🌐 Source & Issues

- GitHub: [https://github.com/infocyph/docker-runner](https://github.com/infocyph/docker-runner)
- Issues: [Open an Issue](https://github.com/infocyph/docker-runner/issues)

