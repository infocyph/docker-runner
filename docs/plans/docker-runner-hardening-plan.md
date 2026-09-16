# docker-runner — Hardening, Quality & Release Plan

## Status

Planning/implementation branch: `plan/docker-runner-hardening`

Baseline:

- Repository: `infocyph/docker-runner`
- Default branch: `main`
- Baseline release: `0.4.3`
- Baseline `main` matched `0.4.3`
- Base image remains `alpine:latest`
- Scriptomatic remains `main`
- Toolset remains latest stable release
- Primary ecosystem role: LocalDevStack background-process runner
- Standalone operation remains first-class
- Supervisor remains PID 1
- Default supervised services remain cron + logrotate

Implementation cadence: **3 phases per batch**.

Current batch status:

- Phase 1 — Validation foundation: **implemented**
- Phase 2 — Dependency modernization: **implemented**
- Phase 3 — Runtime hardening: **implemented**
- Phase 4 onward: **pending next batch**

This plan supersedes older LocalDevStack master-draft assumptions.

---

# 1. Goal and product boundary

Harden `docker-runner` into a small, predictable, observable and independently usable infrastructure image while preserving its primary LocalDevStack role.

Runner supports two valid modes:

1. **LocalDevStack-integrated** — LocalDevStack mounts scheduler configuration, service logs and optionally the Docker socket into Runner.
2. **Standalone** — Runner starts by itself with Supervisor + cron + logrotate; mounts and Docker access are optional.

LocalDevStack is the main compatibility target, but LocalDevStack-specific orchestration must not be baked into the image.

Runner should remain responsible for only:

1. Supervisor as PID 1;
2. cron execution;
3. log rotation;
4. thin Docker `exec` helpers (`dexe`, `pexe`) when Docker access is provided;
5. the existing interactive presentation/banner helper.

Runner must not become a second `docker-tools` control plane or a generic application-runtime image.

---

# 2. Dependency policy — intentional moving dependencies

## 2.1 Alpine remains `latest`

Keep exactly:

```dockerfile
FROM alpine:latest
```

Do not introduce an Alpine version/digest build argument in this project.

Rationale:

- Runner's `latest` channel is expected to receive current Alpine security/package updates;
- scheduled refreshes should deliberately rebuild against current Alpine stable;
- compatibility is protected through CI and runtime smoke rather than source pinning.

Required safeguards:

- CI builds with `pull: true`;
- fresh-upstream canary later builds without stale dependency layers;
- published release tags are immutable after publication;
- provenance/SBOM/image digest capture what was actually published.

## 2.2 Scriptomatic remains `main`

Runner intentionally consumes:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh
```

Do **not** introduce `SCRIPTOMATIC_REF`, a release tag, or a commit SHA.

Required safeguards:

- HTTPS only;
- download must fail the image build on error;
- downloaded file must be non-empty;
- run `bash -n` before installing/using it;
- CI dependency contract must reject stale `Scriptomatic/master` usage;
- fresh-upstream canary must catch future Scriptomatic/main incompatibility.

`main` is an intentional moving foundation dependency, not an accidental unpinned source.

## 2.3 Toolset remains latest stable

Use the current Toolset stable installer contract:

```bash
curl -fsSLo /tmp/toolset-install.sh \
  "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"
bash /tmp/toolset-install.sh --prefix /usr/local/bin chromacat
rm -f /tmp/toolset-install.sh
```

Rules:

- latest stable release only;
- no `TOOLSET_VERSION` build argument;
- no raw `Toolset/main/...` file download;
- install only `chromacat`;
- explicitly use `/usr/local/bin` inside Runner;
- verify `chromacat --version` during the build.

Toolset's installer verifies selected release assets through the release checksum contract before installation.

Do not install `--all` in Runner. `cleanx`, `dockex`, `gitx`, `netx`, `phpx`, `sqlitex` belong elsewhere unless Runner later gains a demonstrated direct need.

## 2.4 Traceability model

Runner intentionally combines moving upstreams:

- `alpine:latest`;
- `Scriptomatic/main`;
- Toolset latest stable;
- fixed Runner source release tag when publishing versioned releases.

Therefore the target is **immutable publication + auditable build inputs**, not byte-identical rebuilds from source forever.

Later publishing work must expose:

- image digest;
- Runner source revision/version;
- Alpine version resolved during build;
- Toolset/chromacat version resolved during build;
- provenance;
- SBOM.

---

# 3. Public compatibility contract

Preserve unless a tested defect requires a deliberate change:

- `docker.io/infocyph/runner`;
- `ghcr.io/infocyph/runner`;
- `latest` as LocalDevStack's moving integration channel;
- immutable version tags for pinned/standalone consumers;
- Supervisor PID 1;
- `/etc/supervisor/conf.d/*.conf` extension surface;
- `/etc/cron.d` scheduler mount surface;
- `/global/log` primary rotation root;
- `/global/movelog` and `/global/oldlogs` compatibility paths;
- `/var/log/supervisor` Supervisor log path;
- `dexe` generic Docker exec wrapper;
- `pexe` PHP-specific Docker exec wrapper;
- exact argument forwarding;
- TTY auto-detection;
- helper exit-code propagation;
- Docker socket remaining optional at image level;
- root execution remaining acceptable for this infrastructure role.

Standalone Runner must start without LocalDevStack and without `/var/run/docker.sock`.

---

# 4. Phase 1 — Validation foundation — IMPLEMENTED

## 4.1 Repository-native tests

Added:

```text
tests/
├── assertions.sh
├── static.sh
├── dependency-contract.sh
├── runtime-contract.sh
└── helpers-smoke.sh
```

Current coverage:

### `assertions.sh`

Small reusable shell assertion helpers.

### `static.sh`

Validates:

- POSIX shell syntax for `dexe`, `pexe`, `runner-healthcheck`;
- Bash syntax for `logrotate-worker` and tests;
- required runtime/config files;
- no CRLF in source/config/workflow trees;
- ShellCheck when installed.

### `dependency-contract.sh`

Locks intentional upstream behavior:

- exact `FROM alpine:latest`;
- Scriptomatic `main`;
- Toolset `releases/latest/download/install.sh`;
- Toolset prefix `/usr/local/bin`;
- only `chromacat` installation;
- no `Scriptomatic/master`;
- no `SCRIPTOMATIC_REF`;
- no `TOOLSET_VERSION`;
- no raw Toolset `main` dependency.

### `runtime-contract.sh`

Locks:

- dedicated core healthcheck;
- core health limited to `cron` + `logrotate`;
- Supervisor internal log rotation disabled;
- Cronie command remains `crond -f -P -p`;
- logrotate worker bounded-failure contract;
- clean TERM/INT trap.

### `helpers-smoke.sh`

Uses a fake Docker executable to test:

- usage errors;
- argument boundaries;
- metacharacters/whitespace are not re-evaluated;
- `pexe` inserts `php` exactly;
- Docker exit status propagates.

TTY-specific real execution remains Phase 4 integration work.

## 4.2 Permanent CI

Added `.github/workflows/check.yml`.

Current CI:

- `actions/checkout@v7`;
- installs ShellCheck;
- runs static tests;
- runs dependency contract;
- runs runtime contract;
- runs helper smoke tests;
- installs/runs actionlint;
- uses `docker/setup-buildx-action@v4`;
- builds the real image with `docker/build-push-action@v7`;
- uses `pull: true`;
- verifies expected commands exist in the built image;
- verifies `chromacat --version`.

Full runtime health/cron/logrotate/LocalDevStack smoke remains Phase 4.

---

# 5. Phase 2 — Dependency modernization — IMPLEMENTED

## 5.1 Dockerfile upstream delivery

Implemented:

- Alpine remains `latest`;
- removed remote Dockerfile `ADD` for Scriptomatic/Toolset;
- Scriptomatic now downloads from `main` using `curl`;
- verifies non-empty Scriptomatic payload;
- `bash -n` validates Scriptomatic banner;
- Toolset installer downloads from latest stable release;
- Toolset installer syntax is validated;
- installs only `chromacat` to `/usr/local/bin`;
- runs `chromacat --version` during build;
- removes temporary installer.

## 5.2 Package policy

Current package list is retained during this batch:

- `bash`
- `curl`
- `ca-certificates`
- `supervisor`
- `docker-cli`
- `logrotate`
- `cronie`
- `tzdata`
- `figlet`
- `ncurses`
- `musl-locales`
- `gawk`

Do not remove packages until Phase 4 image/runtime testing proves they are unnecessary across banner/Toolset/cron/standalone behavior.

Image-size trimming is secondary to compatibility and operational predictability.

---

# 6. Phase 3 — Runtime hardening — IMPLEMENTED

## 6.1 Core-only healthcheck

Added `scripts/runner-healthcheck.sh`.

Health now checks only Runner-owned core programs:

```text
cron
logrotate
```

This prevents an arbitrary mounted Supervisor workload from marking the entire Runner unhealthy merely because that workload is intentionally stopped/failed.

Phase 4 must prove this behavior with a real mounted program.

## 6.2 Supervisor log ownership

Updated `scripts/supervisord.conf`:

```ini
logfile_maxbytes=0
logfile_backups=0
```

External logrotate is now the intended single owner of Supervisor log rotation.

## 6.3 Cronie contract retained

Keep:

```text
/usr/sbin/crond -f -P -p
```

Do not replace this with BusyBox-style flags from the old README.

`-p` may be important for LocalDevStack host bind-mounted cron files whose ownership/mode semantics vary across Docker hosts.

Removal/tightening requires Linux + Docker Desktop compatibility evidence.

## 6.4 Logrotate worker hardening

Implemented:

- removed fail-fast `set -e` behavior for ordinary rotation failures;
- validates `LOGROTATE_INTERVAL` as a positive integer;
- invalid values fall back to `3600`;
- added `LOGROTATE_FAILURE_INTERVAL`, default `60`;
- validates failure interval;
- validates non-empty state-file path;
- creates/checks writable state directory;
- isolates config execution in `run_config`;
- reports failed config + exit status;
- fallback mode continues through remaining fragments;
- aggregates fallback failure state;
- failed pass waits for bounded failure interval rather than exiting into Supervisor restart storm;
- success returns to normal interval;
- TERM/INT trap stops worker and interrupts its sleep child;
- emits final stopped message.

Initialization failures such as an unusable state directory remain fatal, which is correct because the worker cannot operate safely in that state.

---

# 7. Phase 4 — Image/runtime smoke — NEXT BATCH

Build full behavioral tests around the actual image.

Required coverage:

## 7.1 Standalone startup

Run:

```text
infocyph/runner:<candidate>
```

with:

- no LocalDevStack mounts;
- no Docker socket;
- no additional Supervisor programs.

Verify:

- Supervisor is PID 1;
- core health becomes healthy;
- cron RUNNING;
- logrotate RUNNING;
- no Docker socket is required for startup;
- clean SIGTERM shutdown.

## 7.2 Health semantics

Mount a sample Supervisor program.

Verify:

1. sample program starts;
2. core health is healthy;
3. deliberately stop the sample program;
4. core health remains healthy while `cron` + `logrotate` remain running;
5. stopping a core Runner program makes health fail.

## 7.3 Cron smoke

Mount a real `/etc/cron.d` file and verify execution.

Test:

- root-style normal file;
- host-mounted permission shape relevant to LocalDevStack;
- final newline;
- `TZ` behavior;
- inherited PATH behavior from `-P`;
- expected failure/documentation around CRLF.

## 7.4 Logrotate smoke

Test all bundled configs:

- `logrotate -d` validation;
- forced `/global/log` rotation;
- state file creation/update;
- compressed/date output where deterministic;
- Supervisor log rotation and `reopenlogs`;
- continued writes after reopen;
- invalid fragment does not restart-loop worker;
- fallback attempts later fragments after one failure;
- failure retry interval is bounded;
- worker exits promptly during sleep on SIGTERM.

## 7.5 Docker helper integration

Use a real sibling container/socket environment to verify:

- `dexe` non-TTY;
- `dexe` TTY;
- `pexe` where a PHP target fixture is practical;
- exact exit-code propagation.

## 7.6 Package review

After runtime tests, reevaluate whether these can be removed safely:

- `gawk`;
- `musl-locales`;
- any other presentation-only package.

Do not optimize before tests.

---

# 8. Phase 5 — Architecture, upstream canary & supply chain — NEXT BATCH

## 8.1 Latest-upstream canary

Because Alpine, Scriptomatic and Toolset all intentionally move, add a scheduled non-publishing canary.

Requirements:

- fresh `--pull` build;
- bypass stale dependency-fetch layers where needed;
- current `alpine:latest`;
- current Scriptomatic/main;
- current Toolset latest stable;
- run core runtime smoke;
- record resolved Alpine version;
- record `chromacat --version`;
- report failures without publishing.

Weekly is sufficient initially.

## 8.2 Multi-architecture

Target:

```text
linux/amd64
linux/arm64
```

Requirements before advertising arm64:

- amd64 full runtime smoke;
- arm64 successful Buildx/QEMU build;
- minimal arm64 startup smoke where reliable;
- Toolset/Scriptomatic/package behavior validated.

## 8.3 Supply-chain metadata

Add:

- SBOM;
- BuildKit provenance;
- OCI source/revision/version/created metadata;
- image digest visibility;
- resolved upstream-version information in workflow summary.

Use current supported GitHub/Docker actions at implementation time.

---

# 9. Phase 6 — Publishing modernization — NEXT BATCH

Replace legacy publish semantics rather than preserving current tag bugs.

## 9.1 Release event

On `release: published`:

- use `github.event.release.tag_name` directly;
- checkout that exact source tag;
- run candidate smoke before push;
- publish immutable version tag;
- publish/update `latest`;
- do not query some other latest release during a release-event build.

## 9.2 Scheduled refresh

Scheduled refresh exists to absorb moving Alpine/Scriptomatic/Toolset upstreams.

For schedule:

1. resolve current latest Runner release source;
2. checkout that immutable Runner source;
3. fresh-build against current upstreams;
4. run smoke suite;
5. update **only `latest`**;
6. never republish/overwrite the version tag.

## 9.3 Correct biweekly semantics

Current legacy expression:

```cron
0 0 * * */2
```

is not every two weeks; the fifth field is day-of-week.

Preferred implementation:

- schedule weekly on a fixed weekday;
- gate scheduled publish by ISO week parity.

Alternatively deliberately switch to weekly, but document it honestly.

## 9.4 Modern action majors

At the time of this plan revision the modern baselines include:

- `actions/checkout@v7`;
- `docker/login-action@v4`;
- `docker/metadata-action@v6`;
- `docker/setup-buildx-action@v4`;
- `docker/setup-qemu-action@v4`;
- `docker/build-push-action@v7`;
- `actions/attest@v4` for new attestation usage.

Re-check before implementation; always prefer the current stable supported majors.

## 9.5 Publishing quality

Add:

- Buildx GitHub Actions cache;
- sensible timeout;
- publish concurrency;
- `cancel-in-progress: false` for releases;
- pre-push smoke;
- explicit `runner` image identity instead of unnecessary name derivation;
- Docker Hub + GHCR from the same build definition;
- provenance/SBOM.

---

# 10. LocalDevStack compatibility gate

LocalDevStack is Runner's primary ecosystem consumer.

Current integration shape uses:

```text
image: infocyph/runner:latest
```

and mounts approximately:

```text
configuration/scheduler/supervisor -> /etc/supervisor/conf.d:ro
configuration/scheduler/cron-jobs  -> /etc/cron.d:ro
logs/runner                         -> /var/log/supervisor
multiple service logs              -> /global/log/<service>
/var/run/docker.sock               -> /var/run/docker.sock
```

Runner must remain compatible with that shape while also remaining standalone.

## 10.1 `latest` remains a compatibility promise

Do not force LocalDevStack to pin Runner as part of this hardening work.

LocalDevStack intentionally consumes `runner:latest`, so each `latest` publish must preserve established compatibility.

Standalone/pinned consumers can use version tags or digests.

## 10.2 Required LocalDevStack release-candidate smoke

Before final publish:

- start Runner using equivalent read-only Supervisor mount;
- equivalent read-only cron mount;
- writable Supervisor logs;
- many `/global/log/<service>` mounts;
- Docker socket mounted;
- representative scheduler jobs;
- sibling-container execution;
- timezone propagation;
- shutdown/restart;
- confirm no new required capability/network/env/volume.

A full LocalDevStack current-main end-to-end smoke should be done where practical.

## 10.3 Logrotate state follow-up

Current LocalDevStack does not separately persist `/var/lib/logrotate`.

After Runner hardening, evaluate a LocalDevStack named volume/bind if preserving rotation state across container recreation is desirable.

This remains an orchestration decision outside Runner.

---

# 11. Standalone contract

The simple form must remain valid:

```bash
docker run -d --name runner infocyph/runner:latest
```

No Docker socket must be required for health/startup.

Optional standalone integrations:

- `/etc/supervisor/conf.d:ro`;
- `/etc/cron.d:ro`;
- `/global/log`;
- `/global/movelog` + `/global/oldlogs`;
- persistent `/var/lib/logrotate`;
- Docker socket/remote Docker environment only when `dexe`/`pexe` are needed.

Do not make LocalDevStack-specific networks, hostnames or container names mandatory.

---

# 12. Security and privilege boundary

Keep:

- root inside Runner;
- Docker CLI;
- Cronie's current `-p` until cross-platform LocalDevStack evidence supports tightening.

Do not bake in:

- Docker socket;
- privileged mode;
- extra Linux capabilities;
- host paths;
- SSH keys/secrets;
- Docker daemon configuration;
- PHP/Node/application runtimes.

Document clearly later:

- mounting `/var/run/docker.sock` grants strong control over the Docker host;
- scheduler config mounts should normally be read-only;
- moving upstream dependencies are intentional and protected by canary/testing rather than pins.

---

# 13. Logrotate config policy

## `/global/log`

Keep current semantics unless tests show a defect:

- daily;
- rotate 7;
- maxage 30;
- missingok;
- notifempty;
- copytruncate;
- compress;
- delaycompress;
- date suffix;
- Docker-visible postrotate message.

README must later describe the explicit configured glob depths accurately rather than implying unlimited `**` recursion.

`copytruncate` remains correct because Runner cannot signal/reopen arbitrary sibling service processes.

## `/global/movelog` -> `/global/oldlogs`

Current LocalDevStack does not use these mounts, but existing standalone consumers may.

Keep them during this release.

Any removal requires an explicit deprecation cycle.

## Supervisor logs

Keep external logrotate + `supervisorctl reopenlogs`.

Supervisor internal size rotation has already been disabled in Phase 3.

---

# 14. Repository support files

## `.gitattributes`

Current:

```text
* text eol=lf
```

is already the right cross-platform policy. Preserve it.

## `.dockerignore`

Review after all test/docs additions.

Keep build context minimal, but never hide files required by Dockerfile.

## `.gitignore`

Change only if new local tests generate artifacts.

## `.github/dependabot.yml`

Add during later workflow modernization for weekly `github-actions` updates.

Do not use it to pin/replace `alpine:latest`.

---

# 15. Documentation phase requirements

README changes are deferred until runtime behavior is proven.

Later README update must:

- explain standalone + LocalDevStack roles;
- show standalone no-socket usage first;
- describe Supervisor PID 1;
- describe core-only healthcheck;
- document actual Cronie command, not BusyBox flags;
- explain `LOGROTATE_INTERVAL` validation;
- document `LOGROTATE_FAILURE_INTERVAL`;
- document state-file persistence implications;
- accurately describe glob depth;
- document optional legacy move-to-oldlogs paths;
- document Docker socket privilege;
- document moving upstream policy concisely;
- distinguish immutable version tags from moving `latest`;
- advertise amd64/arm64 only after Phase 5 proves it;
- fix the existing malformed `dexe` code fence.

Do not duplicate the full LocalDevStack orchestration manual.

---

# 16. Feature ideas after hardening

These are useful but not part of the current three-phase batch.

## `runner-doctor`

Potential read-only diagnostics:

- Supervisor connectivity/config;
- logrotate configs;
- cron CRLF/final-newline problems;
- writable log/state paths;
- Docker reachability when requested;
- upstream/component versions.

Keep lightweight if introduced.

## `runner-reload`

Potential explicit helper for:

```text
supervisorctl reread
supervisorctl update
```

Do not add filesystem watchers merely to auto-reload mounted config.

## Strict Cronie mode

Future opt-in mode may remove `-p` for environments that guarantee strict root ownership/modes.

Do not change the default until LocalDevStack host-platform testing proves it safe.

## Build info

A future lightweight `runner-version` or `/etc/runner-build-info` could expose:

- Runner revision/version;
- resolved Alpine release;
- resolved Toolset/chromacat version.

Since Scriptomatic intentionally follows `main`, provenance/build summary is a better source for its exact fetched state than inventing a fake stable version contract.

---

# 17. Explicit non-goals

Do not use this project to:

- pin Alpine away from `latest`;
- pin Scriptomatic away from `main`;
- pin Toolset away from latest stable;
- install Toolset `--all`;
- move LocalDevStack orchestration into Runner;
- make LocalDevStack mandatory;
- add PHP/Node/databases/web servers;
- replace Supervisor;
- replace Cronie;
- remove Docker CLI while helpers remain public;
- require Docker socket at startup;
- remove legacy log paths without deprecation;
- solve unrelated LocalDevStack networking;
- add a large framework around simple shell infrastructure.

Keep Runner small and boring.

---

# 18. Remaining implementation order

## Batch 2 — Phases 4, 5, 6

### Phase 4 — image/runtime smoke

- standalone startup;
- core health semantics;
- mounted Supervisor program;
- cron execution;
- real logrotate;
- invalid-fragment behavior;
- real Docker helper execution;
- shutdown;
- package review.

### Phase 5 — architecture/canary/supply chain

- fresh-upstream canary;
- amd64 + arm64 validation;
- QEMU where needed;
- SBOM;
- provenance;
- build metadata.

### Phase 6 — publishing modernization

- modern action majors;
- exact release-event tag;
- schedule updates only `latest`;
- real biweekly semantics;
- cache/concurrency/timeouts;
- smoke-before-push;
- immutable release tags.

## Batch 3 — Phase 7 + integration/release closure

- README and support-file cleanup;
- LocalDevStack current-main end-to-end gate;
- standalone final gate;
- version decision;
- release validation;
- optional follow-up LocalDevStack state-volume decision.

If new phases are introduced during implementation, keep the working cadence at three phases per batch unless there are fewer than three phases remaining.

---

# 19. Final acceptance criteria

Runner hardening is complete when:

1. `FROM alpine:latest` remains.
2. Scriptomatic is consumed from `main`.
3. No Scriptomatic `master` dependency remains.
4. No Scriptomatic SHA/version pin is introduced.
5. Scriptomatic payload is downloaded fail-fast and syntax-checked.
6. Toolset installs from latest stable release installer.
7. Only `chromacat` is installed from Toolset.
8. `chromacat` installs into `/usr/local/bin`.
9. No raw Toolset `main` dependency remains.
10. Static syntax checks pass.
11. ShellCheck passes.
12. actionlint passes.
13. Dependency contract tests pass.
14. Runtime contract tests pass.
15. Helper deterministic tests pass.
16. Actual image builds with current moving upstreams.
17. Supervisor remains PID 1.
18. Core health covers `cron` + `logrotate`, not arbitrary mounted programs.
19. Mounted program failure does not falsely mark Runner core unhealthy.
20. Cronie remains tested under LocalDevStack host-mount semantics.
21. Supervisor internal logfile rotation remains disabled.
22. External Supervisor logrotate/reopen works.
23. Invalid logrotate intervals cannot busy-loop.
24. Rotation config failures do not create Supervisor restart storms.
25. Fallback rotation attempts later fragments after one failure.
26. Worker failure retries are bounded.
27. Worker shuts down cleanly during sleep.
28. All bundled logrotate configs validate.
29. Forced service-log rotation works.
30. Supervisor logs remain writable after rotation.
31. `dexe` preserves argv/TTY/exit status.
32. `pexe` preserves argv/TTY/exit status.
33. Standalone image starts healthy without Docker socket.
34. Docker helpers work when Docker access is provided.
35. LocalDevStack current mount/config contract remains compatible.
36. Legacy move-to-oldlogs paths remain compatible or enter explicit later deprecation.
37. amd64 runtime smoke passes.
38. arm64 is advertised only after build/smoke validation.
39. Fresh-upstream canary protects moving Alpine/Scriptomatic/Toolset inputs.
40. Release-event publication uses the exact event tag.
41. Scheduled refresh updates only `latest`.
42. Historical version tags are never overwritten.
43. Biweekly schedule is implemented correctly or deliberately replaced with a documented cadence.
44. Docker Hub + GHCR use the same release definition.
45. SBOM/provenance are published.
46. README matches tested behavior.
47. Global LF policy remains intact.
48. Runner remains narrowly scoped.
