///|
/// A running container.
///
/// Containers are started by `ContainerRequest::start` (or `run`) and removed
/// again by `cleanup`. Because MoonBit tests have no automatic teardown hook,
/// prefer the scoped helper:
///
/// ```mbt nocheck
/// async test "nginx" {
///   @testcontainers.with_container(request, container => {
///   // ... use container ...
///   })
/// }
/// ```
pub struct Container {
  id : String
  request : ContainerRequest
  ports : Array[(Int32, Int32)]
  host : String
}

///|
/// Result of `docker exec`.
pub(all) struct ExecOutput {
  /// Exit status of the command inside the container.
  code : Int32
  stdout : String
  stderr : String
} derive(Debug, Eq)

///|
pub extend ExecOutput with Eq::{equal, not_equal}

///|
pub extend ExecOutput with Debug::{to_repr}

///|
/// Start a container for `request` and wait until it is ready.
pub async fn run(
  request : ContainerRequest,
) -> Container raise TestContainerError {
  request.start()
}

///|
/// Start a container for this request and wait until it is ready.
///
/// The caller owns the container and must call `cleanup()` eventually; use
/// `with_container` to have that happen automatically.
pub async fn ContainerRequest::start(
  self : ContainerRequest,
) -> Container raise TestContainerError {
  validate_request(self)
  self.ensure_image()
  let args = self.run_args()
  let output = docker_command(args)
  if output.code != 0 {
    raise DockerCommandFailed(
      command=render_command("docker", args),
      code=output.code,
      stderr=command_error_text(output),
    )
  }
  let id = parse_container_id(output.stdout)
  let container : Container = {
    id,
    request: self,
    ports: [],
    host: docker_host(),
  }
  // From here on the container exists. Clean it up if port resolution or the
  // wait strategy fails, or if the surrounding test is cancelled. `cleanup`
  // never raises, so it cannot mask the real error.
  errdefer container.cleanup()
  container.resolve_ports()
  if self.wait != WaitStrategy::NoWait {
    container.wait_ready()
  }
  container
}

///|
/// Run `f` with a freshly started container and clean the container up
/// afterwards, whether `f` succeeds, fails or is cancelled.
pub async fn[T] with_container(
  request : ContainerRequest,
  f : async (Container) -> T,
) -> T {
  let container = request.start()
  defer container.cleanup()
  f(container)
}

///|
/// The container id, as printed by `docker run -d` (64 hex characters).
pub fn Container::id(self : Container) -> String {
  self.id
}

///|
/// The request this container was started from.
pub fn Container::request(self : Container) -> ContainerRequest {
  self.request
}

///|
/// Host name or IP that reaches the container's published ports.
///
/// Normally `localhost`; override with the `TESTCONTAINERS_HOST_OVERRIDE`
/// environment variable when Docker runs on another machine.
pub fn Container::host(self : Container) -> String {
  self.host
}

///|
/// Host port mapped to `container_port`, or `None` when the port was not
/// published.
pub fn Container::host_port_opt(
  self : Container,
  container_port : Int32,
) -> Int32? {
  for binding in self.ports {
    let (container, host) = binding
    if container == container_port {
      return Some(host)
    }
  }
  None
}

///|
/// Host port mapped to `container_port`.
pub fn Container::host_port(
  self : Container,
  container_port : Int32,
) -> Int32 raise TestContainerError {
  match self.host_port_opt(container_port) {
    Some(port) => port
    None => raise PortNotMapped(container_port~, container_id=self.id)
  }
}

///|
/// `host:port` for a published container port, ready to be used in a
/// connection string. IPv6 hosts are bracketed.
pub fn Container::endpoint(
  self : Container,
  container_port : Int32,
) -> String raise TestContainerError {
  join_host_port(self.host, self.host_port(container_port))
}

///|
/// Join a host and a port, bracketing IPv6 addresses.
pub fn join_host_port(host : String, port : Int32) -> String {
  if host.contains(":") && !host.has_prefix("[") {
    "[\{host}]:\{port}"
  } else {
    "\{host}:\{port}"
  }
}

///|
/// Ask docker to stop the container. Waits up to `timeout_seconds` for a clean
/// shutdown.
pub async fn Container::stop(
  self : Container,
  timeout_seconds~ : Int32 = 10,
) -> Unit raise TestContainerError {
  let _ = docker(["stop", "--time", timeout_seconds.to_string(), self.id])
}

///|
/// Force-remove the container and its anonymous volumes.
pub async fn Container::remove(
  self : Container,
) -> Unit raise TestContainerError {
  let output = docker_command(["rm", "--force", "--volumes", self.id])
  if output.code != 0 && !is_missing_container_error(command_error_text(output)) {
    raise DockerCommandFailed(
      command=render_command("docker", ["rm", "--force", self.id]),
      code=output.code,
      stderr=command_error_text(output),
    )
  }
}

///|
/// Best-effort cleanup: force-remove the container, ignoring errors.
///
/// This is what `with_container` uses and what you should put in a `defer`
/// block. Failure to clean up must not turn a passing test into a failing one,
/// so problems are reported on stdout as a warning instead of being raised.
pub async fn Container::cleanup(self : Container) -> Unit noraise {
  let result : Result[Unit, TestContainerError] = Ok(self.remove()) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => ()
    Err(e) =>
      println("testcontainers: warning: cleanup failed: \{e.to_string()}")
  }
}

///|
/// Is the container still running?
pub async fn Container::is_running(
  self : Container,
) -> Bool raise TestContainerError {
  self.status() == "running"
}

///|
/// Does the container still exist (running or stopped)? Never raises, so it is
/// safe to use in assertions after `cleanup`.
pub async fn Container::exists(self : Container) -> Bool noraise {
  let result : Result[Json, TestContainerError] = Ok(inspect_container(self.id)) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// Container state as reported by docker (`running`, `exited`, ...).
pub async fn Container::status(
  self : Container,
) -> String raise TestContainerError {
  let json = inspect_container(self.id)
  match json_index(json, 0) {
    Some(container) =>
      match json_field(container, "State") {
        Some(state) =>
          match json_field(state, "Status") {
            Some(status) => json_as_string(status) |> unwrap_or("unknown")
            None => "unknown"
          }
        None => "unknown"
      }
    None => "unknown"
  }
}

///|
/// Run a command inside the container.
///
/// A non-zero exit status is returned in `ExecOutput::code` rather than raised,
/// so this is safe to use for probing.
pub async fn Container::exec(
  self : Container,
  cmd : ArrayView[String],
) -> ExecOutput raise TestContainerError {
  let args : Array[String] = ["exec", self.id]
  for arg in cmd {
    args.push(arg)
  }
  let output = docker_command(args)
  output |> to_exec_output
}

///|
/// Run a command inside the container and fail unless it exits with status 0.
/// Returns stdout.
pub async fn Container::exec_checked(
  self : Container,
  cmd : ArrayView[String],
) -> String raise TestContainerError {
  let result = self.exec(cmd)
  if result.code != 0 {
    raise DockerCommandFailed(
      command=render_command("docker exec", cmd),
      code=result.code,
      stderr=result.stderr,
    )
  }
  result.stdout
}

///|
/// Copy a file or directory from the host into the container
/// (`docker cp`). Useful to load fixtures or SQL dumps before running a test.
pub async fn Container::copy_to(
  self : Container,
  host_path : String,
  container_path : String,
) -> Unit raise TestContainerError {
  let _ = docker(["cp", host_path, "\{self.id}:\{container_path}"])
}

///|
/// Copy a file or directory out of the container (`docker cp`), e.g. a log or
/// a database dump produced during the test.
pub async fn Container::copy_from(
  self : Container,
  container_path : String,
  host_path : String,
) -> Unit raise TestContainerError {
  let _ = docker(["cp", "\{self.id}:\{container_path}", host_path])
}

///|
fn to_exec_output(output : CommandOutput) -> ExecOutput {
  { code: output.code, stdout: output.stdout, stderr: output.stderr, }
}

///|
fn[T] unwrap_or(value : T?, fallback : T) -> T {
  match value {
    Some(value) => value
    None => fallback
  }
}

///|
fn json_field(json : Json, key : String) -> Json? {
  guard json is Object(fields) else { return None }
  fields.get(key)
}

///|
fn json_index(json : Json, index : Int32) -> Json? {
  guard json is Array(items) else { return None }
  if index < 0 || index >= items.length() {
    return None
  }
  Some(items[index])
}

///|
fn json_as_string(json : Json) -> String? {
  guard json is String(value) else { return None }
  Some(value)
}

///|
fn json_as_int(json : Json) -> Int32? {
  guard json is Number(value, ..) else { return None }
  Some(value.to_int())
}

///|
/// Start pulling the image if the request asks for it (or needs it).
async fn ContainerRequest::ensure_image(
  self : ContainerRequest,
) -> Unit raise TestContainerError {
  match self.pull {
    Always => pull_image(self.image)
    Never => ()
    Missing => if !image_exists(self.image) { pull_image(self.image) }
  }
}

///|
/// Translate a request into `docker run` arguments.
fn ContainerRequest::run_args(self : ContainerRequest) -> Array[String] {
  let args : Array[String] = ["run", "--detach"]
  match self.name {
    Some(name) => {
      args.push("--name")
      args.push(name)
    }
    None => ()
  }
  match self.hostname {
    Some(hostname) => {
      args.push("--hostname")
      args.push(hostname)
    }
    None => ()
  }
  match self.user {
    Some(user) => {
      args.push("--user")
      args.push(user)
    }
    None => ()
  }
  match self.network {
    Some(network) => {
      args.push("--network")
      args.push(network)
    }
    None => ()
  }
  if self.auto_remove {
    args.push("--rm")
  }
  // `Missing` is docker's default and `Always` is handled by an explicit
  // pull in `ensure_image` (which reports `ImagePullFailed`). `Never` is the
  // one policy the daemon has to enforce, otherwise `docker run` would
  // happily pull a missing image.
  if self.pull is Never {
    args.push("--pull")
    args.push("never")
  }
  for pair in self.env {
    let (key, value) = pair
    args.push("--env")
    args.push("\{key}=\{value}")
  }
  // Label every container so leaked ones from a killed test process can be
  // found: docker ps -aq --filter label=org.testcontainers.mbt=true
  args.push("--label")
  args.push("org.testcontainers.mbt=true")
  for pair in self.labels {
    let (key, value) = pair
    args.push("--label")
    args.push("\{key}=\{value}")
  }
  for port in self.ports {
    // `--publish 5432` asks docker for a random host port on every interface.
    // Unlike `--publish-all` this works even when the image does not declare
    // `EXPOSE 5432`.
    args.push("--publish")
    args.push(port.to_string())
  }
  for mount in self.mounts {
    match mount.source {
      Bind(host_path) => {
        args.push("--volume")
        args.push(mount_spec(host_path, mount.target, mount.read_only))
      }
      Volume(volume_name) => {
        args.push("--volume")
        args.push(mount_spec(volume_name, mount.target, mount.read_only))
      }
      Tmpfs => {
        args.push("--tmpfs")
        args.push(
          if mount.read_only {
            "\{mount.target}:ro"
          } else {
            mount.target
          },
        )
      }
    }
  }
  let has_entrypoint = self.entrypoint.length() > 0
  if has_entrypoint {
    args.push("--entrypoint")
    args.push(self.entrypoint[0])
  }
  args.push(self.image)
  if has_entrypoint {
    for i = 1; i < self.entrypoint.length(); i = i + 1 {
      args.push(self.entrypoint[i])
    }
  }
  for arg in self.cmd {
    args.push(arg)
  }
  args
}

///|
fn mount_spec(source : String, target : String, read_only : Bool) -> String {
  if read_only {
    "\{source}:\{target}:ro"
  } else {
    "\{source}:\{target}"
  }
}

///|
/// Extract and validate the container id from `docker run -d` stdout.
///
/// Pull progress never ends up here because stdout and stderr are captured
/// separately, but we still skip empty lines defensively.
fn parse_container_id(stdout : String) -> String raise TestContainerError {
  for line in stdout.split("\n") {
    let candidate = line.trim().to_owned()
    if is_container_id(candidate) {
      return candidate
    }
  }
  raise UnexpectedOutput(
    "expected a container id on stdout, got: \{stdout.trim()}",
  )
}

///|
fn is_container_id(value : String) -> Bool {
  if value.length() < 12 {
    return false
  }
  for c in value.to_array() {
    let is_hex = (c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'F')
    if !is_hex {
      return false
    }
  }
  true
}

///|
/// Resolve container ports to host ports from `docker inspect`.
///
/// Docker records the bindings as soon as the container is created, but right
/// after `docker run -d` the inspect output can still be empty, hence the short
/// retry loop.
async fn Container::resolve_ports(
  self : Container,
) -> Unit raise TestContainerError {
  if self.request.ports.length() == 0 {
    return
  }
  let max_attempts = 50
  let mut attempt = 0
  let mut missing : Array[Int32] = []
  while attempt < max_attempts {
    missing = []
    let json = inspect_container(self.id)
    let network_settings = match json_index(json, 0) {
      Some(container) => json_field(container, "NetworkSettings")
      None => None
    }
    let bindings = match network_settings {
      Some(settings) => json_field(settings, "Ports")
      None => None
    }
    for port in self.request.ports {
      match bindings {
        Some(bindings) =>
          match host_port_from_bindings(bindings, port) {
            Some(host_port) => self.ports.push((port, host_port))
            None => missing.push(port)
          }
        None => missing.push(port)
      }
    }
    if missing.length() == 0 {
      return
    }
    // A container that died before its ports were published will never
    // publish them; report the real cause instead of waiting for the retry
    // loop to run out.
    let status = match (Ok(self.status()) catch { e => Err(e) }) {
      Ok(status) => status
      Err(_) => "gone"
    }
    if status != "running" {
      raise ContainerNotRunning(container_id=self.id, status~)
    }
    attempt = attempt + 1
    if attempt < max_attempts {
      @async.sleep(100)
    }
  }
  let port = missing[0]
  raise PortNotMapped(container_port=port, container_id=self.id)
}

///|
fn host_port_from_bindings(bindings : Json, container_port : Int32) -> Int32? {
  let key = "\{container_port}/tcp"
  match json_field(bindings, key) {
    Some(list) =>
      match json_index(list, 0) {
        Some(binding) =>
          match json_field(binding, "HostPort") {
            Some(host_port) =>
              match json_as_string(host_port) {
                Some(text) => parse_port_number(text)
                None => None
              }
            None => None
          }
        None => None
      }
    None => None
  }
}

///|
/// Parse a decimal port number in 1..65535.
fn parse_port_number(value : String) -> Int32? {
  // Ports have at most five digits; rejecting longer input keeps the
  // accumulation below from overflowing on garbage.
  if value == "" || value.length() > 5 {
    return None
  }
  let mut number = 0
  for c in value.to_array() {
    if c < '0' || c > '9' {
      return None
    }
    number = number * 10 + (c.to_int() - '0'.to_int())
  }
  if number > 0 && number <= 65535 {
    Some(number)
  } else {
    None
  }
}

///|
fn docker_host() -> String {
  match @env.get_env_var("TESTCONTAINERS_HOST_OVERRIDE") {
    Some(host) if host != "" => host
    _ => "localhost"
  }
}

///|
fn is_missing_container_error(message : String) -> Bool {
  message.contains("No such container") ||
  message.contains("no such container") ||
  message.contains("is not running")
}
