# mysql

MySQL testcontainer for MoonBit. Starts `mysql:8.4` on a random host port and
waits until the server accepts connections (the first start runs a full
initialization, hence the 90-second default timeout).

```mbt nocheck
///|
async test "mysql" {
  let db = @mysql.run()
  defer db.cleanup()
  // mysql://test:test@localhost:49154/test
  let url = db.connection_string()
  // test:test@tcp(localhost:49154)/test — Go driver style
  let dsn = db.dsn()
}
```

## Configuration

```mbt nocheck
///|
let db = @mysql.run(
  image="mysql:8.0",
  username="app",
  password="s3cr3t",
  root_password="r00t",
  database="appdb",
  port=3306,
  wait_timeout_ms=120_000,
  reuse=true,
)
```

Every `run` argument is an optional labeled argument with a default:

| Argument | Default |
| --- | --- |
| `image` | `mysql:8.4` |
| `database` | `test` |
| `username` | `test` |
| `password` | `test` |
| `root_password` | `test` |
| `port` | `3306` |
| `wait_timeout_ms` | `90000` |
| `reuse` | `false` |

## What you get back

```mbt nocheck
db.connection_string()   // mysql://user:pass@host:port/db
db.dsn()                 // user:pass@tcp(host:port)/db
db.host() / db.port() / db.database()
db.username() / db.password()
db.container()           // the underlying @testcontainers.Container
db.stop()                // docker stop
db.cleanup()             // docker rm --force --volumes
```

To keep the database between test runs for faster local iteration, combine
with [reusable containers](../README.mbt.md#reusable-containers-experimental).
