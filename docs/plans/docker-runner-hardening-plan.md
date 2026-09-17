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
- Phase 5 — Architecture and supply chain: **implemented and passing**
- Phase 6 — Publishing modernization: **implemented and contract-validated**
- Phase 7 — Documentation/integration/release closure: **implemented and passing**

There is intentionally **no separate upstream-canary workflow**. The weekly Docker publish refresh is the single scheduled fresh-upstream path: it rebuilds the latest stable Runner release against current Alpine/Scriptomatic/Toolset, runs release gates, and updates only `latest`.

---

# 1. Product boundary

`docker-runner` remains a small infrastructure companion image with two supported modes:

1. **LocalDevStack-integrated** — scheduler configuration, service logs and optionally the Docker socket are mounted into Runner.
2. **Standalone** — Runner starts by itself with Supervisor + Cronie + logrotate; all external mounts and Docker access are optional.

Runner owns only:

- Supervisor as PID 1;
- Cronie scheduling;
- log rotation;
- thin Docker exec helpers (`dexe`, `pexe`) when Docker access is supplied;
- the existing interactive banner helper.

Runner must not become a generic application-runtime image or a second `docker-tools` control plane.

---

# 2. Dependency policy

## Alpine

Keep exactly:

```dockerfile
FROM alpine:latest
```

Alpine is intentionally moving. Compatibility is protected by normal CI plus the weekly fresh `latest` rebuild/publish gate rather than by source pinning.

## Scriptomatic

Consume:

```text
https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh
```

Safeguards:

- HTTPS download;
- fail-fast transfer;
- non-empty payload check;
- `bash -n` syntax validation;
- dependency contract rejects `master` and version/SHA pins;
- weekly publish refresh rebuilds against current `main` before updating `latest`.

## Toolset

Install only `chromacat` from the latest stable Toolset release:

```bash
curl -fsSLo /tmp/toolset-install.sh \
  "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"
bash /tmp/toolset-install.sh --prefix /usr/local/bin chromacat
rm -f /tmp/toolset-install.sh
```

Runner does not install Toolset `--all`.

## Traceability model

Because Alpine, Scriptomatic and Toolset intentionally move, the target is **immutable version publication + auditable resolved inputs**, not byte-identical future rebuilds.

Publishing records/exposes:

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
- immutable version tags for pinned consumers;
- Supervisor PID 1;
- `/etc/supervisor/conf.d/*.conf`;
- `/etc/cron.d`;
- `/global/log`;
- `/global/movelog` and `/global/oldlogs`;
- `/var/log/supervisor`;
- `dexe` and `pexe`;
- exact argument forwarding and exit-code propagation;
- TTY auto-detection;
- optional Docker socket;
- root execution for this infrastructure role.

Standalone startup remains valid without LocalDevStack or `/var/run/docker.sock`:

```bash
docker run -d --name runner infocyph/runner:latest
```

---

# 4. Validation and CI — implemented

Repository-native tests include:

```text
tests/
├── assertions.sh
├── static.sh
├── dependency-contract.sh
├── runtime-contract.sh
├── release-contract.sh
├── compose-contract.sh
├── helpers-smoke.sh
├── standalone-smoke.sh
├── supervisor-smoke.sh
├── cron-smoke.sh
├── logrotate-smoke.sh
├── docker-integration-smoke.sh
├── localdevstack-contract.sh
└── release-gate.sh
```

Permanent `Check` workflow coverage:

- shell syntax;
- LF-only source/config/workflow/example files;
- ShellCheck;
- dependency contracts;
- runtime contracts;
- publishing/release contracts;
- Docker Compose example validation;
- deterministic helper tests;
- actionlint;
- real amd64 image build;
- final shared release gate;
- arm64 Buildx/QEMU build and startup smoke.

`plan/**`, `feature/**`, and `fix/**` pushes are validated in addition to the normal main/PR surfaces.

The same `tests/release-gate.sh` is used by normal CI and publishing so release behavior cannot silently bypass the runtime behavior proven in branch/PR CI.

---

# 5. Runtime hardening — implemented

## Health

`scripts/runner-healthcheck.sh` checks Supervisor connectivity and only Runner-owned core programs:

```text
cron
logrotate
```

Mounted application programs are deliberately excluded from container health.

## Supervisor log ownership

Supervisor internal size rotation is disabled:

```ini
logfile_maxbytes=0
logfile_backups=0
```

External logrotate is the single rotation owner.

When Supervisor logs rotate, logrotate reads `/run/supervisord.pid` and sends **SIGUSR2** so Supervisor closes and reopens log descriptors.

## Cronie

Runner retains:

```text
/usr/sbin/crond -f -P -p
```

Testing proved permissive `-p` behavior is useful for cross-platform host bind-mounted cron files. `-P` retains the daemon PATH.

Container `TZ` is not assumed to become every job's timezone; timezone-sensitive jobs should define `TZ=...` in the cron table.

## Logrotate worker

Implemented behavior:

- validates `LOGROTATE_INTERVAL` as a positive integer;
- invalid normal interval falls back to `3600`;
- `LOGROTATE_FAILURE_INTERVAL` defaults to `60`;
- validates state path/directory;
- fallback mode attempts later fragments after one failure;
- rotation errors do not terminate into Supervisor restart storms;
- failures retry on a bounded interval;
- success returns to the normal interval;
- TERM/INT interrupts sleep and exits cleanly;
- impossible initialization failures remain fatal.

---

# 6. Runtime/image smoke — implemented and passing

The amd64 release gate proves:

- standalone startup without Docker socket;
- Supervisor PID 1;
- healthy `cron` + `logrotate`;
- clean shutdown;
- non-core Supervisor failure does not poison core health;
- core failure does make health fail;
- Cronie system-style jobs execute;
- permissive host-mount Cronie behavior works;
- custom PATH and explicit cron-table timezone behavior work;
- bundled logrotate configs parse;
- `/global/log` rotation works;
- logrotate state is created;
- Supervisor logs rotate and reopen through SIGUSR2;
- invalid fragments do not restart-loop the worker;
- fallback continues after a failed fragment;
- bounded failure retry works;
- `dexe` real non-TTY and PTY paths work;
- `pexe` real argument forwarding works;
- Docker target exit status propagates;
- current LocalDevStack mount shape works;
- LocalDevStack-style timezone, Docker socket, sibling execution and restart recovery work.

Package review conclusion: **no package removals for 0.5.0**. `gawk` may be reconsidered only in a dedicated future compatibility pass.

---

# 7. Architecture and supply chain — implemented

Supported publish targets:

```text
linux/amd64
linux/arm64
```

arm64 is validated with QEMU using command and real Runner startup/health smoke in normal CI.

The publish workflow additionally fresh-builds both amd64 and arm64 release candidates against current moving upstreams before registry login/push. The final multi-architecture publication reuses those tested caches.

Supply-chain output includes:

- BuildKit `provenance: mode=max`;
- SBOM;
- OCI source/revision/version metadata;
- manifest digest visibility;
- Docker Hub + GHCR attestations through `actions/attest@v4`;
- resolved upstream information in workflow summaries.

Dependabot is configured for weekly GitHub Actions updates only.

No dedicated upstream-canary workflow is required because the scheduled weekly publish refresh already provides the fresh-upstream build/test path before updating `latest`.

---

# 8. Docker publishing — implemented

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

1. use `github.event.release.tag_name` as the exact source release;
2. checkout that exact tag;
3. fresh-build amd64 and arm64 candidates against current moving dependencies;
4. run the complete amd64 release gate and arm64 startup gate;
5. ensure version tags do not already exist in Docker Hub or GHCR;
6. publish `<release-tag>` and `latest`;
7. publish a multi-architecture amd64/arm64 manifest;
8. emit SBOM/provenance and registry attestations;
9. summarize digest and resolved build inputs.

## Weekly refresh

On the weekly schedule:

1. resolve GitHub's latest **stable** Runner release;
2. checkout that immutable Runner source;
3. fresh-build amd64 and arm64 against current Alpine/Scriptomatic/Toolset;
4. run release gates;
5. publish **only `latest`**;
6. never overwrite/reissue the historical version tag.

This scheduled refresh replaces the need for a separate upstream canary.

## Current action baselines

- `actions/checkout@v7`;
- `docker/login-action@v4`;
- `docker/metadata-action@v6`;
- `docker/setup-buildx-action@v4`;
- `docker/setup-qemu-action@v4`;
- `docker/build-push-action@v7`;
- `actions/attest@v4`.

---

# 9. Docker Compose examples — implemented and validated

Repository examples:

```text
examples/docker-compose.yml
examples/docker-compose.docker.yml
```

`docker-compose.yml` is standalone-first and does not mount `/var/run/docker.sock`.

It demonstrates:

- `infocyph/runner:latest`;
- timezone + logrotate interval environment variables;
- read-only Supervisor config mount;
- read-only Cronie config mount;
- `/global/log` bind mount;
- persistent Supervisor log volume;
- persistent logrotate state volume.

`docker-compose.docker.yml` is an explicit opt-in override that adds only:

```text
/var/run/docker.sock:/var/run/docker.sock
```

`tests/compose-contract.sh` enforces the safety contract and runs:

```bash
docker compose -f examples/docker-compose.yml config -q
docker compose -f examples/docker-compose.yml -f examples/docker-compose.docker.yml config -q
```

Neither example enables privileged mode.

---

# 10. LocalDevStack compatibility — implemented

LocalDevStack remains the primary ecosystem compatibility target and continues to consume:

```text
image: infocyph/runner:latest
```

The release gate reads current LocalDevStack `main` and validates its Runner integration surface, including:

```text
configuration/scheduler/supervisor -> /etc/supervisor/conf.d:ro
configuration/scheduler/cron-jobs  -> /etc/cron.d:ro
logs/runner                         -> /var/log/supervisor
logs/<service>                      -> /global/log/<service>
/var/run/docker.sock               -> /var/run/docker.sock
```

No LocalDevStack-specific network, hostname, container name or host path is baked into Runner.

## Logrotate state decision

LocalDevStack does not currently persist `/var/lib/logrotate` across container recreation. For 0.5.0 this remains an orchestration choice rather than a Runner requirement.

---

# 11. Documentation and repository support — implemented

README documents:

- standalone-first usage;
- validated Compose usage;
- optional Docker-socket override;
- LocalDevStack role;
- core-only health semantics;
- actual Cronie flags and timezone behavior;
- logrotate normal/failure intervals and state persistence;
- explicit supported log glob depths;
- Supervisor SIGUSR2 reopen behavior;
- legacy move-to-oldlogs compatibility;
- Docker socket privilege boundary;
- amd64/arm64 support;
- intentional moving dependencies;
- release + weekly `latest` refresh semantics.

Repository support decisions:

- global LF policy remains `* text eol=lf`;
- `.dockerignore` excludes docs/tests/examples from runtime build context;
- tests/examples remain available to CI from repository checkout;
- no unnecessary generated artifacts require `.gitignore` expansion.

---

# 12. Security/privilege boundary

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

Mounting `/var/run/docker.sock` remains an explicit, documented host-control boundary.

---

# 13. Deferred ideas / explicit non-goals for 0.5.0

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
- a dedicated upstream-canary workflow;
- config filesystem watchers;
- replacing Supervisor or Cronie;
- application runtimes/databases/web servers;
- making Docker socket mandatory;
- removing legacy log paths without deprecation;
- moving LocalDevStack orchestration into Runner.

Keep Runner small and boring.

---

# 14. Release decision

The hardening work is additive and preserves established integration surfaces while materially expanding tested behavior, architecture support, workflow quality and observability.

Target release: **0.5.0**.

Before creating the release:

1. merge the hardened branch to `main` through the normal repository process;
2. ensure final `main` Check workflow is green;
3. create/publish GitHub release `0.5.0`;
4. allow the release event to run fresh amd64/arm64 gates and publish Docker Hub/GHCR images;
5. verify published `0.5.0` + `latest` manifests and attestations.

Do not manually overwrite an existing versioned image tag.

---

# 15. Final acceptance criteria

Hardening is complete when all of the following remain true:

1. `FROM alpine:latest` remains.
2. Scriptomatic comes from `main` and is syntax-checked.
3. Toolset comes from latest stable and installs only `chromacat` to `/usr/local/bin`.
4. Static syntax, ShellCheck and actionlint pass.
5. Dependency, runtime, release and Compose contracts pass.
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
25. No dedicated upstream-canary workflow exists.
26. Weekly publish refresh is the scheduled fresh-upstream validation/publish path.
27. Release-event publication uses the exact event tag.
28. Weekly refresh resolves the latest stable release and updates only `latest`.
29. Historical version tags are guarded against overwrite.
30. Docker Hub + GHCR share the same build definition.
31. Multi-architecture publication targets amd64 + arm64.
32. SBOM, provenance and registry attestations are enabled.
33. Base and Docker-socket Compose examples validate with `docker compose config -q`.
34. Base Compose example does not mount Docker socket or enable privileged mode.
35. README matches tested behavior.
36. Global LF policy remains intact.
37. Runtime build context excludes tests/docs/examples.
38. Runner remains narrowly scoped.

At the end of this plan, branch CI demonstrates the full non-publishing acceptance surface. Registry publication itself remains deferred to the `0.5.0` release event.
