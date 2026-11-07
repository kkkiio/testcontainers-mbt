// Resource reaping via Ryuk, mirroring the official testcontainers
// implementations.
//
// `moon test` has no teardown hook and test processes can be killed
// outright, so explicit `cleanup()` calls cannot guarantee that every
// container is removed. All official libraries solve this with a
// `testcontainers/ryuk` sidecar container that owns a TCP server: every test
// process keeps one connection open and registers a
// `label=org.testcontainers.mbt.sessionId=<id>` filter. When the last
// connection drops, ryuk deletes every resource matching the registered
// filters — including itself, since it carries the session label of the
// process that created it.
//
// Reusable containers deliberately carry no session label, so ryuk never
// touches them.

///|
/// Label applied to every container started by this package, so leaked
/// containers can be found and removed manually:
/// `docker ps -aq --filter label=org.testcontainers.mbt=true`
const LABEL_MANAGED = "org.testcontainers.mbt"

///|
/// Label marking the ryuk container itself, used to find-or-attach it.
const LABEL_RYUK = "org.testcontainers.mbt.ryuk"

///|
/// Per-test-process label ryuk uses to decide what to delete.
const LABEL_SESSION = "org.testcontainers.mbt.sessionId"

///|
/// Label identifying a reusable container; its value is the configuration
/// hash computed by `ContainerRequest::reuse_hash`.
const LABEL_REUSE_HASH = "org.testcontainers.mbt.reuse-hash"

///|
/// Fixed name for the ryuk container so concurrent test processes cannot
/// spawn duplicates: the loser of a `docker run` race gets a name conflict
/// and attaches to the winner's container.
const REAPER_NAME = "testcontainers-mbt-ryuk"

///|
/// Default ryuk image; override with the `RYUK_CONTAINER_IMAGE` environment
/// variable, like the official implementations.
const REAPER_IMAGE = "testcontainers/ryuk:0.14.0"

///|
/// The reaper connection and container id, once established. Kept in a `Ref`
/// so the socket is never garbage-collected before the process exits — the
/// connection staying open is what tells ryuk this test session is alive.
let reaper : Ref[(@socket.Tcp, String)?] = Ref(None)

///|
/// This process's session id, generated lazily by `ensure_reaper`. Every
/// non-reusable container gets it as the `LABEL_SESSION` docker label.
let session : Ref[String?] = Ref(None)

///|
/// Make sure a ryuk container is running and this process has registered its
/// session filter with it. No-op when `TESTCONTAINERS_RYUK_DISABLED` is set.
async fn ensure_reaper() -> Unit {
  if reaper_disabled() || reaper.val is Some(_) {
    return
  }
  let session_id = match session.val {
    Some(id) => id
    None => {
      let id = new_session_id()
      session.val = Some(id)
      id
    }
  }
  let id = reaper_container(session_id)
  let port = published_port(id, 8080)
  let host = docker_host()
  // Desktop docker runtimes (Docker Desktop, OrbStack) plumb the published
  // port asynchronously: a connection made right after `docker run` can be
  // accepted and then dropped without ever reaching ryuk. Verify each
  // attempt by reading ryuk's ACK reply and retry until one sticks.
  let mut failure : Error? = None
  for attempt = 0; attempt < 25; attempt = attempt + 1 {
    let attempt_result : Result[@socket.Tcp, Error] = Ok(
      register_reaper_filters(host, port, session_id),
    ) catch {
      e => Err(e)
    }
    match attempt_result {
      Ok(tcp) => {
        reaper.val = Some((tcp, id))
        return
      }
      Err(e) => {
        failure = Some(e)
        @async.sleep(200)
      }
    }
  }
  match failure {
    Some(e) => raise e
    None =>
      raise UnexpectedOutput(
        "cannot register session filter with ryuk at \{join_host_port(host, port)}",
      )
  }
}

///|
/// Connect to ryuk, send the label filters and verify the registration by
/// reading the `ACK` reply ryuk sends per filter. Two filters: the session
/// label covers this process's containers, and the ryuk label lets ryuk
/// delete itself at the end even when it was created by a previous session
/// and therefore carries a foreign session id.
///
/// The returned socket must be kept open for the rest of the process's
/// lifetime — the open connection is what tells ryuk this test session is
/// still alive.
async fn register_reaper_filters(
  host : String,
  port : Int32,
  session_id : String,
) -> @socket.Tcp {
  let endpoint = join_host_port(host, port)
  let tcp = @async.with_timeout_opt(5_000, () => {
    @socket.Tcp::connect_to_host(host, port~)
  }) catch {
    e =>
      raise UnexpectedOutput(
        "cannot connect to ryuk at \{endpoint}: \{e.to_string()}",
      )
  }
  guard tcp is Some(tcp) else {
    raise UnexpectedOutput("timed out connecting to ryuk at \{endpoint}")
  }
  errdefer tcp.close()
  tcp.write("label=\{LABEL_SESSION}=\{session_id}\nlabel=\{LABEL_RYUK}=true\n") catch {
    e =>
      raise UnexpectedOutput(
        "cannot send session filter to ryuk at \{endpoint}: \{e.to_string()}",
      )
  }
  let ack = @async.with_timeout_opt(5_000, () => tcp.read_until("\n")) catch {
    e =>
      raise UnexpectedOutput(
        "ryuk connection at \{endpoint} dropped before ACK: \{e.to_string()}",
      )
  }
  guard ack is Some(Some(line)) && line.contains("ACK") else {
    let got = match ack {
      Some(Some(line)) => line.trim().to_owned()
      _ => "<eof>"
    }
    raise UnexpectedOutput(
      "expected an ACK from ryuk at \{endpoint}, got: \{got}",
    )
  }
  tcp
}

///|
/// The session id to stamp on new containers, or `None` when the reaper is
/// disabled or not yet initialized. Called from `run_args`, so it must stay
/// synchronous.
fn current_session_id() -> String? {
  session.val
}

///|
/// Is the resource reaper turned off? Honors `TESTCONTAINERS_RYUK_DISABLED`,
/// the same variable the official implementations use.
fn reaper_disabled() -> Bool {
  env_truthy("TESTCONTAINERS_RYUK_DISABLED")
}

///|
/// Find the running ryuk container, or start one. Concurrent test processes
/// are deduplicated by the fixed `REAPER_NAME`: a `docker run` that loses the
/// name race loops back and attaches to the winner.
async fn reaper_container(session_id : String) -> String {
  for attempt = 0; attempt < 50; attempt = attempt + 1 {
    match find_containers("\{LABEL_RYUK}=true", all=true) {
      [id, ..] => if ensure_started(id) { return id }
      [] => ()
    }
    let args = reaper_run_args(session_id)
    let output = docker_command(args)
    if output.code == 0 {
      return parse_container_id(output.stdout)
    }
    // A name conflict means another process won the create race; loop and
    // adopt its container. Anything else (pull failure, socket mount
    // denied, ...) is a real error.
    if !command_error_text(output).contains("already in use") {
      raise DockerCommandFailed(
        command=render_command("docker", args),
        code=output.code,
        stderr=command_error_text(output),
      )
    }
    @async.sleep(100)
  }
  raise UnexpectedOutput("timed out waiting for the ryuk container")
}

///|
/// `docker run` arguments for the ryuk container. The docker socket is bind
/// mounted so ryuk can list and delete resources; the session label lets it
/// delete itself once no clients are left.
fn reaper_run_args(session_id : String) -> Array[String] {
  let image = match @env.get_env_var("RYUK_CONTAINER_IMAGE") {
    Some(custom) if custom != "" => custom
    _ => REAPER_IMAGE
  }
  // `--rm` matters: ryuk removes the resources matching its filters and then
  // exits, but it cannot delete the container it is itself running in. With
  // auto-remove, docker deletes the ryuk container as soon as it stops.
  let args : Array[String] = [
    "run",
    "--detach",
    "--rm",
    "--name",
    REAPER_NAME,
    "--publish",
    "8080",
    "--label",
    "\{LABEL_MANAGED}=true",
    "--label",
    "\{LABEL_RYUK}=true",
    "--label",
    "\{LABEL_SESSION}=\{session_id}",
    "--volume",
    "\{docker_socket_path()}:/var/run/docker.sock",
  ]
  if env_truthy("TESTCONTAINERS_RYUK_PRIVILEGED") {
    args.push("--privileged")
  }
  match @env.get_env_var("RYUK_RECONNECTION_TIMEOUT") {
    Some(timeout) if timeout != "" => {
      args.push("--env")
      args.push("RYUK_RECONNECTION_TIMEOUT=\{timeout}")
    }
    _ => ()
  }
  args.push(image)
  args
}

///|
/// The host path of the docker socket that gets bind-mounted into ryuk:
/// `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` wins, then a `unix://`
/// `DOCKER_HOST`, then the default location.
fn docker_socket_path() -> String {
  match @env.get_env_var("TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE") {
    Some(socket) if socket != "" => return socket
    _ => ()
  }
  match @env.get_env_var("DOCKER_HOST") {
    Some(host) => if host.has_prefix("unix://") { return host[7:].to_owned() }
    None => ()
  }
  "/var/run/docker.sock"
}

///|
/// The host port a container publishes `container_port` on, with a short
/// retry because docker fills in the binding asynchronously.
async fn published_port(id : String, container_port : Int32) -> Int32 {
  for attempt = 0; attempt < 50; attempt = attempt + 1 {
    let json = inspect_container(id)
    let bindings = match json_index(json, 0) {
      Some(container) =>
        match json_field(container, "NetworkSettings") {
          Some(settings) => json_field(settings, "Ports")
          None => None
        }
      None => None
    }
    match bindings {
      Some(b) =>
        match host_port_from_bindings(b, container_port) {
          Some(port) => return port
          None => ()
        }
      None => ()
    }
    @async.sleep(100)
  }
  raise PortNotMapped(container_port~, container_id=id)
}

///|
/// A random session id for this test process: 128 bits of hex, the same role
/// as the UUIDs the official implementations generate.
fn new_session_id() -> String {
  let rand = @random.Rand()
  hex64(rand.uint64()) + hex64(rand.uint64())
}
