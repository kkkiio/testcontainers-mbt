// Integration tests. They need a running Docker daemon; every test starts a
// real container.

///|
async test "run to completion and read logs" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "echo hello from the container"])
    .with_wait_for(@testcontainers.WaitStrategy::Exit(0))
    .with_wait_timeout(120)
    .start()
  defer container.cleanup()
  let logs = container.logs()
  assert_true(logs.contains("hello from the container"))
  assert_false(container.is_running())
}

///|
async test "environment variables reach the container" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_env("GREETING", "hi there")
    .with_env("EMPTY", "")
    .with_cmd(["sh", "-c", "printf '%s|%s' \"$GREETING\" \"${EMPTY:-unset}\""])
    .with_wait_for(@testcontainers.WaitStrategy::Exit(0))
    .with_wait_timeout(120)
    .start()
  defer container.cleanup()
  let logs = container.logs()
  assert_true(logs.contains("hi there|unset"))
}

///|
async test "exec runs inside the container" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "60"])
    .start()
  defer container.cleanup()
  let result = container.exec(["sh", "-c", "echo out; echo err >&2; exit 3"])
  assert_eq(result.code, 3)
  assert_eq(result.stdout.trim().to_owned(), "out")
  assert_eq(result.stderr.trim().to_owned(), "err")
  let failing : Result[String, @testcontainers.TestContainerError] = Ok(
    container.exec_checked(["false"]),
  ) catch {
    e => Err(e)
  }
  assert_true(failing is Err(DockerCommandFailed(_)))
}

///|
async test "ports are published on random host ports" {
  let container = @testcontainers.ContainerRequest::new(
      "hashicorp/http-echo:1.0",
    )
    .with_port(8080)
    .with_cmd(["-listen=:8080", "-text=ok"])
    .with_wait_for(@testcontainers.WaitStrategy::TcpPort(8080))
    .with_wait_timeout(60)
    .start()
  defer container.cleanup()
  let port = container.host_port(8080)
  assert_true(port > 0 && port <= 65535)
  assert_eq(container.host_port_opt(8080), Some(port))
  assert_eq(container.host_port_opt(9999), None)
  assert_eq(container.endpoint(8080), "\{container.host()}:\{port}")
  let missing : Result[Int32, @testcontainers.TestContainerError] = Ok(
    container.host_port(9999),
  ) catch {
    e => Err(e)
  }
  assert_true(missing is Err(PortNotMapped(_)))
}

///|
async test "log message wait strategy" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "sleep 0.3; echo READY-MARKER; sleep 60"])
    .with_wait_for(@testcontainers.WaitStrategy::LogMessage("READY-MARKER"))
    .with_wait_timeout(60)
    .start()
  defer container.cleanup()
  assert_true(container.logs().contains("READY-MARKER"))
}

///|
async test "http wait strategy" {
  let container = @testcontainers.ContainerRequest::new(
      "hashicorp/http-echo:1.0",
    )
    .with_port(5678)
    .with_cmd(["-listen=:5678", "-text=healthy"])
    .with_wait_for(@testcontainers.WaitStrategy::HttpGet(5678, "/", 200))
    .with_wait_timeout(60)
    .start()
  defer container.cleanup()
  let url = "http://" + container.endpoint(5678)
  let (response, body) = @http.get(url)
  assert_eq(response.code, 200)
  assert_eq(body.text().trim().to_owned(), "healthy")
}

///|
async test "bind mounts expose host files" {
  let dir = @fs.tmpdir(prefix="testcontainers-mbt")
  @fs.write_file(dir + "/input.txt", "mounted")
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_bind_read_only(dir, "/data")
    .with_cmd(["cat", "/data/input.txt"])
    .with_wait_for(@testcontainers.WaitStrategy::Exit(0))
    .with_wait_timeout(120)
    .start()
  defer container.cleanup()
  assert_true(container.logs().contains("mounted"))
  @fs.rmdir(dir, recursive=true)
}

///|
async test "timeout errors carry the logs and remove the container" {
  let label = "testcontainers-mbt.timeout-test"
  let request = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_label("testcontainers-mbt", label)
    .with_port(9999)
    .with_cmd(["sh", "-c", "echo booting; sleep 60"])
    .with_wait_for(@testcontainers.WaitStrategy::TcpPort(9999))
    .with_wait_timeout_ms(1500)
  let result : Result[
    @testcontainers.Container,
    @testcontainers.TestContainerError,
  ] = Ok(request.start()) catch { e => Err(e) }
  match result {
    Ok(container) => {
      container.cleanup()
      fail("expected the wait strategy to time out")
    }
    Err(error) => {
      let message = error.to_string()
      assert_true(message.contains("did not become ready"))
      assert_true(message.contains("booting"))
    }
  }
  // A failed start must not leak the half-started container.
  let leftovers = @testcontainers.docker([
    "ps",
    "-a",
    "--quiet",
    "--filter",
    "label=testcontainers-mbt=\{label}",
  ])
  assert_eq(leftovers.trim().to_owned(), "")
}

///|
async test "a dead container fails fast instead of timing out" {
  let request = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "echo crashing; exit 7"])
    .with_wait_for(@testcontainers.WaitStrategy::TcpPort(1234))
    .with_wait_timeout_ms(30_000)
  let result : Result[
    @testcontainers.Container,
    @testcontainers.TestContainerError,
  ] = Ok(request.start()) catch { e => Err(e) }
  match result {
    Ok(container) => {
      container.cleanup()
      fail("expected the wait to fail")
    }
    Err(error) => assert_true(error.to_string().contains("is not running"))
  }
}

///|
async test "with_container cleans up after the body" {
  let label = "testcontainers-mbt.with-container"
  let id = @testcontainers.with_container(
    @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_label("testcontainers-mbt", label)
    .with_cmd(["sleep", "60"]),
    container => container.id(),
  )
  assert_true(id.length() >= 12)
  let leftovers = @testcontainers.docker([
    "ps",
    "-a",
    "--quiet",
    "--filter",
    "label=testcontainers-mbt=\{label}",
  ])
  assert_eq(leftovers.trim().to_owned(), "")
}

///|
async test "with_container cleans up when the body raises" {
  let label = "testcontainers-mbt.with-container-error"
  let result : Result[Unit, Error] = Ok(
    @testcontainers.with_container(
      @testcontainers.ContainerRequest::new("alpine:3.21")
      .with_label("testcontainers-mbt", label)
      .with_cmd(["sleep", "60"]),
      fn(_container) raise { raise Failure("body failed") },
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  let leftovers = @testcontainers.docker([
    "ps",
    "-a",
    "--quiet",
    "--filter",
    "label=testcontainers-mbt=\{label}",
  ])
  assert_eq(leftovers.trim().to_owned(), "")
}

///|
async test "cleanup is idempotent" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "60"])
    .start()
  container.cleanup()
  container.cleanup()
  assert_false(container.exists())
}

///|
async test "pulling a missing image fails with a useful error" {
  let request = @testcontainers.ContainerRequest::new(
    "testcontainers-mbt-does-not-exist:nope",
  )
  let result : Result[
    @testcontainers.Container,
    @testcontainers.TestContainerError,
  ] = Ok(request.start()) catch { e => Err(e) }
  match result {
    Ok(container) => {
      container.cleanup()
      fail("expected the image pull to fail")
    }
    Err(error) =>
      assert_true(error.to_string().contains("failed to pull image"))
  }
}

///|
async test "stream_logs yields lines as they are produced" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "sleep 1; echo first; echo second; echo third"])
    .start()
  defer container.cleanup()
  let lines : Array[String] = []
  container.stream_logs(fn(line) { if line != "" { lines.push(line) } })
  assert_eq(lines, ["first", "second", "third"])
}

///|
async test "log options: tail and timestamps" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "for i in 1 2 3 4 5; do echo line-$i; done"])
    .with_wait_for(@testcontainers.WaitStrategy::Exit(0))
    .with_wait_timeout(120)
    .start()
  defer container.cleanup()
  let tailed = container.logs(
    options=@testcontainers.LogOptions::default().with_tail(2),
  )
  assert_true(tailed.contains("line-5"))
  assert_false(tailed.contains("line-1"))
  let stamped = container.logs(
    options=@testcontainers.LogOptions::default().with_timestamps(),
  )
  // RFC3339 nanosecond timestamps look like 2026-10-17T09:00:00.000000000Z
  assert_true(stamped.contains("T"))
  assert_true(stamped.contains("Z"))
}

///|
async test "wait_for can wait again after start" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "sleep 1; echo LATE-READY; sleep 60"])
    .start()
  defer container.cleanup()
  container.wait_for(@testcontainers.WaitStrategy::LogMessage("LATE-READY"))
  assert_true(container.logs().contains("LATE-READY"))
}

///|
async test "auto remove containers disappear after exit" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_auto_remove(true)
    .with_cmd(["sh", "-c", "echo bye"])
    .start()
  // Give docker a moment to reap the container, then poll briefly.
  let mut reaped = false
  for _ in 0..<50 {
    if !container.exists() {
      reaped = true
      break
    }
    @async.sleep(100)
  }
  assert_true(reaped)
}

///|
async test "exit wait can expect a non-zero status" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sh", "-c", "echo failing; exit 3"])
    .with_wait_for(@testcontainers.WaitStrategy::Exit(3))
    .with_wait_timeout(120)
    .start()
  defer container.cleanup()
  let status = container.status()
  assert_eq(status, "exited")
}

///|
async test "pull policy never fails when the image is missing" {
  let request = @testcontainers.ContainerRequest::new(
    "testcontainers-mbt-does-not-exist:nope",
  ).with_pull_policy(@testcontainers.PullPolicy::Never)
  let result : Result[
    @testcontainers.Container,
    @testcontainers.TestContainerError,
  ] = Ok(request.start()) catch { e => Err(e) }
  match result {
    Ok(container) => {
      container.cleanup()
      fail("expected docker run to fail for a missing image")
    }
    Err(error) =>
      assert_true(error.to_string().contains("docker command failed"))
  }
}

///|
async test "healthy strategy rejects images without a health check" {
  let request = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "30"])
    .with_wait_for(@testcontainers.WaitStrategy::Healthy)
    .with_wait_timeout_ms(30_000)
  let result : Result[
    @testcontainers.Container,
    @testcontainers.TestContainerError,
  ] = Ok(request.start()) catch { e => Err(e) }
  match result {
    Ok(container) => {
      container.cleanup()
      fail("expected the health check wait to fail")
    }
    Err(error) => assert_true(error.to_string().contains("no HEALTHCHECK"))
  }
}

///|
async test "any-of wait strategies succeeds when one holds" {
  let container = @testcontainers.ContainerRequest::new(
      "hashicorp/http-echo:1.0",
    )
    .with_port(8080)
    .with_cmd(["-listen=:8080", "-text=ok"])
    .with_wait_for(
      @testcontainers.WaitStrategy::Any([
        @testcontainers.WaitStrategy::LogMessage("this-never-appears"),
        @testcontainers.WaitStrategy::TcpPort(8080),
      ]),
    )
    .with_wait_timeout(60)
    .start()
  defer container.cleanup()
  assert_true(container.is_running())
}

///|
async test "seconds strategy waits" {
  let start = @async.now()
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "60"])
    .with_wait_for(@testcontainers.WaitStrategy::Seconds(1))
    .with_wait_timeout(30)
    .start()
  defer container.cleanup()
  assert_true(@async.now() - start >= 1000)
}

///|
async test "containers carry the management label" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "30"])
    .start()
  defer container.cleanup()
  let label = @testcontainers.docker([
    "inspect",
    "--format",
    "{{index .Config.Labels \"org.testcontainers.mbt\"}}",
    container.id(),
  ])
  assert_eq(label.trim().to_owned(), "true")
}

///|
async test "a hanging exec probe cannot exceed the wait timeout" {
  let started = @async.now()
  let request = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "60"])
    .with_wait_for(
      @testcontainers.WaitStrategy::Exec(["sh", "-c", "sleep 600"]),
    )
    .with_wait_timeout_ms(1_500)
  let result : Result[
    @testcontainers.Container,
    @testcontainers.TestContainerError,
  ] = Ok(request.start()) catch { e => Err(e) }
  let elapsed = @async.now() - started
  match result {
    Ok(container) => {
      container.cleanup()
      fail("expected the exec wait to time out")
    }
    Err(error) =>
      assert_true(error.to_string().contains("did not become ready"))
  }
  // The probe is cancelled at the deadline; allow generous slack for cleanup.
  assert_true(elapsed < 10_000)
}

///|
async test "wait_for reports the effective timeout" {
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "30"])
    .start()
  defer container.cleanup()
  let result : Result[Unit, @testcontainers.TestContainerError] = Ok(
    container.wait_for(
      @testcontainers.WaitStrategy::LogMessage("never-appears"),
      timeout_ms=500,
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => fail("expected the wait to time out")
    Err(error) => assert_true(error.to_string().contains("within 500 ms"))
  }
}

///|
async test "copy files in and out of the container" {
  let dir = @fs.tmpdir(prefix="testcontainers-mbt-copy")
  @fs.write_file(dir + "/in.txt", "copied in")
  let container = @testcontainers.ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "30"])
    .start()
  defer container.cleanup()
  container.copy_to(dir + "/in.txt", "/tmp/in.txt")
  assert_eq(container.exec(["cat", "/tmp/in.txt"]).stdout, "copied in")
  container.copy_from("/tmp/in.txt", dir + "/out.txt")
  assert_eq(@fs.read_file(dir + "/out.txt").text(), "copied in")
  @fs.rmdir(dir, recursive=true)
}
