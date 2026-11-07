// Reusable containers (experimental).
//
// Mirrors the `withReuse` feature of the official testcontainers libraries:
// the whole container configuration is hashed, the hash is stored as a
// docker label, and `start` re-attaches to an existing container with the
// same hash instead of creating a new one. Because the lookup goes through
// the docker daemon, reuse works across `moon test` processes and across
// separate test runs — which is exactly what is needed, since MoonBit tests
// have no teardown hook and no shared in-process lifecycle.
//
// Reusable containers carry no session label, so the resource reaper
// (reaper.mbt) never deletes them; they survive until `Container::remove`
// (or `docker rm`) is called explicitly.

///|
/// Is container reuse enabled? Like the official implementations this is an
/// opt-in per environment (`TESTCONTAINERS_REUSE_ENABLE`), meant for local
/// development loops — on CI every run starts fresh anyway.
fn reuse_enabled() -> Bool {
  env_truthy("TESTCONTAINERS_REUSE_ENABLE")
}

///|
/// Set once the "reuse disabled" hint has been printed; it is only shown
/// once per test process, like the official implementations.
let reuse_hint_printed : Ref[Bool] = Ref(false)

///|
/// Warn once that `with_reuse` was requested but reuse is not enabled in
/// this environment.
fn warn_reuse_disabled() -> Unit {
  if !reuse_hint_printed.val {
    reuse_hint_printed.val = true
    println(
      "testcontainers: `with_reuse` ignored; set TESTCONTAINERS_REUSE_ENABLE=true to enable reusable containers",
    )
  }
}

///|
/// Is the environment variable `name` set to a truthy value? Accepts `true`
/// (any casing) and `1`.
fn env_truthy(name : String) -> Bool {
  match @env.get_env_var(name) {
    Some(value) => {
      let normalized = ascii_lower(value.trim().to_owned())
      normalized == "true" || normalized == "1"
    }
    None => false
  }
}

///|
/// ASCII-lowercase a string. Docker label values and env vars are ASCII in
/// practice, so no full Unicode case mapping is needed.
fn ascii_lower(text : String) -> String {
  let out : Array[Char] = []
  for c in text.to_array() {
    if c >= 'A' && c <= 'Z' {
      out.push(('a'.to_int() + c.to_int() - 'A'.to_int()).to_char().unwrap())
    } else {
      out.push(c)
    }
  }
  String::from_array(out)
}

///|
/// Start this request in reuse mode: re-attach to an existing container with
/// the same configuration, or create one. The container keeps running after
/// the test; `Container::cleanup` leaves it alone and `Container::remove`
/// deletes it explicitly.
async fn ContainerRequest::start_reusable(self : ContainerRequest) -> Container {
  self.ensure_image()
  let hash = self.reuse_hash()
  for attempt = 0; attempt < 50; attempt = attempt + 1 {
    match find_containers("\{LABEL_REUSE_HASH}=\{hash}", all=true) {
      [id, ..] =>
        match self.adopt(id) {
          Some(container) => return container
          // Not adoptable (vanished or refused to start); `adopt` already
          // removed broken leftovers, so fall through to the create path.
          None => ()
        }
      [] => ()
    }
    match self.create_reusable(hash) {
      Some(container) => return container
      // Lost the name race; the winner's container shows up in the next
      // lookup round.
      None => @async.sleep(100)
    }
  }
  raise UnexpectedOutput(
    "could not start reusable container `\{self.image}`: still racing after 5s",
  )
}

///|
/// Attach to an existing container: (re)start it when needed, resolve its
/// port bindings and apply the request's wait strategy. Returns `None` when
/// the container vanished or cannot be started — broken leftovers are
/// removed so the create path can replace them.
async fn ContainerRequest::adopt(
  self : ContainerRequest,
  id : String,
) -> Container? {
  match container_status(id) {
    None => None
    Some(status) => {
      if status != "running" {
        let output = docker_command(["start", id])
        if output.code != 0 {
          let _ = docker_command(["rm", "--force", "--volumes", id])
          return None
        }
      }
      let container : Container = {
        id,
        request: self,
        ports: [],
        host: docker_host(),
        reusable: true,
      }
      container.resolve_ports()
      if self.wait != WaitStrategy::NoWait {
        container.wait_ready()
      }
      Some(container)
    }
  }
}

///|
/// Create the reusable container. Returns `None` on a name conflict, meaning
/// another test process won the race and its container will appear in the
/// next lookup; real failures raise. The deterministic name (the reuse hash
/// when the request has no explicit name) is what deduplicates concurrent
/// creators.
async fn ContainerRequest::create_reusable(
  self : ContainerRequest,
  hash : String,
) -> Container? {
  let name = match self.name {
    Some(name) => name
    None => "testcontainers-mbt-reuse-\{hash}"
  }
  let labels = self.labels.copy()
  labels.push((LABEL_REUSE_HASH, hash))
  let request : ContainerRequest = { ..self, name: Some(name), labels, }
  let args = request.run_args()
  let output = docker_command(args)
  if output.code != 0 {
    if command_error_text(output).contains("already in use") {
      return None
    }
    raise DockerCommandFailed(
      command=render_command("docker", args),
      code=output.code,
      stderr=command_error_text(output),
    )
  }
  let id = parse_container_id(output.stdout)
  let container : Container = {
    id,
    request,
    ports: [],
    host: docker_host(),
    reusable: true,
  }
  let prepared : Result[Unit, Error] = Ok(
    {
      container.resolve_ports()
      if request.wait != WaitStrategy::NoWait {
        container.wait_ready()
      }
    },
  ) catch {
    e => Err(e)
  }
  match prepared {
    Ok(_) => Some(container)
    Err(e) => {
      // Never leave a failed fresh container behind: it would poison the
      // hash lookup of every future run.
      let _ = docker_command(["rm", "--force", "--volumes", id])
      raise e
    }
  }
}

///|
/// A stable hash of everything that defines the container, used as the
/// `org.testcontainers.mbt.reuse-hash` label value. The rendered
/// `docker run` arguments are hashed rather than struct fields, so every
/// option that changes the container is covered automatically. `reuse` is
/// forced on so the session label — different per test process — is left
/// out of the hash.
fn ContainerRequest::reuse_hash(self : ContainerRequest) -> String {
  fnv1a_hex({ ..self, reuse: true, }.run_args())
}

///|
/// FNV-1a (64-bit) over the UTF-16 code units of the joined arguments,
/// rendered as 16 lowercase hex digits. A self-contained hash is used
/// instead of `Hash` so the value is stable across toolchain versions and
/// processes — it is what lets a later `moon test` run find the container a
/// previous run created.
fn fnv1a_hex(args : Array[String]) -> String {
  let mut hash = 0xcbf29ce484222325UL
  for arg in args {
    for c in arg.to_array() {
      hash = (hash ^ c.to_int().to_uint64()) * 0x100000001b3UL
    }
    hash = (hash ^ 0xffUL) * 0x100000001b3UL
  }
  hex64(hash)
}

///|
/// Render a `UInt64` as exactly 16 lowercase hex digits.
fn hex64(value : UInt64) -> String {
  let digits = "0123456789abcdef".to_array()
  let out : Array[Char] = []
  for i = 15; i >= 0; i = i - 1 {
    let nibble = ((value >> (i * 4)) & 0xfUL).to_int()
    out.push(digits[nibble])
  }
  String::from_array(out)
}

///|
/// Ids of containers carrying `label` (`name=value`). `all` includes stopped
/// containers.
async fn find_containers(label : String, all~ : Bool) -> Array[String] {
  let args : Array[String] = ["ps"]
  args.push(if all { "-aq" } else { "-q" })
  // Full 64-char ids, so an adopted container reports the same id as the
  // one `docker run` originally printed.
  args.push("--no-trunc")
  args.push("--filter")
  args.push("label=\{label}")
  let stdout = docker(args)
  let ids : Array[String] = []
  for line in stdout.split("\n") {
    let id = line.trim().to_owned()
    if id != "" {
      ids.push(id)
    }
  }
  ids
}

///|
/// The docker-reported state of a container (`running`, `exited`, ...), or
/// `None` when it does not exist.
async fn container_status(id : String) -> String? {
  let output = docker_command([
    "inspect", "--type", "container", "--format", "{{.State.Status}}", id,
  ])
  if output.code != 0 {
    None
  } else {
    Some(output.stdout.trim().to_owned())
  }
}

///|
/// Make sure a container is running: start it when it is stopped. Returns
/// `false` when it cannot be started (or no longer exists).
async fn ensure_started(id : String) -> Bool {
  match container_status(id) {
    Some("running") => true
    Some(_) => {
      let output = docker_command(["start", id])
      if output.code != 0 {
        let _ = docker_command(["rm", "--force", "--volumes", id])
        return false
      }
      true
    }
    None => false
  }
}
