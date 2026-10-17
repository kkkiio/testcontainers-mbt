# s3mock

S3 testcontainer for MoonBit. Starts [S3Mock](https://github.com/adobe/S3Mock)
(`adobe/s3mock`), an in-memory S3 server, on a random host port.

```mbt nocheck
///|
async test "uploads" {
  let s3 = @s3mock.run(initial_buckets=["assets"])
  defer s3.cleanup()
  let endpoint = s3.endpoint() // http://localhost:49156
  // endpoint-style S3 client, region "us-east-1", any credentials
}
```

S3Mock does not validate credentials — `access_key()`/`secret_key()` return
the conventional `foo`/`bar` and `region()` returns `us-east-1`.

## Configuration

```mbt nocheck
///|
let s3 = @s3mock.run(
  image="adobe/s3mock:4.4.0",
  initial_buckets=["assets", "backups"],
  wait_timeout_ms=60_000,
  reuse=true,
)
```

Every `run` argument is an optional labeled argument with a default:

| Argument | Default |
| --- | --- |
| `image` | `adobe/s3mock:3.9.1` |
| `initial_buckets` | `[]` |
| `wait_timeout_ms` | `60000` |
| `reuse` | `false` |

## What you get back

```mbt nocheck
s3.endpoint()         // http://host:port
s3.https_endpoint()   // https://host:port
s3.access_key()       // "foo"
s3.secret_key()       // "bar"
s3.region()           // "us-east-1"
s3.initial_buckets()  // buckets created at start
s3.container()        // the underlying @testcontainers.Container
s3.stop()             // docker stop
s3.cleanup()          // docker rm --force --volumes
```
