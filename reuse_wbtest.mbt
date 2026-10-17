// Whitebox tests: exercise the reuse internals directly. The public path
// (`ContainerRequest::start` on a `with_reuse` request) additionally requires
// `TESTCONTAINERS_REUSE_ENABLE` in the environment, so tests call
// `start_reusable` to cover the mechanism itself.

///|
test "hex64 renders exactly 16 lowercase hex digits" {
  assert_eq(hex64(0UL), "0000000000000000")
  assert_eq(hex64(0xffffffffffffffffUL), "ffffffffffffffff")
  assert_eq(hex64(0x1a2bUL), "0000000000001a2b")
}

///|
test "ascii_lower only touches ASCII letters" {
  assert_eq(ascii_lower("TRUE"), "true")
  assert_eq(ascii_lower("Docker_Host1"), "docker_host1")
  assert_eq(ascii_lower(""), "")
}

///|
test "fnv1a_hex is deterministic and order-sensitive" {
  let hash = fnv1a_hex(["run", "--detach", "alpine"])
  assert_eq(hash, fnv1a_hex(["run", "--detach", "alpine"]))
  assert_eq(hash.length(), 16)
  assert_true(hash != fnv1a_hex(["run", "--detach", "alpine:3.21"]))
  assert_true(hash != fnv1a_hex(["run", "alpine", "--detach"]))
}

///|
test "reuse_hash covers configuration but not the session" {
  let request = ContainerRequest::new("alpine:3.21").with_port(80)
  let before = request.reuse_hash()
  session.val = Some("wbtest-session")
  defer {
    session.val = None
  }
  // The session id differs per test process and must not enter the hash.
  assert_eq(request.reuse_hash(), before)
  assert_true(request.reuse_hash() != request.with_env("A", "b").reuse_hash())
  assert_true(request.reuse_hash() != request.with_port(443).reuse_hash())
}

///|
test "run_args carries the session label only when not reusing" {
  session.val = Some("wbtest-session")
  defer {
    session.val = None
  }
  let args = ContainerRequest::new("alpine").run_args()
  assert_true(args.contains("\{LABEL_SESSION}=wbtest-session"))
  let reuse_args = { ..ContainerRequest::new("alpine"), reuse: true, }.run_args()
  assert_true(!reuse_args.contains("\{LABEL_SESSION}=wbtest-session"))
}

///|
test "validate_request rejects reuse with auto_remove" {
  let request = ContainerRequest::new("alpine")
    .with_reuse()
    .with_auto_remove(true)
  let result : Result[Unit, TestContainerError] = Ok(validate_request(request)) catch {
    e => Err(e)
  }
  assert_true(result is Err(InvalidRequest(_)))
}

// Each reuse test stamps a unique env marker into its request so the
// configuration hashes cannot collide: identical requests share a container
// by design, and `moon test` runs the async tests in this file concurrently.

///|
async test "start_reusable attaches the same container twice" {
  let request = ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "600"])
    .with_env("REUSE_TEST", "twice")
  let first = request.start_reusable()
  defer (first.remove() catch { _ => () })
  let second = request.start_reusable()
  assert_eq(first.id(), second.id())
  assert_true(second.reusable)
  // `cleanup` is a no-op for reusable containers; they outlive the test.
  second.cleanup()
  assert_true(second.exists())
}

///|
async test "start_reusable reuses a stopped container" {
  let request = ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "600"])
    .with_env("REUSE_TEST", "stopped")
  let first = request.start_reusable()
  defer (first.remove() catch { _ => () })
  first.stop()
  let second = request.start_reusable()
  assert_eq(first.id(), second.id())
  assert_true(second.is_running())
}

///|
async test "different configurations get different reusable containers" {
  let base = ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "600"])
    .with_env("REUSE_TEST", "configs")
  let first = base.start_reusable()
  defer (first.remove() catch { _ => () })
  let second = base.with_env("EXTRA", "1").start_reusable()
  defer (second.remove() catch { _ => () })
  assert_true(first.id() != second.id())
}

///|
async test "containers carry a session label while the reaper is active" {
  guard !reaper_disabled() else { return }
  let container = ContainerRequest::new("alpine:3.21")
    .with_cmd(["sleep", "60"])
    .start()
  defer container.cleanup()
  let json = inspect_container(container.id())
  let labels = match json_index(json, 0) {
    Some(container) =>
      match json_field(container, "Config") {
        Some(config) => json_field(config, "Labels")
        None => None
      }
    None => None
  }
  match labels {
    Some(Object(fields)) => assert_true(fields.get(LABEL_SESSION) is Some(_))
    _ => abort("container has no labels")
  }
  // The reaper itself is up and labeled so other sessions can find it.
  assert_true(reaper.val is Some(_))
  assert_true(find_containers("\{LABEL_RYUK}=true", all=false).length() > 0)
}

///|
