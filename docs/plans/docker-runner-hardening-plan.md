# docker-runner — Hardening & Release Plan

## Status

Planning branch: `plan/docker-runner-hardening`

Baseline:

- Repository: `infocyph/docker-runner`
- Default branch: `main`
- Current baseline release: `0.4.3`
- Current base image: `alpine:latest`
- Runtime role: LocalDevStack background-process runner
- Supervisor remains PID 1
- Default supervised services remain cron + logrotate

This plan follows the completed shared-foundations work in `infocyph/Scriptomatic` and `infocyph/Toolset`.

## Goal

Harden `docker-runner` as a small, predictable, independently publishable LocalDevStack infrastructure image without broadening its responsibility.

The runner should continue to do four things well:

1. run Supervisor as PID 1;
2. run cron jobs;
3. rotate mounted LocalDevStack logs;
4. execute commands in sibling containers through the Docker CLI when LocalDevStack deliberately mounts the Docker socket.

It must not become a second `docker-tools` control plane.

---

# 1. Foundation contracts already completed

The old ecosystem draft assumed we still needed to design how runner consumes Scriptomatic and Toolset. That foundation is now settled and this plan must follow it.

## Scriptomatic

`Scriptomatic/main` is the canonical distribution source, but reproducible downstream Docker builds may pin a full Scriptomatic commit SHA in the raw URL.

For this image, use an explicit build argument such as:

```text
SCRIPTOMATIC_REF=<full commit SHA>
```

and fetch `bash/banner.sh` from that exact ref.

Do not use `master`.

Do not independently invent a Scriptomatic tag/release dependency because Scriptomatic intentionally does not require releases.

## Toolset

Toolset now has a stable `2.0` release contract with release assets, `SHA256SUMS`, and a checksum-verifying installer.

For reproducible runner builds, consume `chromacat` from an exact stable Toolset release, initially `2.0`, using the supported installer/release-asset contract.

Suggested build argument:

```text
TOOLSET_VERSION=2.0
```

Preferred installation pattern:

```text
https://github.com/infocyph/Toolset/releases/download/${TOOLSET_VERSION}/install.sh
```

Verify the installer itself with that release's `SHA256SUMS`, then install only `chromacat` into `/usr/local/bin`.

Do not consume `Toolset/main/...` raw files.

## Dependency update policy

- Scriptomatic SHA changes are deliberate dependency-update commits.
- Toolset version changes are deliberate dependency-update commits.
- CI must fail if mutable `Scriptomatic/master`, mutable Toolset `main`, or unverified Toolset release downloads reappear.

---

# 2. Public behavior that must remain compatible

The hardening work must preserve these established contracts unless testing proves one is broken and we explicitly change it:

- image names remain `docker.io/infocyph/runner` and `ghcr.io/infocyph/runner`;
- Supervisor remains PID 1;
- `/etc/supervisor/conf.d/*.conf` remains the extension surface for mounted Supervisor programs;
- `/etc/cron.d` remains the mounted cron-job surface;
- `/global/log` remains the normal log-rotation root;
- `/global/movelog` + `/global/oldlogs` remain supported until LocalDevStack usage proves them obsolete;
- `/var/log/supervisor` remains the Supervisor log path;
- `dexe` remains the generic `docker exec` wrapper;
- `pexe` remains the PHP-specific `docker exec ... php` wrapper;
- TTY auto-detection remains;
- helper exit codes must continue to propagate;
- Docker socket access remains an orchestration choice, not an image assumption;
- root execution remains acceptable because cron, logrotate, Supervisor and optional Docker-socket access are privileged infrastructure responsibilities.

---

# 3. File-by-file implementation plan

## 3.1 `Dockerfile`

### Current concerns

The current image:

- uses mutable `alpine:latest`;
- downloads `Scriptomatic/master/bash/banner.sh` directly;
- downloads `Toolset/main/ChromaCat/chromacat` directly;
- does not validate those remote artifacts;
- has no build-time dependency contract verification;
- combines runtime package setup and mutable remote helper retrieval in one image build.

### Planned changes

1. Add explicit base-image control.

   Introduce an Alpine version build argument and use a supported explicit Alpine minor rather than an unbounded floating `latest` for release builds.

   Example shape:

   ```dockerfile
   ARG ALPINE_VERSION=<supported-minor>
   FROM alpine:${ALPINE_VERSION}
   ```

   The exact Alpine version should be selected during implementation after build/runtime compatibility testing.

2. Add foundation dependency arguments.

   ```text
   ARG SCRIPTOMATIC_REF=<full SHA>
   ARG TOOLSET_VERSION=2.0
   ```

3. Install Scriptomatic `banner.sh` from the pinned SHA.

   - use HTTPS with `curl -fsS...`;
   - fail the build on download failure;
   - syntax-check the resulting script where practical;
   - install it as `/usr/local/bin/show-banner`.

4. Install Toolset `chromacat` through the stable release contract.

   - download the exact `${TOOLSET_VERSION}` release installer + `SHA256SUMS`;
   - verify `install.sh` before execution;
   - invoke the installer for `chromacat` only;
   - install into `/usr/local/bin`;
   - verify `chromacat --version` or its documented machine-readable version contract;
   - remove installer/checksum temporary files afterward.

5. Review package list against real usage.

   Keep required packages:

   - `bash`
   - `curl`
   - `ca-certificates`
   - `supervisor`
   - `docker-cli`
   - `logrotate`
   - `cronie`
   - `tzdata`
   - presentation dependencies required by `show-banner` / `chromacat`

   Verify before retaining/removing:

   - `figlet`
   - `ncurses`
   - `musl-locales`
   - `gawk`

   No package should be removed based only on appearance; validate helper/runtime behavior first.

6. Keep the current filesystem contract but tighten permissions.

   Required directories include:

   ```text
   /var/log/supervisor
   /etc/supervisor/conf.d
   /etc/cron.d
   /global/log
   /global/movelog
   /global/oldlogs
   /var/lib/logrotate
   ```

   Avoid world-writable directories unless a mounted LocalDevStack workload demonstrably requires them. The existing `0777` on `/global/log` and `/global/movelog` must be reviewed against actual writer UID/GID behavior before changing it.

7. Preserve:

   ```dockerfile
   HEALTHCHECK ... supervisorctl ... status
   STOPSIGNAL SIGTERM
   CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
   ```

8. Add OCI build metadata through the publish workflow rather than hard-coding release-specific labels.

9. Do not add an ENTRYPOINT unless a real initialization requirement appears. The current direct Supervisor CMD is simpler and should remain the default.

### Acceptance

- reproducible dependency sources;
- no Toolset `main` raw dependency;
- no Scriptomatic `master` dependency;
- real image build passes;
- Supervisor remains PID 1;
- healthcheck reaches healthy state.

---

## 3.2 `scripts/supervisord.conf`

### Preserve

- `nodaemon=true`;
- Supervisor running as root;
- Unix control socket at `/run/supervisor.sock`;
- `supervisorctl` using that socket;
- `cron` and `logrotate` as default managed programs;
- include surface `/etc/supervisor/conf.d/*.conf`;
- child stdout/stderr directed to Docker streams.

### Planned validation/hardening

1. Validate the exact cron invocation on the selected Alpine/Cronie version.

   Current config runs:

   ```text
   /usr/sbin/crond -f -P -p
   ```

   while README currently documents a different invocation (`-f -l 2 -L /dev/stdout`). Do not arbitrarily switch flags. Determine the intended behavior from real Cronie options and smoke tests, then make config + docs identical.

2. Verify `/etc/supervisor/conf.d/*.conf` behaves cleanly when the mounted directory is empty.

3. Validate Supervisor shutdown behavior when it owns long-running children.

4. Add `stopasgroup=true` / `killasgroup=true` only if tests demonstrate child-process leakage during container shutdown. Do not add them speculatively.

5. Confirm restart policy for `logrotate` does not create a tight restart loop after a configuration failure; most of that should be solved inside the worker itself.

6. Do not add application-specific programs to the image. Project workers/schedulers belong in mounted LocalDevStack Supervisor definitions.

---

## 3.3 `scripts/logrotate-worker.sh`

This script needs the most behavioral hardening in the repository.

### Problems to address

- `LOGROTATE_INTERVAL` is trusted as-is;
- zero/non-numeric/negative values can lead to errors or undesirable loops;
- with `set -e`, one bad logrotate configuration can terminate the worker before the sleep point;
- Supervisor then restarts it immediately, which can create a noisy tight failure loop;
- fallback mode processes fragments independently but has no explicit aggregated failure strategy.

### Planned changes

1. Validate `LOGROTATE_INTERVAL` as a positive integer.

   - retain default `3600`;
   - reject/normalize invalid values with a clear warning;
   - never allow a zero-second busy loop.

2. Validate `LOGROTATE_STATE_FILE` parent directory and create it safely.

3. Split one rotation pass into a small function so it can be tested independently.

4. Prefer `/etc/logrotate.conf` when it exists, as today.

5. Preserve per-file fallback over `/etc/logrotate.d/*` when the main config is absent.

6. Make configuration failures observable but bounded.

   Target behavior:

   - emit the failed config and exit status to stderr;
   - do not silently mark failure as success;
   - do not let one invalid optional fragment cause a rapid Supervisor restart storm;
   - sleep the configured interval before retrying unless the worker cannot initialize at all.

7. Keep one worker instance; do not add concurrency machinery unless a test demonstrates overlapping execution can occur.

8. Preserve state-file use across passes.

9. Add a one-shot/testing mode only if it materially simplifies reliable CI; do not expose extra runtime flags without a reason.

---

## 3.4 `scripts/pexe.sh`

Current implementation is already small and structurally sound.

### Planned work

- keep POSIX `sh`;
- preserve argument-array forwarding (`"$@"`);
- preserve TTY auto-detection;
- preserve `exec` so Docker's exit code becomes the helper exit code;
- validate missing-container and missing-command errors;
- verify names containing unusual but Docker-valid characters are safely passed;
- add unit/smoke coverage using a fake `docker` binary so quoting and flags are deterministic;
- add one real Docker smoke test in CI where feasible.

Do not expand `pexe` into PHP runtime discovery; that belongs to LocalDevStack/its PHP tooling.

---

## 3.5 `scripts/dexe.sh`

Same principles as `pexe`:

- keep POSIX `sh`;
- preserve exact argv forwarding;
- preserve TTY behavior;
- preserve child exit code;
- test non-interactive and TTY flag construction;
- test commands containing spaces/shell metacharacters to ensure no re-evaluation occurs;
- do not duplicate `lds exec` orchestration features.

`dexe` remains useful because runner-owned Supervisor jobs may call sibling containers directly.

---

## 3.6 `loggables/daily`

Current contract rotates matching `/global/log` logs daily using `copytruncate`, seven rotations, compression, date suffixes, and a postrotate message written to PID 1 stdout.

### Planned work

- validate syntax with `logrotate -d` in CI;
- test at least one real forced rotation using a temporary/mounted log tree;
- verify glob depth matches LocalDevStack's current mounted service paths;
- preserve `copytruncate` because sibling containers continue writing those mounted files and Runner cannot safely reopen every external process;
- preserve Docker-log postrotate message;
- review `maxage 30` + `rotate 7` together but keep existing retention unless we intentionally change policy;
- ensure missing service log directories remain harmless.

---

## 3.7 `loggables/dailyold`

This is the legacy move-to-oldlogs path:

```text
/global/movelog -> /global/oldlogs
```

### Planned work

1. Search LocalDevStack and documentation for active use.
2. If active, retain and test it.
3. If no active consumer remains:
   - mark deprecated in README first;
   - keep it for the current compatibility release;
   - remove only in a later deliberate cleanup.

Do not silently delete an established mount contract during hardening.

---

## 3.8 `loggables/supervisord`

### Planned work

- validate syntax with `logrotate -d`;
- verify it matches `/var/log/supervisor/*.log` including `supervisord.log`;
- keep `supervisorctl ... reopenlogs` after rotation;
- test forced rotation without losing subsequent Supervisor log writes;
- preserve Docker-log postrotate diagnostics;
- confirm file creation mode/ownership is appropriate for root-owned Supervisor.

---

## 3.9 `.github/workflows/check.yml` — new

Add a permanent PR/push validation workflow.

### Static gates

- `sh -n` for POSIX shell scripts;
- `bash -n` for Bash scripts;
- ShellCheck with failures enabled for actionable errors;
- validate Dockerfile/build inputs;
- actionlint for workflow syntax;
- dependency-policy check that rejects:
  - `Scriptomatic/master`;
  - raw Toolset `main` consumption;
  - unverified Toolset release installer usage.

### Image gates

Build the actual image and then test:

1. image starts;
2. Supervisor is PID 1;
3. healthcheck becomes healthy;
4. `supervisorctl status` reports `cron` RUNNING;
5. `supervisorctl status` reports `logrotate` RUNNING;
6. `dexe` and `pexe` are executable;
7. `show-banner` and `chromacat` are installed;
8. mounted empty `/etc/supervisor/conf.d` works;
9. a mounted sample Supervisor program starts;
10. a mounted sample cron file is recognized;
11. SIGTERM causes a clean bounded shutdown.

### Logrotate gates

- debug-validate all three bundled logrotate configs;
- force rotation of a temporary `/global/log` file;
- verify compressed/dated output behavior where deterministic;
- verify Supervisor logs remain writable after `reopenlogs`;
- deliberately inject one invalid optional fragment and verify the worker does not create a rapid restart storm.

### Helper gates

Use both fake-Docker deterministic tests and, where useful, an actual sibling container to validate `dexe` / `pexe` exit-code and argv forwarding.

---

## 3.10 `.github/workflows/docker.publish.yml`

Replace the legacy publication workflow with the modern ecosystem publishing contract already proven in `docker-llm-sm`.

### Trigger semantics

Release event:

- build from the released source/tag;
- publish immutable release tag;
- publish/update `latest`.

Scheduled refresh:

- build from the latest released source;
- publish/update `latest` only;
- **never republish/overwrite the immutable release tag**.

Preserve the existing every-two-weeks refresh cadence unless we deliberately standardize ecosystem schedules later.

### Workflow modernization

- current `actions/checkout` major used by the ecosystem reference workflow;
- current Docker login/metadata/setup-buildx/build-push action majors;
- Buildx cache;
- Docker Hub + GHCR tags from the same build;
- provenance attestations for both registries;
- concurrency group with `cancel-in-progress: false`;
- sensible job timeout;
- OCI revision/version/source labels supplied from workflow metadata;
- exact release source checkout;
- no mutable release-tag overwrite on schedule.

### Build arguments

Pass the pinned dependency contract explicitly:

```text
ALPINE_VERSION=...
SCRIPTOMATIC_REF=<full SHA>
TOOLSET_VERSION=2.0
```

Do not resolve Scriptomatic `main` or Toolset `latest` implicitly inside a release build if the goal is deterministic image reproduction.

---

## 3.11 `README.md`

Update README only after runtime behavior is settled.

### Required corrections/additions

- describe Runner narrowly as LocalDevStack background execution infrastructure;
- document Supervisor as PID 1;
- reconcile the documented cron command with the tested actual Cronie invocation;
- document `LOGROTATE_INTERVAL` validation semantics;
- document `LOGROTATE_STATE_FILE` persistence requirements;
- document `/global/log`, `/global/movelog`, `/global/oldlogs`, `/var/log/supervisor` accurately;
- document `dexe`/`pexe` as Docker-socket-dependent helpers;
- clearly state that mounting `/var/run/docker.sock` grants high privilege and is optional at image level;
- show Docker Hub and GHCR usage;
- document immutable release tags versus moving `latest`;
- document how LocalDevStack mounts Supervisor/cron/log paths;
- fix Markdown formatting issues (including the current malformed code-fence around the `dexe` example);
- remove stale claims that do not match the tested Supervisor config.

Do not turn the README into LocalDevStack's full documentation; link to LocalDevStack where orchestration-specific behavior belongs.

---

## 3.12 `.dockerignore`

Review build context after test/docs additions.

- include only files required to build the image;
- exclude tests/docs when they are not required by Docker build context;
- do not hide source files needed for validation;
- keep the file simple.

---

## 3.13 `.gitattributes`

Preserve unless needed for explicit shell-script LF normalization.

If line-ending policy is not currently explicit, add LF rules for:

```text
*.sh text eol=lf
Dockerfile text eol=lf
*.conf text eol=lf
```

This matters because LocalDevStack supports Windows/Git Bash users and CRLF-mounted scheduler files are already a known operational issue.

---

## 3.14 `.gitignore`

No functional change expected. Update only for test-generated artifacts if required.

---

## 3.15 `LICENSE`

No change.

---

# 4. New test layout

Create a small repository-native test surface rather than embedding all validation in workflow YAML.

Suggested files:

```text
tests/
├── assertions.sh
├── static.sh
├── helpers-smoke.sh
├── supervisor-smoke.sh
├── logrotate-smoke.sh
└── dependency-contract.sh
```

## `tests/assertions.sh`

Small reusable assertion helpers only.

## `tests/static.sh`

- shell syntax;
- expected executable/source files;
- config presence;
- optional local ShellCheck invocation.

## `tests/helpers-smoke.sh`

Test `dexe` / `pexe` argv construction, TTY behavior and exit-code propagation using a fake Docker executable.

## `tests/supervisor-smoke.sh`

Against a built image:

- start container;
- wait for health;
- verify Supervisor/cron/logrotate;
- mount a sample program;
- test shutdown.

## `tests/logrotate-smoke.sh`

- config debug validation;
- forced `/global/log` rotation;
- Supervisor reopen test;
- invalid-fragment bounded-failure test.

## `tests/dependency-contract.sh`

Reject regression to mutable/unsupported dependency sources and confirm the selected Scriptomatic/Toolset inputs are represented consistently in Dockerfile/workflow/docs.

---

# 5. Security and privilege boundaries

This image is intentionally privileged infrastructure, but the privilege should be explicit.

## Keep

- root inside the runner container;
- Docker CLI in the image because `dexe` / `pexe` are part of its role.

## Do not bake in

- Docker socket mount;
- host filesystem mounts beyond what the orchestrator supplies;
- broad network privileges/capabilities;
- Docker daemon configuration.

## Document clearly

A caller mounting `/var/run/docker.sock` effectively grants the Runner strong control over the host Docker environment. LocalDevStack may choose that because scheduler/Supervisor jobs need sibling-container execution, but the base image must not imply that the socket is mandatory for cron/logrotate-only use.

---

# 6. LocalDevStack integration follow-up

Do not change LocalDevStack during the runner implementation branch. After a new Runner release is validated:

1. update LocalDevStack from `infocyph/runner:latest` to the agreed compatibility-pinned runner version/tag strategy;
2. retest mounted Supervisor definitions;
3. retest mounted cron jobs;
4. retest all service log directories;
5. decide whether `/var/lib/logrotate` needs a dedicated LocalDevStack named volume/bind so rotation state survives container replacement, not merely restart;
6. inventory current scheduler use of `dexe` / `pexe` before considering removal of the Docker socket mount;
7. do not couple this runner release to the later LocalDevStack static-IP/Docker-DNS migration.

The current LocalDevStack Runner service mounts the Docker socket and multiple service log directories, so compatibility testing must include that real integration shape.

---

# 7. Release strategy

Do not assign a new semantic version until implementation results establish whether any public contract changes.

If behavior remains compatible, release according to the repository's existing versioning policy.

A major bump is not required merely because CI, dependency pinning and internals were hardened.

Release requirements:

- all CI green;
- real Docker image smoke green;
- LocalDevStack scheduler/supervisor compatibility green;
- release tag published to Docker Hub + GHCR;
- matching digest provenance generated;
- moving `latest` updated;
- scheduled workflow proven unable to overwrite the immutable release tag.

---

# 8. Implementation order

Execute in this order so failures are isolated:

### Phase 1 — Permanent validation foundation

1. add `tests/` helpers/static/dependency tests;
2. add `.github/workflows/check.yml`;
3. make current baseline pass before behavioral changes.

### Phase 2 — Dependency reproducibility

1. update Dockerfile Scriptomatic dependency to full-SHA contract;
2. move `chromacat` to exact Toolset stable release installer/assets;
3. add dependency regression tests.

### Phase 3 — Worker/runtime hardening

1. harden `logrotate-worker.sh`;
2. validate Supervisor/Cronie behavior;
3. harden/test `dexe` + `pexe` without expanding features;
4. validate logrotate fragments.

### Phase 4 — Image/runtime smoke

1. build actual image;
2. health/Supervisor tests;
3. cron test;
4. mounted Supervisor job test;
5. forced log rotation test;
6. SIGTERM/shutdown test.

### Phase 5 — Publishing modernization

1. replace legacy publish workflow;
2. enforce immutable release tags;
3. add Buildx cache/concurrency/timeouts/provenance;
4. validate scheduled versus release tag generation.

### Phase 6 — Documentation and release

1. reconcile README with tested behavior;
2. finalize `.dockerignore` / `.gitattributes` if needed;
3. run full validation;
4. test against LocalDevStack;
5. release.

---

# 9. Explicit non-goals

Do **not** use this hardening pass to:

- move LocalDevStack orchestration logic into Runner;
- add application runtimes such as PHP/Node to Runner;
- add databases, web servers or AI services;
- replace Supervisor with another process manager;
- remove Docker CLI while `dexe`/`pexe` are still required;
- remove legacy log paths without usage proof/deprecation;
- solve LocalDevStack static networking here;
- make Runner responsible for Docker socket provisioning;
- introduce a large framework for a handful of shell scripts.

Keep the image small and boring.

---

# 10. Final acceptance criteria

The runner work is complete when all of the following are true:

1. `sh -n` / `bash -n` pass for the correct script types.
2. ShellCheck gate passes at the agreed severity.
3. Dependency contract test passes.
4. No `Scriptomatic/master` dependency remains.
5. Scriptomatic is reproducibly pin-able by full SHA.
6. Toolset `chromacat` comes from a checksum-verified stable release contract, initially Toolset `2.0`.
7. Actual Docker image builds successfully.
8. Supervisor is PID 1 and the image becomes healthy.
9. Cron and logrotate show RUNNING under Supervisor.
10. Current Cronie flags are tested and README/config agree.
11. Invalid logrotate configuration cannot trigger an uncontrolled rapid Supervisor restart loop.
12. `dexe` and `pexe` preserve argv, TTY behavior and exit codes.
13. All bundled logrotate configurations validate.
14. Forced rotation smoke test passes.
15. Supervisor logs continue after rotation/reopen.
16. SIGTERM causes a clean bounded container shutdown.
17. Docker Hub + GHCR publish from the same build output.
18. Release-event builds publish immutable release tag + `latest`.
19. Scheduled builds publish only `latest` and cannot overwrite a release tag.
20. LocalDevStack's current mounted Supervisor/cron/log/Docker-socket workflow remains compatible.
21. Documentation matches actual runtime behavior.
22. Runner remains narrow: Supervisor + cron + logrotate + Docker exec helpers, nothing more.
