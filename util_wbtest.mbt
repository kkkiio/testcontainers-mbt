///|
test "split_image_ref: plain names get the latest tag" {
  assert_eq(split_image_ref("nginx"), ("nginx", "latest"))
  assert_eq(split_image_ref("postgres:16-alpine"), ("postgres", "16-alpine"))
}

///|
test "split_image_ref: registry ports are not tags" {
  assert_eq(
    split_image_ref("localhost:5000/app"),
    ("localhost:5000/app", "latest"),
  )
  assert_eq(
    split_image_ref("localhost:5000/app:1.2"),
    ("localhost:5000/app", "1.2"),
  )
  assert_eq(
    split_image_ref("ghcr.io/org/app:sha-1234"),
    ("ghcr.io/org/app", "sha-1234"),
  )
}

///|
test "split_image_ref: digest references have no tag" {
  assert_eq(
    split_image_ref("alpine@sha256:abc123"),
    ("alpine@sha256:abc123", ""),
  )
}

///|
test "render_command quotes only when needed" {
  assert_eq(
    render_command("docker", ["run", "-d", "alpine"]),
    "docker run -d alpine",
  )
  // Env values are redacted: they may be credentials.
  assert_eq(
    render_command("docker", ["run", "-e", "A=b c"]),
    "docker run -e A=***",
  )
  assert_eq(
    render_command("docker", ["run", "--env", "TOKEN=x"]),
    "docker run --env TOKEN=***",
  )
  assert_eq(render_command("docker", ["x", "a$b"]), "docker x \"a\\$b\"")
}

///|
test "parse_container_id accepts only hex ids" {
  let id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  assert_eq(parse_container_id(id + "\n"), id)
  assert_eq(parse_container_id("[::1]:1234\n" + id), id)
  let result : Result[String, Error] = Ok(
    parse_container_id("pulling from library/alpine\n"),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(TestContainerError::UnexpectedOutput(_)))
}

///|
test "parse_port_number rejects out of range values" {
  assert_eq(parse_port_number("5432"), Some(5432))
  assert_eq(parse_port_number("0"), None)
  assert_eq(parse_port_number("65536"), None)
  assert_eq(parse_port_number("12a"), None)
  assert_eq(parse_port_number(""), None)
}

///|
test "describe covers every wait strategy" {
  // These strings are what WaitTimeout errors show to the user, so the whole
  // vocabulary belongs in one reviewable snapshot.
  debug_inspect(
    [
      WaitStrategy::NoWait.describe(),
      WaitStrategy::Seconds(5).describe(),
      WaitStrategy::TcpPort(5432).describe(),
      WaitStrategy::HttpGet(8080, "/health", 200).describe(),
      WaitStrategy::LogMessage("ready").describe(),
      WaitStrategy::Exec(["pg_isready", "-h", "127.0.0.1"]).describe(),
      WaitStrategy::Healthy.describe(),
      WaitStrategy::Exit(0).describe(),
      WaitStrategy::All([
        WaitStrategy::TcpPort(1),
        WaitStrategy::LogMessage("ready"),
      ]).describe(),
      WaitStrategy::Any([WaitStrategy::TcpPort(1), WaitStrategy::Exit(3)]).describe(),
    ],
    content=(
      #|[
      #|  "no wait",
      #|  "sleep 5s",
      #|  "TCP port 5432",
      #|  "HTTP GET on port 8080 /health returning 200",
      #|  "log message `ready`",
      #|  "exec `pg_isready -h 127.0.0.1`",
      #|  "docker health check",
      #|  "container exit code 0",
      #|  "all of [TCP port 1, log message `ready`]",
      #|  "any of [TCP port 1, container exit code 3]",
      #|]
    ),
  )
}

///|
test "invalid requests are rejected before docker is called" {
  let relative_bind = ContainerRequest::new("alpine").with_bind(
    "relative/path", "/data",
  )
  let result : Result[Unit, Error] = Ok(validate_request(relative_bind)) catch {
    e => Err(e)
  }
  assert_true(result is Err(TestContainerError::InvalidRequest(_)))

  let relative_target = ContainerRequest::new("alpine").with_tmpfs("data")
  let result : Result[Unit, Error] = Ok(validate_request(relative_target)) catch {
    e => Err(e)
  }
  assert_true(result is Err(TestContainerError::InvalidRequest(_)))

  let bad_port = ContainerRequest::new("alpine").with_port(70000)
  let result : Result[Unit, Error] = Ok(validate_request(bad_port)) catch {
    e => Err(e)
  }
  assert_true(result is Err(TestContainerError::InvalidRequest(_)))
}

///|
test "auto_remove cannot be combined with an exit wait" {
  let request = ContainerRequest::new("alpine")
    .with_auto_remove(true)
    .with_wait_for(WaitStrategy::Exit(0))
  let result : Result[Unit, Error] = Ok(validate_request(request)) catch {
    e => Err(e)
  }
  assert_true(result is Err(TestContainerError::InvalidRequest(_)))
}

///|
test "run args" {
  // The complete argv is the review artifact: it shows the per-port
  // `--publish 5432` (no --publish-all / EXPOSE requirement), the management
  // label, env values and where the command starts.
  let request = ContainerRequest::new("postgres:16-alpine")
    .with_port(5432)
    .with_env("POSTGRES_PASSWORD", "a b")
    .with_label("suite", "db")
    .with_cmd(["postgres", "-c", "fsync=off"])
  debug_inspect(
    "docker " + request.run_args().join(" "),
    content=(
      #|"docker run --detach --env POSTGRES_PASSWORD=a b --label org.testcontainers.mbt=true --label suite=db --publish 5432 postgres:16-alpine postgres -c fsync=off"
    ),
  )
}

///|
test "run args: entrypoint becomes --entrypoint plus leading command args" {
  let request = ContainerRequest::new("alpine")
    .with_entrypoint(["/bin/sh", "-c"])
    .with_cmd(["echo hi"])
  debug_inspect(
    "docker " + request.run_args().join(" "),
    content=(
      #|"docker run --detach --label org.testcontainers.mbt=true --entrypoint /bin/sh alpine -c echo hi"
    ),
  )
}

///|
test "run args: pull policy never is enforced by the daemon" {
  // Only `Never` needs a daemon flag: `Missing` is docker's default and
  // `Always` is an explicit pull in `ensure_image`.
  let base = ContainerRequest::new("alpine:3.21")
  debug_inspect(
    [PullPolicy::Missing, PullPolicy::Always, PullPolicy::Never].map(policy => {
      "docker " + base.with_pull_policy(policy).run_args().join(" ")
    }),
    content=(
      #|[
      #|  "docker run --detach --label org.testcontainers.mbt=true alpine:3.21",
      #|  "docker run --detach --label org.testcontainers.mbt=true alpine:3.21",
      #|  "docker run --detach --pull never --label org.testcontainers.mbt=true alpine:3.21",
      #|]
    ),
  )
}

///|
test "parse_listening_ports finds listeners only" {
  let sample = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
    "   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n" +
    "   1: 0100007F:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0\n" +
    "   2: 0100007F:9C40 0100007F:1F90 01 00000000:00000000 00:00000000 00000000     0        0 12347 1 0000000000000000 100 0 0 10 0\n"
  // Only LISTEN (0A) entries are returned; 40000 is ESTABLISHED (01).
  debug_inspect(
    parse_listening_ports(sample),
    content=(
      #|[8080, 5432]
    ),
  )
}

///|
test "uri_scheme and uri_hostname split docker host URIs" {
  assert_eq(uri_scheme("tcp://docker.example.com:2375"), "tcp")
  assert_eq(uri_scheme("unix:///var/run/docker.sock"), "unix")
  assert_eq(uri_scheme("/var/run/docker.sock"), "")
  assert_eq(uri_scheme(""), "")
  assert_eq(uri_hostname("tcp://docker.example.com:2375"), "docker.example.com")
  assert_eq(uri_hostname("tcp://docker.example.com"), "docker.example.com")
  assert_eq(uri_hostname("https://user@10.0.0.2:2376/certs"), "10.0.0.2")
  assert_eq(uri_hostname("tcp://[fd00::1]:2375"), "fd00::1")
}

///|
test "parse_hex_port" {
  assert_eq(parse_hex_port("1F90"), Some(8080))
  assert_eq(parse_hex_port("1538"), Some(5432))
  assert_eq(parse_hex_port("0000"), Some(0))
  assert_eq(parse_hex_port("ZZZZ"), None)
  assert_eq(parse_hex_port(""), None)
}
