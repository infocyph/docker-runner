# docker-runner — Hardening, Quality & Release Plan

## Status

Planning/implementation branch: `plan/docker-runner-hardening`

Baseline:

- Repository: `infocyph/docker-runner`
- Default branch: `main`
- Baseline release: `0.4.3`
- Target release: **`0.5.0`**
- Base image: `alpine:latest`
- Scriptomatic: `main`
- Toolset: latest stable release
- Primary ecosystem role: LocalDevStack background-process runner
- Standalone operation: first-class
- Supervisor: PID 1
- Core supervised services: `cron` + `logrotate`

Implementation status:

- Phase 1 — Validation foundation: **implemented and passing**
- Phase 2 — Dependency modernization: **implemented and passing**
- Phase 3 — Runtime hardening: **implemented and passing**
- Phase 4 — Full image/runtime smoke: **implemented and passing**
- Phase 5 — Architecture, upstream canary and supply chain: **implemented and passing**
- Phase 6 — Publishing modernization: **implemented and contract-validated**
- Phase 7 — Documentation/integration/release closure: **implemented and passing**

The final branch CI gate validates amd64 runtime behavior, live LocalDevStack compatibility, and arm64 startup. Actual Docker Hub/GHCR publication is intentionally performed only by the release/scheduled publish workflow rather than by branch CI.

---

# 1. Product boundary

`docker-runner` remains a small infrastructure companion image. It supports two valid modes:

1. **LocalDevStack-integrated** — scheduler configuration, service logs and optionally the Docker socket are mounted into Runner.
2. **Standalone** — Runner starts by itself with Supervisor + Cronie + logrotate; all external mounts and Docker access are optional.

Runner owns only:

- Supervisor as PID 1;
- Cronie scheduling;
- log rotation;
- thin Docker exec helpers (`dexe`, `pexe`) when Docker access is supplied;
- the existing interactive banner helper.

Runner does not become a generic runtime image or a replacement for `docker-tools`.

---

# 2. Dependency policy

## Alpine

Keep exactly:

```dockerfile
FROM alpine:latest
```

This is intentionally moving. Compatibility is protected by CI, weekly canary builds and weekly `latest` refreshes rather than by pinning Alpine.

## Scriptomatic

Consume:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh
```

Safeguards implemented:

- HTTPS download;
- fail-fast download;
- non-empty payload check;
- `bash -n` syntax validation;
- dependency contract rejects `master` and version/SHA pins;
- fresh-upstream canary catches future `main` incompatibility.

## Toolset

Install only `chromacat` from the latest stable Toolset release:

```bash
curl -fsSLo /tmp/toolset-install.sh \
  "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"
bash /tmp/toolset-install.sh --prefix /usr/local/bin chromacat
rm -f /tmp/toolset-install.sh
```

The installer validates the selected release asset against Toolset release checksums. Runner does not install Toolset `--all`.

## Traceability model

Because Alpine, Scriptomatic and Toolset intentionally move, Runner targets **immutable publication + auditable build inputs**, not byte-identical future rebuilds.

Publishing records or exposes:

- Runner source tag/revision;
- image digest;
- resolved Alpine version;
- resolved Toolset/chromacat version;
- current Scriptomatic `main` revision and installed banner SHA-256;
- BuildKit provenance;
- SBOM;
- registry attestations.

---

# 3. Public compatibility contract

Preserved:

- `docker.io/infocyph/runner`;
- `ghcr.io/infocyph/runner`;
- `latest` as LocalDevStack's moving integration channel;
- immutable release tags for pinned consumers;
- Supervisor PID 1;
- `/etc/supervisor/conf.d/*.conf`;
- `/etc/cron.d`;
- `/global/log`;
- `/global/movelog` and `/global/oldlogs`;
- `/var/log/supervisor`;
- `dexe` and `pexe`;
- argument and exit-code preservation;
- TTY auto-detection;
- optional Docker socket;
- root execution for this infrastructure role.

Standalone startup remains valid without LocalDevStack or `/var/run/docker.sock`:

```bash
docker run -d --name runner infocyph/runner:latest
```

---

# 4. Validation and CI — implemented

Repository-native tests now include:

```text
tests/
├── assertions.sh
├── static.sh
├── dependency-contract.sh
├── runtime-contract.sh
├── release-contract.sh
├── helpers-smoke.sh
├── standalone-smoke.sh
├── supervisor-smoke.sh
├── cron-smoke.sh
├── logrotate-smoke.sh
├── docker-integration-smoke.sh
├── localdevstack-contract.sh
└── release-gate.sh
```

The permanent `Check` workflow uses current action majors and enforces:

- shell syntax;
- LF-only source/config/workflow files;
- ShellCheck;
- dependency contracts;
- runtime contracts;
- publishing/release contracts;
- deterministic helper tests;
- actionlint;
- real amd64 image build;
- final shared release gate;
- arm64 Buildx/QEMU build and startup smoke.

The same `tests/release-gate.sh` is used by normal CI and the publishing workflow so the release path cannot silently skip behavior proven in PR/branch CI.

---

# 5. Runtime hardening — implemented

## Health

`scripts/runner-healthcheck.sh` checks Supervisor connectivity and only Runner-owned core programs:

```text
cron
logrotate
```

Mounted application programs do not incorrectly make Runner unhealthy when those programs are intentionally stopped or fail.

## Supervisor log ownership

Supervisor internal size rotation is disabled:

```ini
logfile_maxbytes=0
logfile_backups=0
```

External logrotate is the single rotation owner.

When Supervisor logs rotate, logrotate reads `/run/supervisord.pid` and sends **SIGUSR2** to Supervisor so its log descriptors are closed and reopened. The old/non-portable `supervisorctl reopenlogs` assumption is not used.

## Cronie

Runner retains:

```text
/usr/sbin/crond -f -P -p
```

Testing proved the permissive `-p` behavior is useful for host bind-mounted cron files with non-root host ownership/modes. `-P` retains the daemon PATH.

Container `TZ` does not automatically become every Cronie job's `TZ`; jobs that depend on a timezone should set `TZ=...` explicitly in the cron table.

## Logrotate worker

Implemented behavior:

- positive-integer validation for `LOGROTATE_INTERVAL`;
- invalid normal interval falls back to `3600`;
- `LOGROTATE_FAILURE_INTERVAL`, default `60`;
- state-path validation;
- fallback mode attempts every fragment even if one fails;
- rotation errors are reported without terminating into Supervisor restart storms;
- bounded retry delay after failed passes;
- normal interval restored after success;
- TERM/INT cleanly interrupts sleep and exits;
- initialization failures that make operation impossible remain fatal.

Real tests cover malformed fragments, later-fragment continuation, state creation, service-log rotation and shutdown.

---

# 6. Runtime/image smoke — implemented and passing

The amd64 release gate proves:

- standalone startup without Docker socket;
- Supervisor PID 1;
- healthy `cron` + `logrotate`;
- clean shutdown;
- non-core Supervisor failure does not poison core health;
- core program failure does make health fail;
- Cronie system-style jobs execute;
- permissive host-mount Cronie behavior works;
- custom PATH behavior works;
- explicit cron-table timezone behavior works;
- bundled logrotate configs parse;
- `/global/log` rotates correctly;
- logrotate state is created;
- Supervisor logs rotate and reopen through SIGUSR2;
- invalid logrotate fragments do not restart-loop the worker;
- fallback continues past a failed fragment;
- bounded failure retries work;
- `dexe` real non-TTY and PTY paths work;
- `pexe` real argument forwarding works;
- Docker target exit status propagates;
- current LocalDevStack mount shape works;
- LocalDevStack-style timezone, Docker socket and sibling-container execution work;
- LocalDevStack-style Runner survives restart without new privileges/capabilities.

Package review conclusion: **no package removals for 0.5.0**. Compatibility and predictable behavior outweigh marginal image-size savings. `gawk` may be reconsidered only in a dedicated future compatibility pass.

---

# 7. Architecture and moving-upstream canary — implemented

Supported publish targets:

```text
linux/amd64
linux/arm64
```

arm64 is validated with QEMU using both command and real Runner startup/health smoke.

`.github/workflows/upstream-canary.yml` runs weekly and deliberately performs fresh non-publishing builds against current:

- `alpine:latest`;
- Scriptomatic `main`;
- Toolset latest stable.

The canary uses fresh/no-cache behavior, records resolved dependency information, runs amd64 core runtime smoke and validates arm64 startup. It never publishes images.

Dependabot is configured for weekly GitHub Actions updates only; it does not replace the intentional moving container/tool dependencies.

---

# 8. Docker publishing — implemented

The publish workflow is aligned with the established `docker-llm-sm` release model while retaining Runner's stronger runtime and supply-chain gates.

Triggers:

```yaml
on:
  release:
    types: [published]
  schedule:
    - cron: '0 0 * * 0'
  workflow_dispatch:
```

Scheduled publication is intentionally **once per week**.

## Release event

On `release: published`:

1. use `github.event.release.tag_name` as the exact Runner source release;
2. checkout that exact tag;
3. fresh-build amd64 candidate against current moving dependencies;
4. run the complete shared release gate;
5. ensure the version tag does not already exist in Docker Hub or GHCR;
6. publish `<release-tag>` and `latest`;
7. publish a multi-architecture amd64/arm64 manifest;
8. emit SBOM/provenance and registry attestations;
9. summarize the resulting digest and resolved build inputs.

## Weekly refresh

On the weekly schedule:

1. resolve the latest published Runner release;
2. checkout that immutable Runner source;
3. fresh-build against current Alpine/Scriptomatic/Toolset;
4. run the complete release gate;
5. publish **only `latest`**;
6. never overwrite/reissue the historical version tag.

This replaces the older incorrect/overcomplicated biweekly scheduling logic with the explicitly requested weekly cadence.

## Current action baselines

- `actions/checkout@v7`;
- `docker/login-action@v4`;
- `docker/metadata-action@v6`;
- `docker/setup-buildx-action@v4`;
- `docker/setup-qemu-action@v4`;
- `docker/build-push-action@v7`;
- `actions/attest@v4`.

Release contracts lock these important semantics so accidental workflow regression is caught by normal CI.

---

# 9. LocalDevStack compatibility — implemented

LocalDevStack remains the primary ecosystem compatibility target and continues to consume:

```text
image: infocyph/runner:latest
```

The release gate reads current LocalDevStack `main` and locks its Runner integration surface, including:

```text
configuration/scheduler/supervisor -> /etc/supervisor/conf.d:ro
configuration/scheduler/cron-jobs  -> /etc/cron.d:ro
logs/runner                         -> /var/log/supervisor
logs/<service>                      -> /global/log/<service>
/var/run/docker.sock               -> /var/run/docker.sock
```

The test reproduces this shape with representative Supervisor/cron workloads, all current service-log mounts, timezone propagation, Docker socket access, sibling execution, health and restart recovery.

No LocalDevStack-specific network, hostname, container name or host path is baked into Runner.

## Logrotate state decision

LocalDevStack currently does not separately persist `/var/lib/logrotate` across container recreation.

For 0.5.0 this remains unchanged intentionally:

- Runner documents optional state persistence;
- standalone users may mount `/var/lib/logrotate`;
- LocalDevStack may add a named volume/bind later if preserving rotation state across recreation becomes operationally useful;
- Runner does not force that orchestration decision.

---

# 10. Documentation and repository support — implemented

README now reflects tested behavior rather than legacy assumptions. It documents:

- standalone-first usage;
- LocalDevStack role;
- core-only health semantics;
- real Cronie flags;
- cron timezone behavior;
- logrotate normal/failure intervals;
- logrotate state persistence;
- explicit supported log glob depths;
- Supervisor SIGUSR2 reopen behavior;
- legacy move-to-oldlogs compatibility;
- Docker socket privilege boundary;
- amd64/arm64 support;
- intentional moving dependencies;
- release + weekly `latest` refresh semantics.

Repository support decisions:

- global LF policy remains `* text eol=lf`;
- `.dockerignore` excludes docs/tests from runtime build context;
- tests remain available to CI from the repository checkout;
- no unnecessary generated artifacts require `.gitignore` expansion.

---

# 11. Security/privilege boundary

Keep:

- root inside Runner;
- Docker CLI;
- Cronie `-p` for current cross-platform bind-mount compatibility.

Do not bake in:

- Docker socket;
- privileged mode;
- extra Linux capabilities;
- host paths;
- credentials/secrets;
- Docker daemon configuration;
- application runtimes.

Mounting `/var/run/docker.sock` is documented as a powerful host-control boundary and remains optional.

---

# 12. Deferred ideas / explicit non-goals for 0.5.0

Potential later additions only if demonstrated useful:

- lightweight read-only `runner-doctor`;
- explicit `runner-reload` for Supervisor reread/update;
- opt-in strict Cronie mode after cross-platform evidence;
- lightweight runtime build-info helper;
- reevaluation of `gawk`/presentation packages;
- LocalDevStack `/var/lib/logrotate` persistence.

Not part of 0.5.0:

- pinning Alpine away from `latest`;
- pinning Scriptomatic away from `main`;
- pinning Toolset away from latest stable;
- Toolset `--all`;
- config filesystem watchers;
- replacing Supervisor or Cronie;
- application runtimes/databases/web servers;
- making Docker socket mandatory;
- removing legacy log paths without deprecation;
- moving LocalDevStack orchestration into Runner.

Keep Runner small and boring.

---

# 13. Release decision

The hardening work is additive and preserves the established public integration surfaces. It materially expands tested behavior, architecture support, workflow quality and observability without requiring a breaking public API/config migration.

Target release: **0.5.0**.

Before creating the release:

1. merge the hardened branch to `main` through the normal repository process;
2. ensure final `main` Check workflow is green;
3. create/publish GitHub release `0.5.0`;
4. allow the release event to execute the fresh release gate and publish Docker Hub/GHCR images;
5. verify published `0.5.0` + `latest` manifests and attestations.

Do not manually overwrite an existing versioned image tag.

---

# 14. Final acceptance criteria

Hardening is complete when all of the following remain true:

1. `FROM alpine:latest` remains.
2. Scriptomatic comes from `main` and is syntax-checked.
3. Toolset comes from latest stable and installs only `chromacat` to `/usr/local/bin`.
4. Static syntax, ShellCheck and actionlint pass.
5. Dependency, runtime and release contracts pass.
6. Supervisor remains PID 1.
7. Health covers only `cron` + `logrotate`.
8. Mounted program failure does not falsely mark core Runner unhealthy.
9. Cronie behavior is validated under LocalDevStack-style bind mounts.
10. Supervisor internal logfile rotation is disabled.
11. External Supervisor logrotate reopens logs through SIGUSR2.
12. Invalid logrotate intervals cannot busy-loop.
13. Rotation failures do not create Supervisor restart storms.
14. Fallback rotation attempts later fragments after one failure.
15. Worker failure retries are bounded and shutdown is prompt.
16. Service-log and Supervisor-log rotation work in the real image.
17. `dexe`/`pexe` preserve argv, TTY behavior and exit status.
18. Standalone Runner starts healthy without Docker socket.
19. Docker helpers work when Docker access is explicitly provided.
20. Current LocalDevStack mount/config contract remains compatible.
21. No new privileged mode/capabilities are required.
22. Legacy move-to-oldlogs paths remain available.
23. amd64 full release gate passes.
24. arm64 build/startup gate passes.
25. Fresh weekly upstream canary protects the moving dependency policy.
26. Release-event publication uses the exact event tag.
27. Weekly refresh rebuilds the latest Runner release against current upstreams and updates only `latest`.
28. Historical version tags are guarded against overwrite.
29. Docker Hub + GHCR share the same build definition.
30. Multi-architecture publication targets amd64 + arm64.
31. SBOM, provenance and registry attestations are enabled.
32. README matches tested behavior.
33. Global LF policy remains intact.
34. Runtime build context excludes tests/docs.
35. Runner remains narrowly scoped.

At the end of this plan, branch CI has demonstrated the full non-publishing acceptance surface. Registry publication itself is intentionally deferred to the `0.5.0` release event.
