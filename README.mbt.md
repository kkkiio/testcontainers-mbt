# Testcontainers for MoonBit

[Testcontainers](https://testcontainers.com/) for MoonBit — throwaway Docker
containers for integration tests. Same services as production instead of
mocks, fresh instance per test:

```mbt nocheck
///|
async test "postgres stores rows" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  // ... connect to dsn and run queries ...
}
```

## Prerequisites

- **Docker daemon**: running locally — macOS and Windows work through Docker
  Desktop or OrbStack

## Installation

Only supports the **native** target for now.
Containers are started through the `docker` CLI.

```bash
moon add xziheng/testcontainers
```

Import the packages in `moon.pkg` only for tests:

```text
// your-project/moon.pkg
import {
  "xziheng/testcontainers/postgres",
  "xziheng/testcontainers/mysql",
  "xziheng/testcontainers/s3mock",
} for "test"

import {
  "moonbitlang/async",
} for "test"
```

A package importing testcontainers needs `supported_targets = "native"` in its
`moon.pkg`. To keep a package multi-target, put the container tests in a
dedicated package:

```text
tests/
├── moon.pkg      # import testcontainers for "test"; supported_targets = "native"
└── integration_test.mbt
```

## Usage

### Any image

```mbt nocheck
///|
async test "redis" {
  let container = @testcontainers.ContainerRequest::new("redis:7-alpine")
    .with_port(6379)
    .with_wait_for(@testcontainers.WaitStrategy::TcpPort(6379))
    .with_wait_timeout(60)
    .start()
  defer container.cleanup()
  let port = container.host_port(6379)
  let endpoint = container.endpoint(6379) // localhost:49155
}
```

Ready-made modules for common services live in their own packages:
[postgres](postgres/README.mbt.md), [mysql](mysql/README.mbt.md) and
[s3mock](s3mock/README.mbt.md).

### Scoped helper

MoonBit tests have no automatic teardown callback, so either `defer
container.cleanup()` or let `with_container` do it for you — cleanup also runs
when the body fails or the test is cancelled:

```mbt nocheck
///|
async test "nginx" {
  @testcontainers.with_container(
    @testcontainers.ContainerRequest::new("nginx:1.27-alpine").with_port(80),
    container => {
      let url = "http://" + container.endpoint(80)
      // ...
    },
  )
}
```

### Reusable containers (experimental)

A container marked `with_reuse` keeps running after the test — the next `moon
test`, even in another process, re-attaches to it instead of starting a new
one:

```mbt nocheck
///|
async test "postgres stores rows" {
  let request = @testcontainers.ContainerRequest::new("postgres:16-alpine")
    .with_port(5432)
    .with_env("POSTGRES_PASSWORD", "secret")
    .with_reuse()
  // ...
}
```

Reuse is a local-development opt-in and only activates when
`TESTCONTAINERS_REUSE_ENABLE=true` is set; otherwise the flag is ignored and
tests behave exactly as before.
The container to reuse is chosen by a hash of the whole configuration, so
changing any `with_*` option starts a fresh container. `cleanup()` intentionally
leaves it running — use `container.remove()` to delete it, and reset service
state yourself between tests.

## Wait strategies

`with_wait_for` controls when a started container counts as ready:

| Strategy | Ready when |
| --- | --- |
| `NoWait` | Immediately (the default) |
| `TcpPort(port)` | `port` listens inside the container |
| `HttpGet(port, path, status)` | `GET path` on the mapped port returns `status` |
| `LogMessage(text)` | The container logs contain `text` |
| `Exec(cmd)` | `cmd` exits 0 inside the container |
| `Healthy` | The image's `HEALTHCHECK` is `healthy` |
| `Exit(code)` | The container exited with `code` |
| `Seconds(n)` | `n` seconds passed |
| `All(...)` / `Any(...)` | All / at least one strategy holds |

## What you get back

```mbt nocheck
container.host_port(5432)       // mapped host port
container.endpoint(5432)        // "localhost:49153"
container.logs()                // stdout + stderr
container.exec(["psql", "-c", "SELECT 1"])  // code, stdout, stderr
container.copy_to("schema.sql", "/tmp/schema.sql")
container.copy_from("/tmp/dump.sql", "./dump.sql")
container.stop()                // docker stop
container.remove()              // docker rm --force --volumes
container.cleanup()             // best effort, never raises
```

## Caveats

- **`docker` CLI is the backend.** Commands run without a shell, but values
  passed with `--env` are briefly visible in the host process list.
- **A [Ryuk](https://github.com/testcontainers/moby-ryuk) sidecar reaps
  containers of killed test processes**, like in the official implementations.
  Disable with `TESTCONTAINERS_RYUK_DISABLED=true`; tune with
  `TESTCONTAINERS_RYUK_PRIVILEGED`, `RYUK_CONTAINER_IMAGE`,
  `RYUK_RECONNECTION_TIMEOUT`. Reusable containers are exempt. Leftovers carry
  `org.testcontainers.mbt=true`:
  `docker rm -f $(docker ps -aq --filter label=org.testcontainers.mbt=true)`.
- **Named volumes are not removed** by `cleanup()`; anonymous volumes are.
- **Host networking, UDP ports and HTTPS wait strategies** are not supported.
- Default wait timeout is 60 s (90 s for MySQL, whose first start runs a full
  initialization).

## Credits

The first MoonBit implementation of testcontainers was
[ryota0624/moonbit_test_containers](https://github.com/ryota0624/moonbit_test_containers).
This project started from that code and was updated for current MoonBit and
`moonbitlang/async`. Behaviour follows
[testcontainers-go](https://github.com/testcontainers/testcontainers-go).

Licensed under Apache-2.0. See `NOTICE` for attribution.
