# Testcontainers for MoonBit

Throwaway Docker containers for MoonBit integration tests.

`testcontainers` starts real services — Postgres, MySQL, S3, anything with a
Docker image — on random host ports, waits until they are actually ready, and
hands you a connection string. Tests use the same software as production
instead of a mock, and each test gets a fresh instance.

```moonbit nocheck
///|
async test "postgres stores rows" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  // ... connect to dsn and run queries ...
}
```

## Requirements

- **MoonBit native backend.** Containers are started by running the `docker`
  CLI, which needs an operating system; the package declares
  `supported_targets = "native"`, so run `moon test --target native`.
- **Docker** installed and running, with the `docker` CLI on `PATH`.
  Linux containers are required (macOS and Windows work through Docker Desktop).
- No Docker socket permissions beyond what the CLI already has.

## Installation

The module is not published on mooncakes.io yet, so use it from a checkout.
Clone it next to your project:

```bash
git clone https://github.com/kkkiio/testcontainers-mbt
```

Register both modules in your workspace and declare the dependency in your
module:

```text
# moon.work, at the root of your project
members = [
  "./your-project",
  "../testcontainers-mbt",
]
```

```text
// your-project/moon.mod
name = "you/app"
version = "0.1.0"

// Containers are started as processes, so tests run on the native backend.
preferred_target = "native"

import {
  // The version must match `version` in testcontainers-mbt/moon.mod.
  "xziheng/testcontainers@0.1.0",
  // Needed for your own `async test` blocks.
  "moonbitlang/async@0.22.5",
}
```

Import the packages you use only in tests:

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

Then run `moon test --target native` (or rely on `preferred_target = "native"`
and run `moon test`).

Target constraints apply per **package**: a package whose `moon.pkg` imports
testcontainers must declare `supported_targets = "native"`, because
`moon check` and `moon test` also compile the test code of that package. If
such a package is built for another backend, MoonBit fails with
`Selected backend 'wasm-gc' is incompatible with the dependency graph`.

If the same package also ships Wasm code, move the container tests into their
own package instead of marking the production package native-only:

```text
your-project/
├── moon.mod          # imports xziheng/testcontainers@0.1.0 + moonbitlang/async
├── moon.pkg          # production code, no testcontainers import
├── src.mbt
└── tests/
    ├── moon.pkg      # import testcontainers for "test"; supported_targets = "native"
    └── integration_test.mbt
```

`moon build --target wasm-gc` then builds only the production package, while
`moon test --target native` runs both. This layout is verified: no separate
workspace module is needed.

Once the module is published, `moon add xziheng/testcontainers` replaces the
workspace setup.

## Usage

### A database in one line

```mbt nocheck
///|
async test "postgres" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  // postgres://postgres:postgres@localhost:49153/postgres?sslmode=disable
}
```

```mbt nocheck
///|
async test "mysql" {
  let db = @mysql.run()
  defer db.cleanup()
  // mysql://test:test@localhost:49154/test
  let url = db.connection_string()
  // test:test@tcp(localhost:49154)/test
  let dsn = db.dsn()
}
```

Both modules accept a config when the defaults are not enough:

```mbt nocheck
///|
let pg = @postgres.run(
  config=@postgres.PostgresConfig::new()
    .with_image("postgis/postgis:16-3.4")
    .with_credentials("app", "s3cr3t")
    .with_database("appdb"),
)
```

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

### Scoped helper

MoonBit tests have no automatic teardown callback, so either `defer
container.cleanup()` or let `with_container` do it for you. Cleanup also runs
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

### S3 without AWS

```mbt nocheck
///|
async test "uploads" {
  let s3 = @s3mock.run(
    config=@s3mock.S3MockConfig::new().with_initial_buckets(["assets"]),
  )
  defer s3.cleanup()
  let endpoint = s3.endpoint() // http://localhost:49156
  // endpoint style S3 client, region "us-east-1", any credentials
}
```

## Wait strategies

A container is not ready when Docker says it started; it is ready when the
service inside can answer. Pick a strategy with `with_wait_for`:

| Strategy | Ready when |
| --- | --- |
| `NoWait` | Immediately after `docker run` (the default) |
| `TcpPort(port)` | Something inside the container listens on `port` (fallback: host TCP connect) |
| `HttpGet(port, path, status)` | `GET http://host:mapped_port/path` returns `status` |
| `LogMessage(text)` | The container logs contain `text` |
| `Exec(cmd)` | `docker exec <id> cmd...` exits with 0, e.g. `Exec(["pg_isready", "-h", "127.0.0.1"])` |
| `Healthy` | The image's `HEALTHCHECK` reports `healthy` |
| `Exit(code)` | The container exited with `code` (for one-shot jobs) |
| `Seconds(n)` | `n` seconds passed (last resort) |
| `All([...])` / `Any([...])` | All / at least one of the strategies hold |

`TcpPort` checks `/proc/net/tcp` inside the container instead of only opening a
host connection. This matters because Docker's userland proxy accepts host
connections to published ports even when nothing listens inside the container.

On timeout the error message contains the last 200 log lines and the
half-started container is removed.

## What you get back

```mbt nocheck
container.id()                  // container id
container.host()                // "localhost" (override with TESTCONTAINERS_HOST_OVERRIDE)
container.host_port(5432)       // mapped host port
container.endpoint(5432)        // "localhost:49153"
container.logs()                // stdout + stderr
container.logs(options=@testcontainers.LogOptions::default().with_tail(50))
container.exec(["psql", "-c", "SELECT 1"])  // code, stdout, stderr
container.exec_checked([...])   // raises on non-zero exit
container.copy_to("schema.sql", "/tmp/schema.sql")    // docker cp in
container.copy_from("/tmp/dump.sql", "./dump.sql")    // docker cp out
container.is_running()          // docker state == running
container.stop()                // docker stop
container.remove()              // docker rm --force --volumes
container.cleanup()             // best effort, never raises
```

## Caveats

- **Native only.** Wasm/JS targets cannot spawn processes.
- **Linux containers only.** Windows containers are not supported.
- **The `docker` CLI is the backend.** Commands are executed without a shell,
  so arguments are never re-interpreted, but values passed with `--env` are
  briefly visible in the host process list. Error messages redact `--env`
  values.
- **No automatic cleanup at process exit.** Use `defer`, `with_container`, or
  your own test harness wrapper. Every container is labeled, so containers
  leaked by a killed test process can be found and removed with
  `ids="$(docker ps -aq --filter label=org.testcontainers.mbt=true)"; [ -z "$ids" ] || docker rm -f $ids`.
- **Named volumes are not removed** by `cleanup()`; anonymous volumes are.
- **Host networking is not supported**; every port is published on a random
  host port.
- **UDP ports and HTTPS wait strategies** are not implemented yet.
- Wait strategies poll every 100 ms; the default timeout is 60 s (90 s for the
  MySQL module, whose first start runs a full initialization).

## Credits

The first MoonBit implementation of testcontainers was
[ryota0624/moonbit_test_containers](https://github.com/ryota0624/moonbit_test_containers).
This project started from that code and was updated for current MoonBit and
`moonbitlang/async`, with fixes for port publication, readiness detection and
error reporting. Behaviour follows
[testcontainers-go](https://github.com/testcontainers/testcontainers-go).

Licensed under Apache-2.0. See `NOTICE` for attribution.
