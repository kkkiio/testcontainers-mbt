///|
/// Where a mount gets its content from.
#derive(Debug, Eq)
pub(all) enum MountSource {
  /// A path on the host, e.g. `/tmp/fixtures`.
  Bind(String)
  /// A docker named volume, e.g. `testcontainers-data`.
  Volume(String)
  /// An in-memory `tmpfs` mount.
  Tmpfs
}

///|
/// A mount inside the container.
#derive(Debug, Eq)
pub(all) struct Mount {
  /// Source of the data.
  source : MountSource
  /// Absolute path inside the container.
  target : String
  /// Mount read-only.
  read_only : Bool
}

///|
/// Whether the image should be pulled before the container starts.
#derive(Debug, Eq)
pub(all) enum PullPolicy {
  /// Pull only when the image is not present locally (default).
  Missing
  /// Always pull, even when the image is present locally.
  Always
  /// Never pull; fail if the image is missing.
  Never
}

///|
/// A condition that must hold before a started container is considered ready.
///
/// Every strategy except `NoWait` and `Seconds` is polled until it holds or the
/// request's `wait_timeout_ms` (default: 60 seconds) expires.
#derive(Debug, Eq)
pub(all) enum WaitStrategy {
  /// Do not wait: the container is considered ready as soon as docker started
  /// it. This is the default, matching testcontainers-go.
  NoWait
  /// Wait unconditionally. Useful as a quick and dirty fallback; prefer a real
  /// readiness signal.
  Seconds(Int32)
  /// Wait until the port is LISTENing inside the container, checked via
  /// `/proc/net/tcp`. Probing inside the container avoids the docker-proxy
  /// false positive, where the proxy accepts connections on a published port
  /// even though nothing inside listens yet. For images without procfs (or
  /// `cat`) it falls back to a TCP connection to the host-mapped port.
  TcpPort(Int32)
  /// Wait until `GET http://<host>:<mapped port><path>` returns `status`.
  ///
  /// The first argument is the *container* port.
  HttpGet(Int32, String, Int32)
  /// Wait until the container logs contain `message` (plain substring match).
  LogMessage(String)
  /// Wait until running `cmd` inside the container exits with status 0, e.g.
  /// `Exec(["pg_isready", "-h", "127.0.0.1"])`.
  Exec(Array[String])
  /// Wait until the image's `HEALTHCHECK` reports `healthy`. Requires a
  /// health check in the image.
  Healthy
  /// Wait until the container exits with the given status code.
  Exit(Int32)
  /// Wait until every strategy is satisfied, in order.
  All(Array[WaitStrategy])
  /// Wait until at least one strategy is satisfied.
  Any(Array[WaitStrategy])
}

///|
/// Promote trait methods to inherent methods (the compiler warns about implicit
/// promotion otherwise).
pub extend MountSource with Eq::{equal, not_equal}

///|
pub extend MountSource with Debug::{to_repr}

///|
pub extend Mount with Eq::{equal, not_equal}

///|
pub extend Mount with Debug::{to_repr}

///|
pub extend PullPolicy with Eq::{equal, not_equal}

///|
pub extend PullPolicy with Debug::{to_repr}

///|
/// Human readable description, used in timeout messages.
pub fn WaitStrategy::describe(self : WaitStrategy) -> String {
  match self {
    NoWait => "no wait"
    Seconds(seconds) => "sleep \{seconds}s"
    TcpPort(port) => "TCP port \{port}"
    HttpGet(port, path, status) =>
      "HTTP GET on port \{port} \{path} returning \{status}"
    LogMessage(message) => "log message `\{message}`"
    Exec(cmd) => "exec `\{cmd.join(" ")}`"
    Healthy => "docker health check"
    Exit(code) => "container exit code \{code}"
    All(strategies) => "all of [" + describe_all(strategies) + "]"
    Any(strategies) => "any of [" + describe_all(strategies) + "]"
  }
}

///|
fn describe_all(strategies : ArrayView[WaitStrategy]) -> String {
  let parts : Array[String] = []
  for strategy in strategies {
    parts.push(strategy.describe())
  }
  parts.join(", ")
}

///|
/// Everything needed to start one container.
///
/// Build it with `ContainerRequest::new` and the `with_*` methods:
///
/// ```mbt nocheck
/// let request = @testcontainers.ContainerRequest::new("postgres:16-alpine")
///   .with_port(5432)
///   .with_env("POSTGRES_PASSWORD", "secret")
///   .with_wait_for(@testcontainers.WaitStrategy::TcpPort(5432))
/// ```
#derive(Debug, Eq)
pub(all) struct ContainerRequest {
  /// Full image reference, e.g. `postgres:16-alpine`.
  image : String
  /// Container ports to publish on a random host port.
  ports : Array[Int32]
  /// Environment variables, in insertion order.
  env : Array[(String, String)]
  /// Command (arguments after the image). Overrides the image's `CMD`.
  cmd : Array[String]
  /// Entrypoint override. The first element becomes `--entrypoint`, the rest
  /// are prepended to the command, like docker itself does.
  entrypoint : Array[String]
  /// Bind mounts, named volumes and tmpfs mounts.
  mounts : Array[Mount]
  /// Container labels.
  labels : Array[(String, String)]
  /// Readiness condition.
  wait : WaitStrategy
  /// Readiness timeout in milliseconds. Defaults to 60_000.
  wait_timeout_ms : Int32
  /// Ask docker to remove the container when it exits. Off by default so logs
  /// stay available; `cleanup()` removes it explicitly.
  auto_remove : Bool
  /// Explicit container name. Docker generates one when omitted.
  name : String?
  /// User to run the container as, e.g. `1000:1000`.
  user : String?
  /// Attach the container to this docker network.
  network : String?
  /// Container hostname.
  hostname : String?
  /// Image pull behaviour. Defaults to `Missing`.
  pull : PullPolicy
  /// Keep the container alive after the test and re-attach to it on the next
  /// run (experimental). Only honored when `TESTCONTAINERS_REUSE_ENABLE` is
  /// set in the environment; see `with_reuse`.
  reuse : Bool
}

///|
/// A new request for `image`.
///
/// `image` is a normal docker reference: `nginx`, `postgres:16-alpine`,
/// `ghcr.io/org/app:1.2`. A missing tag means `latest`.
pub fn ContainerRequest::new(image : String) -> ContainerRequest {
  {
    image,
    ports: [],
    env: [],
    cmd: [],
    entrypoint: [],
    mounts: [],
    labels: [],
    wait: WaitStrategy::NoWait,
    wait_timeout_ms: 60_000,
    auto_remove: false,
    name: None,
    user: None,
    network: None,
    hostname: None,
    pull: PullPolicy::Missing,
    reuse: false,
  }
}

///|
/// Replace the image reference.
pub fn ContainerRequest::with_image(
  self : ContainerRequest,
  image : String,
) -> ContainerRequest {
  { ..self, image, }
}

///|
/// Publish `port` on a random host port. Call it once per port.
pub fn ContainerRequest::with_port(
  self : ContainerRequest,
  port : Int32,
) -> ContainerRequest {
  let ports = self.ports.copy()
  if !ports.contains(port) {
    ports.push(port)
  }
  { ..self, ports, }
}

///|
/// Publish several ports on random host ports.
pub fn ContainerRequest::with_ports(
  self : ContainerRequest,
  ports : ArrayView[Int32],
) -> ContainerRequest {
  let mut request = self
  for port in ports {
    request = request.with_port(port)
  }
  request
}

///|
/// Add one environment variable.
pub fn ContainerRequest::with_env(
  self : ContainerRequest,
  key : String,
  value : String,
) -> ContainerRequest {
  let env = self.env.copy()
  env.push((key, value))
  { ..self, env, }
}

///|
/// Add several environment variables.
pub fn ContainerRequest::with_envs(
  self : ContainerRequest,
  env : ArrayView[(String, String)],
) -> ContainerRequest {
  let merged = self.env.copy()
  for pair in env {
    merged.push(pair)
  }
  { ..self, env: merged, }
}

///|
/// Set the command arguments passed after the image.
pub fn ContainerRequest::with_cmd(
  self : ContainerRequest,
  cmd : ArrayView[String],
) -> ContainerRequest {
  { ..self, cmd: cmd.to_owned(), }
}

///|
/// Set the entrypoint. The first element is passed to `--entrypoint`, the
/// remaining elements are prepended to the command.
pub fn ContainerRequest::with_entrypoint(
  self : ContainerRequest,
  entrypoint : ArrayView[String],
) -> ContainerRequest {
  { ..self, entrypoint: entrypoint.to_owned(), }
}

///|
/// Bind-mount a host path into the container. `host_path` must be absolute.
pub fn ContainerRequest::with_bind(
  self : ContainerRequest,
  host_path : String,
  container_path : String,
) -> ContainerRequest {
  self.with_mount({
    source: MountSource::Bind(host_path),
    target: container_path,
    read_only: false,
  })
}

///|
/// Like `with_bind`, but mounted read-only.
pub fn ContainerRequest::with_bind_read_only(
  self : ContainerRequest,
  host_path : String,
  container_path : String,
) -> ContainerRequest {
  self.with_mount({
    source: MountSource::Bind(host_path),
    target: container_path,
    read_only: true,
  })
}

///|
/// Mount a docker named volume into the container.
pub fn ContainerRequest::with_volume(
  self : ContainerRequest,
  volume_name : String,
  container_path : String,
) -> ContainerRequest {
  self.with_mount({
    source: MountSource::Volume(volume_name),
    target: container_path,
    read_only: false,
  })
}

///|
/// Mount an in-memory `tmpfs` at `container_path`.
pub fn ContainerRequest::with_tmpfs(
  self : ContainerRequest,
  container_path : String,
) -> ContainerRequest {
  self.with_mount({
    source: MountSource::Tmpfs,
    target: container_path,
    read_only: false,
  })
}

///|
/// Add an arbitrary mount.
pub fn ContainerRequest::with_mount(
  self : ContainerRequest,
  mount : Mount,
) -> ContainerRequest {
  let mounts = self.mounts.copy()
  mounts.push(mount)
  { ..self, mounts, }
}

///|
/// Add a container label.
pub fn ContainerRequest::with_label(
  self : ContainerRequest,
  key : String,
  value : String,
) -> ContainerRequest {
  let labels = self.labels.copy()
  labels.push((key, value))
  { ..self, labels, }
}

///|
/// Set the readiness condition.
pub fn ContainerRequest::with_wait_for(
  self : ContainerRequest,
  wait : WaitStrategy,
) -> ContainerRequest {
  { ..self, wait, }
}

///|
/// Set the readiness timeout in milliseconds.
pub fn ContainerRequest::with_wait_timeout_ms(
  self : ContainerRequest,
  timeout_ms : Int32,
) -> ContainerRequest {
  { ..self, wait_timeout_ms: timeout_ms, }
}

///|
/// Set the readiness timeout in seconds.
pub fn ContainerRequest::with_wait_timeout(
  self : ContainerRequest,
  timeout_seconds : Int32,
) -> ContainerRequest {
  { ..self, wait_timeout_ms: timeout_seconds * 1000, }
}

///|
/// Ask docker to remove the container automatically when it exits.
pub fn ContainerRequest::with_auto_remove(
  self : ContainerRequest,
  auto_remove : Bool,
) -> ContainerRequest {
  { ..self, auto_remove, }
}

///|
/// Set an explicit container name.
pub fn ContainerRequest::with_name(
  self : ContainerRequest,
  name : String,
) -> ContainerRequest {
  { ..self, name: Some(name), }
}

///|
/// Set the user the container runs as.
pub fn ContainerRequest::with_user(
  self : ContainerRequest,
  user : String,
) -> ContainerRequest {
  { ..self, user: Some(user), }
}

///|
/// Attach the container to a docker network.
pub fn ContainerRequest::with_network(
  self : ContainerRequest,
  network : String,
) -> ContainerRequest {
  { ..self, network: Some(network), }
}

///|
/// Set the container hostname.
pub fn ContainerRequest::with_hostname(
  self : ContainerRequest,
  hostname : String,
) -> ContainerRequest {
  { ..self, hostname: Some(hostname), }
}

///|
/// Mark the container as reusable (experimental).
///
/// A reusable container is looked up by a hash of its configuration before it
/// is created: when a container with the same configuration already exists —
/// running or stopped — it is re-attached instead of starting a new one. The
/// container is **not** removed by `cleanup()` or when the test process exits;
/// call `Container::remove` explicitly to delete it.
///
/// Reuse only takes effect when `TESTCONTAINERS_REUSE_ENABLE=true` is set in
/// the environment. Without it the flag is ignored, matching the other
/// testcontainers implementations that treat reuse as a local-development
/// opt-in which must not leak into CI.
///
/// Caveat: a reused container keeps all of its state (rows, topics, keys).
/// Tests that depend on a clean service must reset that state themselves.
pub fn ContainerRequest::with_reuse(
  self : ContainerRequest,
  reuse~ : Bool = true,
) -> ContainerRequest {
  { ..self, reuse, }
}

///|
/// Choose when the image is pulled.
pub fn ContainerRequest::with_pull_policy(
  self : ContainerRequest,
  pull : PullPolicy,
) -> ContainerRequest {
  { ..self, pull, }
}

///|
/// Repository part of the image reference (`nginx` for `nginx:1.27`).
pub fn ContainerRequest::image_name(self : ContainerRequest) -> String {
  split_image_ref(self.image).0
}

///|
/// Tag part of the image reference (`1.27` for `nginx:1.27`). Empty for digest
/// references.
pub fn ContainerRequest::image_tag(self : ContainerRequest) -> String {
  split_image_ref(self.image).1
}

///|
/// Split a docker image reference into `(repository, tag)`.
///
/// Tag detection must only consider colons after the last slash, otherwise a
/// registry with a port (`localhost:5000/app`) would be parsed as tag `5000/app`.
/// Digest references (`repo@sha256:...`) keep the whole reference as repository
/// and report an empty tag.
pub fn split_image_ref(image : String) -> (String, String) {
  if image.contains("@") {
    return (image, "")
  }
  let chars = image.to_array()
  let mut last_slash = -1
  let mut last_colon = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' {
      last_slash = i
    } else if chars[i] == ':' {
      last_colon = i
    }
  }
  if last_colon > last_slash && last_colon < chars.length() - 1 {
    let name = image[:last_colon].to_owned()
    let tag = image[last_colon + 1:].to_owned()
    (name, tag)
  } else {
    (image, "latest")
  }
}

///|
/// Is `path` an absolute path on a platform docker accepts for bind mounts?
/// Accepts POSIX paths and Windows drive paths.
fn is_absolute_path(path : String) -> Bool {
  if path.has_prefix("/") {
    return true
  }
  let chars = path.to_array()
  chars.length() >= 3 &&
  chars[1] == ':' &&
  (chars[2] == '/' || chars[2] == '\\')
}

///|
/// Reject requests that docker would fail on with a cryptic message.
fn validate_request(request : ContainerRequest) -> Unit raise {
  if request.image.trim().to_owned() == "" {
    raise InvalidRequest("image must not be empty")
  }
  if request.wait_timeout_ms <= 0 {
    raise InvalidRequest(
      "wait_timeout_ms must be positive, got \{request.wait_timeout_ms}",
    )
  }
  if request.auto_remove && wait_needs_container_after_exit(request.wait) {
    raise InvalidRequest(
      "auto_remove cannot be combined with a wait strategy that inspects the " +
      "container after it exits (Exit); docker deletes the container on exit",
    )
  }
  if request.reuse && request.auto_remove {
    raise InvalidRequest(
      "reuse cannot be combined with auto_remove; docker deletes the " +
      "container on exit so there would be nothing to reuse",
    )
  }
  for port in request.ports {
    if port <= 0 || port > 65535 {
      raise InvalidRequest("port \{port} is not in 1..65535")
    }
  }
  for mount in request.mounts {
    if !mount.target.has_prefix("/") {
      raise InvalidRequest(
        "mount target `\{mount.target}` must be an absolute container path",
      )
    }
    match mount.source {
      Bind(host_path) =>
        if !is_absolute_path(host_path) {
          raise InvalidRequest(
            "bind mount source `\{host_path}` must be an absolute host path; " +
            "use `with_volume` for a docker named volume",
          )
        }
      Volume(name) =>
        if name == "" {
          raise InvalidRequest("named volume must not be empty")
        }
      Tmpfs => ()
    }
  }
  match request.entrypoint {
    [] => ()
    _ =>
      if request.entrypoint[0] == "" {
        raise InvalidRequest("entrypoint must not contain an empty program")
      }
  }
}

///|
pub extend WaitStrategy with Eq::{equal, not_equal}

///|
pub extend WaitStrategy with Debug::{to_repr}

///|
pub extend ContainerRequest with Eq::{equal, not_equal}

///|
pub extend ContainerRequest with Debug::{to_repr}

///|
/// Would this strategy need to inspect the container after it exited? With
/// `--rm` docker deletes it at that point, so the wait could never succeed.
fn wait_needs_container_after_exit(strategy : WaitStrategy) -> Bool {
  match strategy {
    Exit(_) => true
    All(strategies) => strategies.any(s => wait_needs_container_after_exit(s))
    Any(strategies) => strategies.all(s => wait_needs_container_after_exit(s))
    _ => false
  }
}
