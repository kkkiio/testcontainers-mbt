# postgres

PostgreSQL testcontainer for MoonBit. Starts `postgres:16-alpine` on a random
host port and waits until `pg_isready` answers.

```mbt nocheck
///|
async test "postgres" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  // postgres://postgres:postgres@localhost:49153/postgres?sslmode=disable
}
```

## Configuration

```mbt nocheck
///|
let pg = @postgres.run(
  image="postgis/postgis:16-3.4",
  username="app",
  password="s3cr3t",
  database="appdb",
  port=5432,
  wait_timeout_ms=90_000,
  reuse=true,
)
```

Every `run` argument is an optional labeled argument with a default:

| Argument | Default |
| --- | --- |
| `image` | `postgres:16-alpine` |
| `database` | `postgres` |
| `username` | `postgres` |
| `password` | `postgres` |
| `port` | `5432` |
| `wait_timeout_ms` | `60000` |
| `reuse` | `false` |

## What you get back

```mbt nocheck
pg.connection_string(ssl_mode="disable")  // postgres://user:pass@host:port/db?sslmode=disable
pg.connection_string()                    // same, without the query parameter
pg.host() / pg.port() / pg.database()
pg.username() / pg.password()
pg.container()                            // the underlying @testcontainers.Container
pg.exec(["psql", "-U", "postgres", "-c", "SELECT 1"])
pg.stop()                                 // docker stop
pg.cleanup()                              // docker rm --force --volumes
```

Pass `ssl_mode="disable"` for plain local containers; by default the
connection string carries no `sslmode` parameter.

To keep the database between test runs for faster local iteration, combine
with [reusable containers](../README.mbt.md#reusable-containers-experimental).
