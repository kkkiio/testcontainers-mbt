# testcontainers-mbt AGENTS.md

## Project Structure Guide

A MoonBit library that starts throwaway Docker containers for integration tests.
The root package is the generic engine; each subdirectory is an optional
per-service module built on top of it.

### Repo Structure & Important Files

```text
.
├── moon.mod                      # module `xziheng/testcontainers`, preferred_target = native
├── moon.pkg                      # root package imports + supported_targets = "native"
├── error.mbt                     # TestContainerError (suberror) + Show impl
├── docker.mbt                    # the only place that spawns the `docker` CLI
├── request.mbt                   # ContainerRequest, Mount, WaitStrategy, validation
├── container.mbt                 # start/run, port resolution, exec, stop/remove/cleanup, with_container
├── wait.mbt                      # polling readiness engine + /proc/net/tcp parsing
├── logs.mbt                      # LogOptions, docker logs, stream_logs
├── container_test.mbt            # blackbox integration tests (need Docker)
├── util_wbtest.mbt               # whitebox unit tests for pure helpers
├── postgres/                     # @postgres module (config, run, connection_string)
├── mysql/                        # @mysql module
├── s3mock/                       # @s3mock module (Adobe S3Mock)
├── README.mbt.md                 # user docs (README.md is a symlink)
└── .github/workflows/ci.yml      # check + native tests on Ubuntu with Docker
```

Dependency direction is one-way: modules import the root package, never the
other way around. `postgres/`, `mysql/` and `s3mock/` must not import each
other.

### Request → Container flow

1. `ContainerRequest` describes what to run (image, ports, env, mounts, wait).
2. `ContainerRequest::start` validates, pulls the image if needed, runs
   `docker run -d`, resolves the random host ports from `docker inspect`, then
   polls the wait strategy.
3. `Container` owns the container id and resolved port map. `cleanup()` removes
   it.

## Domain Language

- **Request** — the immutable description of a container to start (`ContainerRequest`); not a running thing.
- **Container** — a started container handle (`Container`), owning an id and a container-port → host-port map.
- **Module** — a package under `postgres/`, `mysql/`, `s3mock/` that wraps a request preset for one service and returns a typed handle.
- **Wait strategy** — the condition that proves the service inside the container is usable, polled after `docker run`.
- **Probe** — one evaluation of a wait strategy (`Ready`, `NotReady`, `Fatal` in `wait.mbt`).
- **Port publication** — `docker run --publish <container port>` without a host port; Docker picks a free host port.
- **Mapping** — the container-port → host-port pair resolved from `docker inspect`, not guessed.

_Avoid_: "image" for a request (an image is only one field), "container" for a request, "check" for a wait strategy.

## Policies & Mandatory Rules

- When adding a Docker interaction, put it in `docker.mbt` (or use `docker` /
  `docker_command` from it). Do not spawn `docker` elsewhere.
- When reporting a Docker failure, raise `DockerCommandFailed` with the rendered
  command and the most useful stream. Never execute through a shell: pass argv
  arrays so values with spaces and quotes stay intact.
- When passing secrets, redact them in messages: `render_command` already
  redacts `--env` values. Do not add new error paths that print env values.
- When adding a readiness check, add a `WaitStrategy` variant plus a `probe_*`
  function in `wait.mbt`, and treat probe errors as "not ready yet" (the poll
  loop swallows them); use `Probe::Fatal` only for conditions that cannot
  change, such as a dead container.
- When adding a service module, mirror `postgres/`: a `*Config` with `new()` +
  `with_*` builders, `run(config?)`, a typed handle with `container()`,
  `cleanup()`, and defaults matching testcontainers-go.
- Do not introduce a WASM/JS fallback. The package is native-only by design.
- Do not add a new dependency on `moonbitlang/core` subpackages without need;
  prefer `moonbitlang/core/encoding/percent`, `core/json`, `core/env` which are
  already used.
- Keep public API changes deliberate: run `moon info` and review the `.mbti`
  diff before committing.

### Test observation: snapshot vs assertion

Choose the observation primitive by what the value is:

- Deterministic pure values — `ContainerRequest::run_args`, `render_command`,
  `WaitStrategy::describe`, module `*Config` defaults,
  `parse_listening_ports`, inspect-JSON projections — snapshot the complete
  value with `inspect` (`debug_inspect` for structs). Do not assert `contains` /
  `has_suffix` on a value whose full form is deterministic, and do not
  enumerate config fields one by one.
- Values Docker assigns at runtime — host ports, container ids, image digests,
  log timestamps — assert the invariant instead (`port > 0`,
  `host_port_opt(5432) == Some(port)`, `endpoint(5432) == host + ":" + port`).
  Never put them in a snapshot. When a value embeds one (a DSN, an endpoint),
  build the complete expected string from the observed port and use
  `assert_eq`.
- Boolean predicates (`exists`, `is_running`, "no leftover containers") and
  single values derivable from the spec: `assert_eq` / `assert_true` /
  `assert_false`.
- Error UX: integration tests match the variant and assert exact payload fields
  (`WaitTimeout(logs~, timeout_ms~, ..)`); `error_test.mbt` snapshots
  `TestContainerError::to_string()` from constructed errors with fixed ids,
  ports and logs. Do not assert English substrings of error messages, except
  for text produced by an external tool (for example Docker's `No such image`).
- Baselines are generated, not hand-written: `moon test <path> --target native
  --update`, then review every diff for leaked ports, ids, temp paths and
  timestamps. Commit the snapshot with the behavior change that caused it.
- `moon cram` and `@test.Test` file snapshots do not apply here: there is no
  CLI and no generated file artifact. The reviewed public-API contract is
  `pkg.generated.mbti` (`moon info`).

## Operation Guide

### Environment

Docker must be running with Linux containers. Verify:

```bash
docker run --rm alpine:3.21 echo ok
```

### Build and test

```bash
moon check --target native
moon test --target native
```

Tests are integration tests: they start real containers. Run a single package
while iterating on a module:

```bash
moon test --target native -p xziheng/testcontainers/postgres
```

Run tests matching a name:

```bash
moon test --target native -f "*timeout*"
```

### Before committing

```bash
moon info
moon fmt
moon test --target native
git diff -- '*.mbti'
```

`moon info` regenerates `pkg.generated.mbti` / `moon.pkg` interfaces; commit the
changes. `moon fmt` formats; do not hand-format.

### Cleaning up leaked containers

Tests clean up after themselves, but a killed test process can leak containers:

```bash
docker ps -a --filter label=org.testcontainers.mbt=true --format '{{.ID}} {{.Image}} {{.Status}}'
ids="$(docker ps -aq --filter label=org.testcontainers.mbt=true)"
[ -z "$ids" ] || docker rm -f $ids
```

### Adding a service module

```bash
mkdir myservice
```

Create `myservice/moon.pkg` with `"xziheng/testcontainers"` imported and
`supported_targets = "native"`, then follow the layout in `postgres/postgres.mbt`
and add `myservice/myservice_test.mbt` that starts a real container.

### Release

1. Bump `version` in `moon.mod` (the release tag must match it).
2. Tag the verified commit and push the tag:
   `git tag v<version> && git push origin v<version>`.
3. Create a **draft** GitHub release on that tag
   (`gh release create v<version> --draft`), review it, then Publish.
   `release.yml` triggers on `release: published`: it verifies the tag matches
   `moon.mod` and runs `moon publish` to mooncakes (needs the `MOONCAKES_TOKEN`
   repo secret).
