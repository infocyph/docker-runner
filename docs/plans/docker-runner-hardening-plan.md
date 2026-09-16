# docker-runner — Hardening, Quality & Release Plan

## Status

Planning branch: `plan/docker-runner-hardening`

Baseline:

- Repository: `infocyph/docker-runner`
- Default branch: `main`
- Current baseline release: `0.4.3`
- `main` currently matches release `0.4.3`
- Current base image: `alpine:latest`
- Primary ecosystem role: LocalDevStack background-process runner
- Standalone use remains a supported first-class mode
- Supervisor remains PID 1
- Default supervised services remain cron + logrotate

This plan follows the completed shared-foundation work in `infocyph/Scriptomatic` and `infocyph/Toolset` and supersedes older assumptions from the LocalDevStack master draft.

## Goal

Harden `docker-runner` into a small, predictable, observable and independently publishable infrastructure image while preserving its LocalDevStack role.

Runner has two equally valid operating profiles:

1. **LocalDevStack-integrated** — LocalDevStack mounts scheduler configuration, service logs and optionally the Docker socket into Runner.
2. **Standalone** — the image runs Supervisor + cron + logrotate by itself, with all mounts and Docker access optional.

LocalDevStack is the primary compatibility target, but LocalDevStack-specific orchestration must not be baked into the image.

Runner should continue to do four things well:

1. run Supervisor as PID 1;
2. run cron jobs;
3. rotate mounted logs;
4. execute commands in sibling/remote Docker containers through thin Docker CLI helpers when Docker access is deliberately provided.

It must not become a second `docker-tools` control plane or a generic application-runtime image.

---

# 1. Non-negotiable dependency policy

The following dependency choices are intentional and must not be "hardened" by pinning them away.

## 1.1 Alpine stays `latest`

The base image remains:

```dockerfile
FROM alpine:latest
```

Do **not** introduce `ALPINE_VERSION` and do not pin an Alpine minor/digest in the Dockerfile.

The purpose of scheduled Runner refreshes is partly to absorb the current Alpine stable base and its security/package updates.

Because this is intentionally mutable:

- CI must regularly rebuild with `--pull`;
- an upstream-canary build must detect Alpine/package breakage before publication where possible;
- release provenance/SBOM/digests become more important than source-level byte reproducibility;
- published release tags must never be overwritten after their first successful publish.

A release tag is therefore an **immutable published image artifact**, not a promise that rebuilding the same source later against moving `alpine:latest` produces identical bytes.

## 1.2 Scriptomatic stays full-SHA pinned

`Scriptomatic/main` is the canonical upstream, but Runner must consume `bash/banner.sh` from an explicit full commit SHA.

Use a build argument:

```text
SCRIPTOMATIC_REF=<40-character commit SHA>
```

and fetch:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/${SCRIPTOMATIC_REF}/bash/banner.sh
```

Rules:

- full SHA only;
- never `master`;
- do not consume a mutable Scriptomatic branch in release builds;
- validate the ref shape in the Docker build and/or CI;
- syntax-check the downloaded Bash script;
- Scriptomatic SHA changes remain explicit dependency-update commits.

## 1.3 Toolset follows the latest stable release

Toolset is intentionally **not pinned** in Runner.

Runner must install Toolset through the current stable-release installer contract:

```bash
curl -fsSLO "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"
bash install.sh chromacat
rm -f install.sh
```

For the Docker image, use the same contract but explicitly install into Runner's executable path:

```bash
curl -fsSLo /tmp/toolset-install.sh \
  "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"
bash /tmp/toolset-install.sh --prefix /usr/local/bin chromacat
rm -f /tmp/toolset-install.sh
```

The explicit prefix is important because Toolset's installer otherwise defaults to `~/.local/bin`, while Runner exposes `/usr/local/bin` in `PATH`.

Toolset's installer already downloads the selected release's `SHA256SUMS`, verifies the selected tool asset, runs shell syntax validation and checks `--version` before atomic installation.

Runner should install **only `chromacat`**. Do not install `--all` merely because Toolset supports it. Other Toolset utilities overlap other LocalDevStack/control-plane responsibilities and would unnecessarily enlarge Runner.

Rules:

- use `releases/latest/download/install.sh`;
- install latest stable Toolset intentionally;
- no raw `Toolset/main/...` downloads;
- no `TOOLSET_VERSION` build argument;
- verify `chromacat --version` after installation;
- CI must fail if raw mutable Toolset source consumption reappears.

## 1.4 Consequence: traceability over rebuild reproducibility

Runner intentionally combines:

- mutable `alpine:latest`;
- mutable Toolset latest stable release;
- immutable Scriptomatic full SHA;
- immutable Runner source release tag.

Therefore the release system must provide traceability:

- image digest;
- OCI source/revision/version metadata;
- BuildKit provenance;
- SBOM;
- logged Alpine version;
- logged installed Toolset/`chromacat` version;
- logged Scriptomatic SHA.

Do not describe this policy as fully reproducible. The correct property is **immutable publication + auditable build materials**.

---

# 2. Current repository review findings

The repository is intentionally small and was reviewed file-by-file.

## 2.1 Current release/source state

- branch `plan/docker-runner-hardening` is based directly on current `main`;
- `main` is identical to release `0.4.3`;
- before this plan, the branch adds documentation only;
- implementation can therefore be evaluated cleanly against the exact `0.4.3` runtime baseline.

## 2.2 Dockerfile findings

Current issues:

- `alpine:latest` is correct and must stay;
- Scriptomatic is fetched from stale mutable `master`;
- Toolset `chromacat` is fetched raw from mutable `main`;
- Docker remote `ADD` is being used for both helper downloads;
- remote helper downloads have no explicit failure/syntax contract in the Dockerfile;
- Toolset's new release installer is not used;
- world-writable log directories exist and need compatibility-driven review;
- package list contains presentation/locale dependencies that should be validated against actual helper behavior;
- current healthcheck checks every Supervisor process indirectly, including user-mounted programs.

## 2.3 Supervisor findings

Current core layout is sound:

- Supervisor is PID 1;
- root is appropriate for this infrastructure image;
- Unix control socket is local and mode `0700`;
- `cron` and `logrotate` are default programs;
- `/etc/supervisor/conf.d/*.conf` is a clean extension surface.

Hardening gaps:

- the healthcheck currently runs `supervisorctl status` with no process names; Supervisor returns non-zero if **any** managed process is not running, so a deliberately stopped or failed user-mounted program can mark the whole Runner container unhealthy even when Runner itself is healthy;
- Supervisor's own logfile rotation settings are not explicitly disabled even though external `logrotate` also owns `/var/log/supervisor/*.log`; one component should own rotation;
- shutdown/process-group behavior needs a real test, especially while the logrotate worker is sleeping or a cron job has children;
- current Cronie flags and README disagree.

## 2.4 Cron findings

Current command:

```text
/usr/sbin/crond -f -P -p
```

Cronie defines:

- `-f` as foreground mode;
- `-P` as preserve/inherit `PATH` instead of replacing it;
- `-p` as permitting user-set crontabs that would otherwise fail owner/type/mode restrictions.

`-p` is potentially important for LocalDevStack because scheduler files are bind-mounted from the host and may not present strict root ownership/mode semantics on every Docker host platform.

README currently documents BusyBox-style flags (`-l 2 -L /dev/stdout`) that do not describe this Cronie process and must be removed/reconciled.

Do not switch cron implementations during this hardening pass.

## 2.5 Logrotate worker findings

Current worker has the most significant runtime failure mode:

- `LOGROTATE_INTERVAL` is accepted without validation;
- `set -e` lets one bad logrotate config terminate the worker;
- Supervisor immediately restarts it because `autorestart=true`;
- a persistent config error can therefore cause a tight restart/log storm;
- fallback mode stops at the first failing fragment rather than attempting the remaining fragments;
- shutdown while Bash waits on `sleep` needs explicit testing.

## 2.6 Logrotate configuration findings

- `daily` covers `/global/log` with explicit glob depths rather than true recursive `**` semantics;
- README currently overstates the pattern as effectively recursive;
- `copytruncate` remains appropriate because Runner cannot signal/reopen arbitrary sibling service logs;
- `dailyold` remains a valid standalone compatibility feature but is not mounted by current LocalDevStack `companion.yaml`;
- Supervisor logs use `reopenlogs`, which is the correct model when logrotate moves Supervisor-owned files.

## 2.7 Helper findings

`dexe` and `pexe` are already small and structurally good:

- POSIX shell;
- safe quoted argv forwarding;
- no `eval`;
- TTY detection;
- `exec` preserves the Docker command's exit status.

They mainly need deterministic tests, not feature growth.

## 2.8 GitHub Actions findings

Current publish workflow needs substantial modernization:

- `actions/checkout@v4` is stale; current major is `v7`;
- Docker actions also have newer majors;
- release publication re-discovers the "latest release" instead of using the release event's exact tag;
- scheduled publication generates both release tag and `latest`, so it can overwrite an immutable release tag;
- there is no permanent PR/push image validation workflow;
- there is no Buildx cache setup;
- there is no explicit QEMU/multi-platform contract;
- there is no SBOM gate;
- current schedule `0 0 * * */2` is **not biweekly**. The fifth POSIX cron field is day-of-week; `*/2` steps within that field.

## 2.9 Repository metadata findings

- `.gitattributes` already contains `* text eol=lf`; this is stronger and simpler than adding per-extension LF rules. Keep it.
- `.dockerignore` is reasonable but should be revisited after tests are added.
- `.gitignore` needs no functional change unless tests create artifacts.
- README contains a malformed code fence in the `dexe` section.

---

# 3. Public behavior that must remain compatible

Unless a tested defect requires a deliberate change, preserve:

- image names `docker.io/infocyph/runner` and `ghcr.io/infocyph/runner`;
- `latest` as the primary LocalDevStack-consumed moving tag;
- immutable version/release tags for standalone/pinned consumers;
- Supervisor as PID 1;
- `/etc/supervisor/conf.d/*.conf` as the mounted Supervisor extension surface;
- `/etc/cron.d` as the mounted cron-job surface;
- `/global/log` as the normal log-rotation root;
- `/global/movelog` + `/global/oldlogs` as compatibility paths for standalone/existing users until separately deprecated;
- `/var/log/supervisor` as the Supervisor log path;
- `dexe` as a generic Docker `exec` wrapper;
- `pexe` as `docker exec ... php ...`;
- TTY auto-detection;
- exact argument forwarding;
- helper exit-code propagation;
- optional Docker socket/remote Docker access;
- root execution inside Runner.

The image must start and become healthy **without** `/var/run/docker.sock` mounted.

---

# 4. File-by-file implementation plan

## 4.1 `Dockerfile`

### Required changes

1. Keep:

   ```dockerfile
   FROM alpine:latest
   ```

   Do not add Alpine pinning arguments.

2. Add only the Scriptomatic dependency argument:

   ```dockerfile
   ARG SCRIPTOMATIC_REF=<full SHA>
   ```

   Validate that it is a 40-character lowercase/uppercase hex SHA before using it.

3. Stop using remote Dockerfile `ADD` for Scriptomatic/Toolset.

   Use explicit `curl -fsSL`/`curl -fsSLo` so download failure, destination and validation are obvious.

4. Install Scriptomatic `banner.sh` from `${SCRIPTOMATIC_REF}`.

   Requirements:

   - HTTPS;
   - fail build on download error;
   - non-empty result;
   - `bash -n` validation;
   - install mode `0755` as `/usr/local/bin/show-banner`.

5. Install latest stable Toolset `chromacat` through the release installer.

   Target pattern:

   ```bash
   curl -fsSLo /tmp/toolset-install.sh \
     "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"
   bash -n /tmp/toolset-install.sh
   bash /tmp/toolset-install.sh --prefix /usr/local/bin chromacat
   chromacat --version
   rm -f /tmp/toolset-install.sh
   ```

   No `TOOLSET_VERSION` argument.

6. Do not install all Toolset CLIs.

   `chromacat` is the only current Runner dependency. `cleanx`, `dockex`, `gitx`, `netx`, `phpx`, `sqlitex` stay out unless Runner later has a demonstrated direct use.

7. Review runtime packages against current helper code.

   Keep as required unless tests prove otherwise:

   - `bash`
   - `ca-certificates`
   - `supervisor`
   - `docker-cli`
   - `logrotate`
   - `cronie`
   - `tzdata`
   - `figlet` for the full Scriptomatic banner
   - terminal support needed by `chromacat` (`tput`/ncurses)

   Validate before deciding whether to keep/remove:

   - `curl` as a runtime package versus build-only dependency;
   - `musl-locales` versus a simpler locale contract;
   - `gawk` because `chromacat` intentionally has fallback AWK selection.

   Prefer correctness first, then image-size trimming. Do not remove packages speculatively.

8. Keep the profile banner hook but test all modes:

   - interactive shell shows it once;
   - non-interactive shell does not print it;
   - `NO_COLOR`/non-TTY behavior remains sane;
   - missing `figlet`/`chromacat` remains graceful by upstream design.

9. Review filesystem modes with LocalDevStack bind mounts.

   Required directories:

   ```text
   /var/log/supervisor
   /etc/supervisor/conf.d
   /etc/cron.d
   /global/log
   /global/movelog
   /global/oldlogs
   /var/lib/logrotate
   ```

   Current `0777` modes on `/global/log` and `/global/movelog` should only be tightened after Linux + Docker Desktop bind-mount behavior is tested. LocalDevStack service log directories are host mounts and compatibility takes priority over cosmetic permission tightening.

10. Keep direct Supervisor startup:

   ```dockerfile
   STOPSIGNAL SIGTERM
   CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
   ```

   Do not add an entrypoint merely to perform startup-time mutation.

11. Replace the broad healthcheck with a core-health contract, ideally via a small `runner-healthcheck` script or an explicit command that checks only Runner-owned programs (`cron`, `logrotate`) plus Supervisor connectivity.

   A user-mounted optional program must not make Runner unhealthy solely because that program is intentionally stopped.

12. Keep static OCI identity labels if useful, but supply release-specific source/revision/version labels from the publish workflow.

### Acceptance

- `alpine:latest` remains;
- Scriptomatic uses full SHA;
- Toolset installs from latest stable release installer;
- no raw Toolset `main` dependency;
- image starts without Docker socket;
- core health becomes healthy;
- banner works interactively without polluting non-interactive output.

---

## 4.2 `scripts/supervisord.conf`

### Preserve

- `nodaemon=true`;
- root execution;
- `/run/supervisor.sock` mode `0700`;
- `supervisorctl` through Unix socket;
- `cron` and `logrotate` default programs;
- `/etc/supervisor/conf.d/*.conf` include surface;
- program stdout/stderr directed to Docker streams.

### Hardening

1. Make Supervisor log ownership unambiguous.

   Because external `logrotate` owns `/var/log/supervisor/*.log`, explicitly disable Supervisor's own size-based rotation for `supervisord.log`:

   ```ini
   logfile_maxbytes=0
   logfile_backups=0
   ```

   Test this with real rotation/reopen behavior.

2. Preserve Cronie initially as:

   ```text
   /usr/sbin/crond -f -P -p
   ```

   Do not replace these flags with BusyBox examples.

3. Document why `-p` exists.

   It relaxes Cronie's normal owner/type/mode restrictions and may be necessary for LocalDevStack host-mounted cron files. This is a conscious compatibility/security tradeoff, not an accidental flag.

4. Test whether `-p` is still required on:

   - Linux Docker Engine;
   - Docker Desktop bind mounts where practical.

   Do not remove it in this release unless LocalDevStack compatibility proves strict mode works.

5. Do not claim Cronie logs directly to `/dev/stdout` unless the tested Cronie invocation actually provides that behavior. Cron jobs themselves should explicitly redirect useful output to Docker/mounted logs when needed.

6. Test process-group shutdown.

   If child leakage/delayed shutdown is reproduced, add `stopasgroup=true` and `killasgroup=true` to the affected Runner-owned programs. Prefer evidence over blanket settings.

7. Keep `autorestart=true` for core daemons, but ensure the logrotate worker itself handles ordinary configuration failures without exiting.

8. Verify mounted empty `/etc/supervisor/conf.d` remains harmless.

9. Verify malformed mounted Supervisor configuration fails visibly and predictably rather than producing an ambiguous health state.

---

## 4.3 `scripts/logrotate-worker.sh`

This remains the highest-priority runtime hardening target.

### Required behavior

1. Validate `LOGROTATE_INTERVAL` as a positive integer.

   - default `3600`;
   - invalid/zero/negative values produce a clear warning and fall back to default;
   - never allow accidental zero-second busy looping.

2. Validate `LOGROTATE_STATE_FILE`.

   - non-empty path;
   - create parent safely;
   - fail clearly if parent cannot be created/written.

3. Split one rotation pass into a function that can be called from tests.

4. Preserve primary behavior:

   - use `/etc/logrotate.conf` when present;
   - otherwise process non-hidden regular files in `/etc/logrotate.d`.

5. In fallback mode, attempt all config fragments and aggregate failures instead of stopping on the first one.

6. Make rotation/config failures **observable but non-fatal to the worker loop**.

   On failure:

   - print config/path and exit status to stderr;
   - record that the pass failed;
   - do not pretend success;
   - do not exit and trigger a Supervisor restart storm;
   - sleep before retrying.

7. Add bounded failure backoff.

   Ordinary success can use `LOGROTATE_INTERVAL`, but repeated config failure must not spin rapidly even if the configured interval is tiny. Use a sensible minimum failure retry delay (for example 60 seconds) or a small capped exponential backoff.

   Keep the mechanism simple and deterministic.

8. Reset failure backoff after a successful pass.

9. Handle TERM/INT cleanly.

   Test shutdown both while logrotate is running and while the worker is sleeping. If Bash/sleep signal behavior is insufficient, add a minimal trap/process-group solution.

10. Keep a single worker instance. Do not add locking/concurrency unless testing demonstrates overlapping runs are possible.

11. A one-shot mode such as `LOGROTATE_ONCE=1` or a private script argument may be added **only** if it materially simplifies deterministic CI. If added, document it as a diagnostic/test feature rather than the default runtime path.

### Acceptance

- bad optional logrotate fragment does not restart-loop the container;
- healthy fragments still receive an attempt in fallback mode;
- failure is visible in logs;
- worker retries in a bounded way;
- SIGTERM exits within the container shutdown budget.

---

## 4.4 `scripts/dexe.sh`

Keep the implementation intentionally small.

Required tests:

- missing container -> usage + exit 2;
- missing command -> usage + exit 2;
- non-TTY -> no `-it`;
- TTY -> `-it`;
- whitespace/shell metacharacters remain distinct argv, never re-evaluated;
- Docker exit code propagates;
- unusual Docker-valid container names remain correctly quoted;
- works with standard socket-backed Docker CLI;
- does not require a socket merely for Runner to start.

Do not turn `dexe` into LocalDevStack orchestration.

---

## 4.5 `scripts/pexe.sh`

Same quality rules as `dexe`.

Also test:

- `php` remains inserted as the executable inside the target container;
- all following args remain exact;
- PHP target exit code propagates.

Do not replace this compatibility helper with Toolset `phpx` during the hardening release. They solve different contracts and existing external scheduler configuration may use `pexe`.

---

## 4.6 `loggables/daily`

Current behavior should stay unless integration evidence requires change:

- daily rotation;
- seven rotations;
- `maxage 30`;
- `missingok`;
- `notifempty`;
- `copytruncate`;
- compression + delayed compression;
- date suffix;
- Docker-visible postrotate message.

Required work:

1. `logrotate -d` validation in CI.
2. Forced real rotation smoke test.
3. Verify current glob depths against LocalDevStack's mounted service logs.
4. Correct README wording: these are explicit glob depths, not unlimited recursive `**` traversal.
5. Add deeper patterns only if real LocalDevStack log paths require them.
6. Preserve `copytruncate`; Runner cannot safely reopen every sibling service log writer.
7. Keep missing service directories harmless.

---

## 4.7 `loggables/dailyold`

Current LocalDevStack `companion.yaml` does not mount `/global/movelog` or `/global/oldlogs`, but standalone/existing consumers may still use them.

For this release:

- retain the config;
- test it;
- document it as legacy/optional compatibility behavior;
- do not remove it silently.

A future removal requires an explicit deprecation cycle.

---

## 4.8 `loggables/supervisord`

Required work:

- debug validation;
- forced rotation test;
- verify `supervisorctl ... reopenlogs` succeeds;
- verify new writes continue after rotation;
- verify creation mode/ownership;
- ensure Supervisor's own internal logfile rotation has been disabled so two rotation mechanisms do not compete;
- keep Docker-visible postrotate diagnostic.

---

## 4.9 New `scripts/runner-healthcheck.sh` — recommended

A dedicated tiny healthcheck script is preferable to a broad inline `supervisorctl status`.

Contract:

- verify Supervisor control socket responds;
- verify Runner-owned `cron` is RUNNING;
- verify Runner-owned `logrotate` is RUNNING;
- ignore state of arbitrary user-mounted Supervisor programs;
- no network dependency;
- no Docker socket dependency;
- fast bounded execution;
- exit 0/1 only, with optional useful stderr for manual execution.

This gives stable image health while still allowing Supervisor to manage user workloads independently.

---

# 5. Test layout

Add repository-native tests rather than embedding all behavior in workflow YAML.

Suggested layout:

```text
tests/
├── assertions.sh
├── static.sh
├── dependency-contract.sh
├── helpers-smoke.sh
├── supervisor-smoke.sh
├── cron-smoke.sh
├── logrotate-smoke.sh
├── standalone-smoke.sh
└── localdevstack-contract.sh
```

## `tests/assertions.sh`

Small dependency-free assertion functions.

## `tests/static.sh`

- `sh -n` for POSIX scripts;
- `bash -n` for Bash scripts;
- required files/executable modes;
- no CRLF;
- expected Supervisor/logrotate paths.

## `tests/dependency-contract.sh`

Enforce:

- `FROM alpine:latest` remains;
- no Alpine version pin is introduced accidentally;
- Scriptomatic URL contains `${SCRIPTOMATIC_REF}` and not `master`;
- Scriptomatic ref validation exists;
- Toolset uses `releases/latest/download/install.sh`;
- no raw Toolset `main` download;
- Toolset installs only `chromacat` into `/usr/local/bin`;
- no stale `TOOLSET_VERSION` pin.

## `tests/helpers-smoke.sh`

Use a fake Docker executable for deterministic argv/TTY/exit-code tests.

Also run at least one real Docker integration case in CI.

## `tests/supervisor-smoke.sh`

Against a built image:

- Supervisor PID 1;
- core programs running;
- healthcheck healthy;
- empty mounted conf directory works;
- sample mounted Supervisor program starts;
- stopping the sample program does not make core Runner health fail;
- clean SIGTERM shutdown.

## `tests/cron-smoke.sh`

Mount a real `/etc/cron.d` file and verify execution.

Test:

- host-style ownership/permissions relevant to LocalDevStack;
- required final newline;
- CRLF failure/documentation path;
- inherited PATH behavior from `-P`;
- timezone behavior with `TZ`.

## `tests/logrotate-smoke.sh`

- debug-validate all bundled configs;
- real forced rotation;
- state file updates;
- Supervisor reopen;
- invalid-fragment bounded failure;
- remaining fallback fragments still attempted;
- worker clean shutdown while sleeping.

## `tests/standalone-smoke.sh`

Start Runner with no LocalDevStack mounts and no Docker socket.

Verify:

- healthy;
- cron/logrotate alive;
- helper binaries present;
- calling Docker-dependent helper fails normally only when invoked;
- no startup dependence on external services.

## `tests/localdevstack-contract.sh`

Model the current LocalDevStack Runner shape without turning this repository into LocalDevStack.

Verify compatibility with:

- read-only `/etc/supervisor/conf.d` bind mount;
- read-only `/etc/cron.d` bind mount;
- writable `/var/log/supervisor`;
- multiple service directories mounted under `/global/log/<service>`;
- Docker socket mounted for scheduler/helper execution;
- Runner attached as a normal Compose service rather than requiring special capabilities.

The test may use fixtures that reproduce the LocalDevStack contract. A release gate should additionally test against current LocalDevStack itself.

---

# 6. Permanent CI

Add `.github/workflows/check.yml`.

## 6.1 Triggers

- pull requests;
- pushes to active branches/main as appropriate;
- optional manual dispatch.

Keep publishing separate from validation.

## 6.2 Static quality gates

- shell syntax;
- ShellCheck;
- actionlint;
- Dockerfile/BuildKit validation (`buildx --check` where supported);
- optional Hadolint if its rules are configured intentionally rather than blindly;
- dependency-contract tests;
- README/config consistency checks for critical commands.

## 6.3 Real image gates

Build the actual image and verify:

1. image builds;
2. Supervisor is PID 1;
3. core health becomes healthy;
4. cron RUNNING;
5. logrotate RUNNING;
6. `dexe`, `pexe`, `show-banner`, `chromacat` exist;
7. `chromacat --version` works;
8. interactive banner behavior;
9. mounted Supervisor config behavior;
10. cron job execution;
11. log rotation;
12. shutdown.

## 6.4 Latest-upstream canary

Because Alpine and Toolset intentionally float, add a scheduled validation job/workflow that performs a **fresh** build:

- `--pull`;
- avoid stale layer reuse for dependency-fetch steps (`--no-cache` where needed for the canary);
- install current Toolset latest stable;
- run full core smoke tests;
- print resolved `/etc/alpine-release`;
- print `chromacat --version`;
- print Scriptomatic SHA.

This canary must not publish images.

A weekly canary is sufficient unless upstream churn proves a need for more frequent checks.

## 6.5 Multi-architecture quality gate

Runner is used through Docker Desktop as well as Linux Docker Engine, so support:

```text
linux/amd64
linux/arm64
```

Validate at least:

- full native `amd64` runtime smoke on GitHub-hosted runner;
- successful `arm64` image build via QEMU/Buildx;
- preferably a minimal arm64/QEMU startup smoke if reliable enough.

Do not claim multi-arch support until both package/tool dependencies build on arm64.

---

# 7. GitHub Actions modernization

Use current action majors reviewed during this plan update:

- `actions/checkout@v7`
- `docker/login-action@v4`
- `docker/metadata-action@v6`
- `docker/setup-buildx-action@v4`
- `docker/setup-qemu-action@v4` when multi-arch is enabled
- `docker/build-push-action@v7`
- `actions/attest@v4` for new attestation implementation rather than starting new usage of the older provenance wrapper

Do not freeze this list forever. At implementation time, re-check current stable majors and use the newest supported versions.

Add `.github/dependabot.yml` for weekly `github-actions` updates so workflow actions do not silently age again.

Use least-required workflow permissions.

---

# 8. `.github/workflows/docker.publish.yml`

Replace the current workflow rather than incrementally preserving its problematic tag logic.

## 8.1 Release-event behavior

For `release: published`:

- use `github.event.release.tag_name` directly;
- checkout that exact tag;
- build from that source;
- run pre-publish runtime smoke;
- publish the release tag;
- publish/update `latest`;
- never look up some other "latest release" for a release-event build.

## 8.2 Scheduled-refresh behavior

Scheduled refresh exists because Alpine + Toolset latest move independently of Runner source.

For schedule:

1. resolve the current latest Runner release tag;
2. checkout that immutable Runner source;
3. fresh-build it against current `alpine:latest` and current Toolset stable latest;
4. run the full pre-publish smoke suite;
5. publish/update **only `latest`**;
6. never publish/overwrite the version tag.

This lets `latest` receive upstream base/tool fixes without mutating historical release artifacts.

## 8.3 Fix the fake biweekly cron

Current:

```cron
0 0 * * */2
```

is not an every-two-weeks schedule.

GitHub Actions uses standard five-field POSIX cron; there is no native "every 2 weeks" field.

Use one of these explicit strategies:

- schedule weekly on one weekday and guard the publish job by ISO week parity; **preferred** because it is deterministic;
- or intentionally choose a simpler weekly refresh if ecosystem policy changes.

Do not use the current day-of-week step expression and call it biweekly.

## 8.4 Build/publish architecture

Recommended sequence:

1. checkout exact source;
2. set up QEMU if multi-arch;
3. set up Buildx;
4. build an `amd64` candidate locally (`--load`) for smoke testing;
5. only after smoke succeeds, build/push the multi-platform manifest;
6. emit OCI metadata;
7. emit provenance + SBOM;
8. attest the published digest(s).

This prevents pushing an image that has only passed Dockerfile syntax but never actually booted.

## 8.5 Image naming

This repository is specifically Runner. Prefer a simple explicit image identity:

```text
runner
```

over dynamically deriving it with `sed` unless ecosystem-wide reuse is a real requirement.

Less workflow magic improves auditability.

## 8.6 Cache and concurrency

Add:

- Buildx GitHub Actions cache;
- publish concurrency group;
- `cancel-in-progress: false` for release publication;
- sensible timeout;
- no duplicate checkout unless the workflow genuinely needs two refs.

## 8.7 Supply-chain metadata

Publish:

- OCI source URL;
- source revision;
- release version;
- created timestamp;
- licenses/description;
- BuildKit provenance (`mode=max` where compatible);
- SBOM.

Where useful, log resolved Alpine and Toolset versions to the workflow summary.

---

# 9. LocalDevStack integration contract

LocalDevStack is the primary ecosystem consumer and must receive explicit release-gate attention.

Current `LocalDevStack/main` Runner service uses:

```text
image: infocyph/runner:latest
```

and mounts:

- `configuration/scheduler/supervisor` -> `/etc/supervisor/conf.d:ro`;
- `configuration/scheduler/cron-jobs` -> `/etc/cron.d:ro`;
- `logs/runner` -> `/var/log/supervisor`;
- many service log directories -> `/global/log/<service>`;
- `/var/run/docker.sock` -> `/var/run/docker.sock`.

It currently does **not** mount `/global/movelog`, `/global/oldlogs`, or persistent `/var/lib/logrotate` state.

## 9.1 `latest` is a compatibility promise

Do not automatically change LocalDevStack to a pinned Runner release as part of this repository hardening.

LocalDevStack currently intentionally consumes `runner:latest`. Therefore every moving `latest` publication must remain backward compatible with the established mount/config contract.

Standalone users who need fixed artifacts can use immutable Runner release tags/digests.

## 9.2 Logrotate state decision

Current LocalDevStack does not persist `/var/lib/logrotate` separately.

This means state survives a container restart but not replacement/recreation.

After Runner hardening, evaluate in LocalDevStack whether a small named volume/bind for logrotate state is beneficial. This is a LocalDevStack orchestration decision, not something Runner should force.

## 9.3 Docker socket boundary

LocalDevStack deliberately mounts the Docker socket because scheduler jobs/helper wrappers may need sibling-container execution.

Runner itself must:

- work without the socket;
- never mount/provision the socket itself;
- document the privilege implication clearly.

## 9.4 LocalDevStack release gate

Before publishing a new Runner release/latest behavior:

1. start Runner with the current LocalDevStack-equivalent mount layout;
2. verify default empty scheduler directories work;
3. add representative Supervisor and cron fixtures;
4. exercise sibling-container execution through Docker socket;
5. exercise several mounted service-log paths;
6. verify LocalDevStack timezone propagation;
7. verify shutdown/restart behavior;
8. confirm no new required env var, capability, network, volume or writable mount was introduced.

A full LocalDevStack end-to-end smoke against current `main` should be performed for the release candidate where practical.

Do not couple this work to unrelated LocalDevStack networking/static-IP changes.

---

# 10. Standalone contract

Standalone Runner must remain easy to use:

```bash
docker run -d --name runner infocyph/runner:latest
```

That container must become healthy with no Docker socket and no extra mounts.

Optional standalone capabilities:

- mount `/etc/supervisor/conf.d:ro` for additional processes;
- mount `/etc/cron.d:ro` for jobs;
- mount `/global/log` for log rotation;
- persist `/var/lib/logrotate` if state across container replacement matters;
- mount Docker socket or set a remote Docker CLI environment only when `dexe`/`pexe` are required.

Do not make LocalDevStack hostnames, networks, container names or paths outside Runner's public mount contract mandatory.

---

# 11. Security and privilege boundaries

Runner is intentionally privileged infrastructure, but privilege should be explicit and limited to its job.

## Keep

- root inside container;
- Docker CLI because `dexe`/`pexe` are public helpers;
- Cronie's currently permissive `-p` mode until LocalDevStack bind-mount compatibility proves it removable.

## Do not bake in

- Docker socket;
- host filesystem paths;
- extra Linux capabilities;
- privileged container mode;
- Docker daemon configuration;
- SSH keys/secrets;
- application runtimes.

## Document

Mounting `/var/run/docker.sock` effectively gives Runner strong control over the Docker host. It is optional for cron/logrotate/Supervisor-only standalone usage.

Read-only mounts should be used for scheduler configuration where possible.

## Supply-chain posture

Because Alpine/Toolset are intentionally latest:

- use HTTPS only;
- use Toolset's release installer, never raw branch scripts;
- retain Scriptomatic SHA pin;
- publish provenance/SBOM;
- keep historical version tags immutable;
- regularly fresh-build in CI.

---

# 12. README rewrite requirements

Update README only after behavior is implemented and tested.

Required corrections/additions:

- describe the dual role: LocalDevStack subsystem + standalone image;
- describe Supervisor as PID 1;
- document core-only health semantics;
- replace stale Cronie flags with the actual tested command;
- explain `-P` and `-p` at a practical level;
- do not promise Cronie daemon logs to stdout unless verified;
- document `LOGROTATE_INTERVAL` validation/failure behavior;
- document `LOGROTATE_STATE_FILE` and persistence-on-recreation considerations;
- document explicit logrotate glob depth instead of implying arbitrary recursion;
- mark `/global/movelog` + `/global/oldlogs` as optional/legacy-compatible if retained;
- document Docker socket as optional and high privilege;
- document `dexe`/`pexe` exact roles;
- show standalone usage without socket first;
- show LocalDevStack-style usage separately;
- document Toolset/Alpine moving dependency policy at a concise user-relevant level;
- distinguish immutable release tags from moving `latest`;
- mention `linux/amd64` + `linux/arm64` only after validated/published;
- fix the malformed `dexe` code fence;
- keep orchestration-specific detail in LocalDevStack docs rather than duplicating the full stack manual.

---

# 13. Repository support files

## `.dockerignore`

Revisit after adding tests.

Keep build context minimal:

- repository metadata/docs/tests can stay excluded if Docker build does not need them;
- do not exclude any source copied by Dockerfile;
- avoid unnecessary generic entries that imply ecosystems not present, but cleanup is optional.

## `.gitattributes`

Current:

```text
* text eol=lf
```

is already correct for this shell/config-heavy repository and Windows contributors. Preserve it.

Do not replace it with a more verbose per-extension policy without a real need.

## `.gitignore`

No functional change expected except any deliberate local test artifacts.

## `LICENSE`

No change.

## `.github/dependabot.yml` — new

Add GitHub Actions update monitoring:

```text
package-ecosystem: github-actions
schedule: weekly
```

This supports the project's policy of staying on modern action majors.

Do not use Dependabot to "fix" `alpine:latest`; that moving tag is intentional.

---

# 14. Quality and feature upgrades

## 14.1 Implement in this hardening cycle

These add meaningful value without changing Runner's mission:

1. core-only healthcheck;
2. bounded logrotate failure behavior;
3. complete shell/config/image smoke suite;
4. latest-upstream canary;
5. actual biweekly publication semantics;
6. immutable historical tags + moving `latest`;
7. multi-arch build target (`amd64` + `arm64`) if smoke passes;
8. SBOM + provenance;
9. LocalDevStack contract smoke;
10. standalone no-socket smoke;
11. current GitHub Actions majors + Dependabot.

## 14.2 Good future features, but defer unless implementation proves trivial

### `runner-doctor`

A read-only diagnostic helper could validate:

- Supervisor config parse/connectivity;
- logrotate configs;
- CRLF/final-newline issues in cron files;
- writable log/state paths;
- Docker CLI/socket reachability when requested;
- installed dependency versions.

This would be useful for both LocalDevStack troubleshooting and standalone users, but it must remain optional and lightweight.

### `runner-reload`

A helper could perform safe:

```text
supervisorctl reread
supervisorctl update
```

and possibly signal cron when required.

Do not add automatic filesystem watchers merely for this; mounted config reload should stay explicit.

### Strict Cronie mode

A future opt-in mode could remove `-p` for users who guarantee root-owned strict cron files.

Do not make strict mode the default until LocalDevStack host-mount behavior is proven across supported platforms.

### Build-info command/file

A tiny static `/etc/runner-build-info` or `runner-version` output could expose:

- Runner source version/revision;
- resolved Alpine version;
- Scriptomatic SHA;
- installed `chromacat` version.

This is especially valuable because Alpine and Toolset float. Prefer build metadata/provenance first; add a runtime helper only if operational debugging benefits justify it.

## 14.3 Explicitly rejected feature growth

Do not add Toolset `--all`, PHP, Node, databases, web servers, queue brokers, a Docker control plane, config watchers, metrics stacks or another init system to Runner.

---

# 15. Implementation order

## Phase 1 — Validation foundation

1. add repository-native tests;
2. add permanent `check.yml`;
3. add actionlint/ShellCheck/dependency gates;
4. make baseline `0.4.3` behavior measurable before changing it.

## Phase 2 — Dependency modernization

1. keep `alpine:latest`;
2. replace Scriptomatic `master` with full SHA;
3. replace raw Toolset `main` file with latest stable installer;
4. use `--prefix /usr/local/bin chromacat`;
5. add latest-dependency contract tests.

## Phase 3 — Runtime hardening

1. harden logrotate worker;
2. add core-only healthcheck;
3. disable competing Supervisor logfile rotation;
4. validate Cronie flags and mounted-file behavior;
5. test helper wrappers;
6. validate all logrotate fragments.

## Phase 4 — Dual-mode image smoke

1. standalone no-mount/no-socket startup;
2. mounted Supervisor test;
3. mounted cron test;
4. forced logrotate test;
5. Docker helper integration;
6. LocalDevStack-equivalent mount test;
7. shutdown/restart test.

## Phase 5 — Architecture and supply chain

1. validate amd64;
2. validate arm64/QEMU;
3. enable multi-platform build if green;
4. add SBOM/provenance;
5. add fresh-upstream canary.

## Phase 6 — Publishing modernization

1. move to current action majors;
2. release event uses event tag directly;
3. scheduled refresh uses latest release source;
4. scheduled refresh updates only `latest`;
5. fix biweekly scheduling semantics;
6. add cache/concurrency/timeouts;
7. smoke before push;
8. keep historical release tags immutable.

## Phase 7 — Documentation and ecosystem gate

1. rewrite README to tested truth;
2. final standalone smoke;
3. final LocalDevStack current-main compatibility smoke;
4. release Runner;
5. no LocalDevStack source change unless integration testing identifies a real required follow-up.

---

# 16. Release strategy

Do not choose a new semantic version until implementation shows whether public behavior changed incompatibly.

Hardening CI, dependency delivery, multi-arch publication and failure handling do not automatically require a major version.

Release requirements:

- all static tests green;
- fresh `alpine:latest` build green;
- Toolset latest installer green;
- Scriptomatic full-SHA contract green;
- standalone smoke green;
- LocalDevStack contract smoke green;
- real cron execution green;
- real logrotate green;
- bounded invalid-config behavior green;
- clean SIGTERM shutdown green;
- amd64 green;
- arm64 build/smoke green before advertising arm64;
- Docker Hub + GHCR publish from the same build definition;
- SBOM/provenance generated;
- historical release tag not mutable by schedule;
- `latest` updated only after all publish gates pass.

---

# 17. Explicit non-goals

Do **not** use this hardening pass to:

- pin Alpine away from `latest`;
- pin Toolset away from latest stable;
- install all Toolset tools;
- move LocalDevStack orchestration into Runner;
- make LocalDevStack mandatory for standalone operation;
- add PHP/Node/application runtimes;
- replace Supervisor;
- replace Cronie;
- remove Docker CLI while `dexe`/`pexe` remain public;
- require Docker socket at startup;
- remove legacy log paths without deprecation/usage proof;
- solve unrelated LocalDevStack networking changes;
- introduce a framework for a handful of shell scripts.

Keep Runner small, observable and boring.

---

# 18. Final acceptance criteria

The hardening work is complete when all of the following are true:

1. `FROM alpine:latest` remains intentionally.
2. Fresh `--pull` image build succeeds.
3. Scriptomatic is fetched using a validated full commit SHA.
4. No Scriptomatic `master` dependency remains.
5. Toolset is installed through `releases/latest/download/install.sh`.
6. Toolset installs only `chromacat` into `/usr/local/bin`.
7. No raw Toolset `main` dependency remains.
8. `chromacat --version` passes in the image.
9. Shell syntax and ShellCheck pass.
10. Workflow syntax/actionlint pass.
11. Supervisor remains PID 1.
12. Supervisor external logrotate ownership is unambiguous.
13. Core health checks only Runner-owned core services.
14. An intentionally stopped mounted Supervisor program does not falsely mark Runner core unhealthy.
15. Cronie invocation is tested and README matches it.
16. LocalDevStack host-mounted cron files execute under the supported permission model.
17. Invalid `LOGROTATE_INTERVAL` cannot cause a busy loop.
18. Invalid logrotate configuration cannot create a Supervisor restart storm.
19. Fallback logrotate mode attempts remaining fragments after one failure.
20. Failure retry behavior is bounded.
21. All bundled logrotate configs validate.
22. Forced `/global/log` rotation passes.
23. Supervisor logs remain writable after rotation/reopen.
24. `dexe` preserves argv, TTY behavior and exit codes.
25. `pexe` preserves argv, TTY behavior and exit codes.
26. Image starts and becomes healthy with no Docker socket.
27. Image works with Docker socket when helpers are exercised.
28. SIGTERM produces clean bounded shutdown.
29. Current LocalDevStack mount layout remains compatible.
30. `/global/movelog`/`/global/oldlogs` remain compatible for standalone/existing users or are explicitly deferred for later deprecation.
31. `linux/amd64` image passes runtime smoke.
32. `linux/arm64` builds and passes the agreed smoke before multi-arch is advertised.
33. GitHub Actions use current supported majors at implementation time.
34. Release event publishes its exact event tag + `latest`.
35. Scheduled refresh publishes only `latest`.
36. Scheduled refresh is truly biweekly (or deliberately changed to a clearly documented cadence), not `*/2` in day-of-week.
37. Published version tags are never overwritten.
38. Buildx cache/concurrency/timeouts are configured.
39. SBOM and provenance are produced.
40. Resolved Alpine/Toolset/Scriptomatic build information is observable in CI/provenance.
41. README accurately documents standalone and LocalDevStack modes.
42. `.gitattributes` global LF policy remains intact.
43. Runner remains narrowly scoped to Supervisor + cron + logrotate + Docker exec helpers + presentation helper.
