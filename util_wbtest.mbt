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
  let result : Result[String, TestContainerError] = Ok(
    parse_container_id("pulling from library/alpine\n"),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(UnexpectedOutput(_)))
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
test "describe is human readable" {
  assert_eq(WaitStrategy::TcpPort(5432).describe(), "TCP port 5432")
  assert_eq(
    WaitStrategy::All([
      WaitStrategy::TcpPort(1),
      WaitStrategy::LogMessage("ready"),
    ]).describe(),
    "all of [TCP port 1, log message `ready`]",
  )
}

///|
test "invalid requests are rejected before docker is called" {
  let relative_bind = ContainerRequest::new("alpine").with_bind(
    "relative/path", "/data",
  )
  let result : Result[Unit, TestContainerError] = Ok(
    validate_request(relative_bind),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(InvalidRequest(_)))

  let relative_target = ContainerRequest::new("alpine").with_tmpfs("data")
  let result : Result[Unit, TestContainerError] = Ok(
    validate_request(relative_target),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(InvalidRequest(_)))

  let bad_port = ContainerRequest::new("alpine").with_port(70000)
  let result : Result[Unit, TestContainerError] = Ok(validate_request(bad_port)) catch {
    e => Err(e)
  }
  assert_true(result is Err(InvalidRequest(_)))
}

///|
test "auto_remove cannot be combined with an exit wait" {
  let request = ContainerRequest::new("alpine")
    .with_auto_remove(true)
    .with_wait_for(WaitStrategy::Exit(0))
  let result : Result[Unit, TestContainerError] = Ok(validate_request(request)) catch {
    e => Err(e)
  }
  assert_true(result is Err(InvalidRequest(_)))
}

///|
test "run args use per-port publishing, not --publish-all" {
  let request = ContainerRequest::new("postgres:16-alpine")
    .with_port(5432)
    .with_env("POSTGRES_PASSWORD", "a b")
    .with_label("suite", "db")
    .with_cmd(["postgres", "-c", "fsync=off"])
  let args = request.run_args()
  assert_false(args.contains("-P"))
  assert_false(args.contains("--publish-all"))
  // -p 5432 without a host port: docker picks a free port, no EXPOSE needed.
  assert_true(args.contains("--publish"))
  let joined = args.join(" ")
  assert_true(joined.contains("POSTGRES_PASSWORD=a b"))
  assert_true(joined.has_suffix("postgres:16-alpine postgres -c fsync=off"))
}

///|
test "entrypoint becomes --entrypoint plus leading command args" {
  let request = ContainerRequest::new("alpine")
    .with_entrypoint(["/bin/sh", "-c"])
    .with_cmd(["echo hi"])
  let args = request.run_args()
  let joined = args.join(" ")
  assert_true(joined.contains("--entrypoint /bin/sh alpine -c echo hi"))
}

///|
test "parse_listening_ports finds listeners only" {
  let sample = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
    "   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n" +
    "   1: 0100007F:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0\n" +
    "   2: 0100007F:9C40 0100007F:1F90 01 00000000:00000000 00:00000000 00000000     0        0 12347 1 0000000000000000 100 0 0 10 0\n"
  let ports = parse_listening_ports(sample)
  assert_true(ports.contains(8080))
  assert_true(ports.contains(5432))
  // ESTABLISHED (01) is not a listening port.
  assert_false(ports.contains(40000))
}

///|
test "parse_hex_port" {
  assert_eq(parse_hex_port("1F90"), Some(8080))
  assert_eq(parse_hex_port("1538"), Some(5432))
  assert_eq(parse_hex_port("0000"), Some(0))
  assert_eq(parse_hex_port("ZZZZ"), None)
  assert_eq(parse_hex_port(""), None)
}
