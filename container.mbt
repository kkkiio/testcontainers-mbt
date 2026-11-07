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
  /// Started under reuse mode: `cleanup` leaves it running on purpose and
  /// `remove` is needed to delete it.
  reusable : Bool
}

///|
/// Result of `docker exec`.
#derive(Debug, Eq)
pub(all) struct ExecOutput {
  /// Exit status of the command inside the container.
  code : Int32
  stdout : String
  stderr : String
}

///|
pub extend ExecOutput with Eq::{equal, not_equal}

///|
pub extend ExecOutput with Debug::{to_repr}

///|
/// Start a container for `request` and wait until it is ready.
pub async fn run(request : ContainerRequest) -> Container {
  request.start()
}

///|
/// Start a container for this request and wait until it is ready.
///
/// The caller owns the container and must call `cleanup()` eventually; use
/// `with_container` to have that happen automatically.
pub async fn ContainerRequest::start(self : ContainerRequest) -> Container {
  validate_request(self)
  if self.reuse {
    if reuse_enabled() {
      return self.start_reusable()
    }
    warn_reuse_disabled()
  }
  // Register this process with the resource reaper before the container is
  // created, so a killed test process cannot leak it.
  ensure_reaper()
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
    reusable: false,
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
) -> Int32 raise {
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
) -> String raise {
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
) -> Unit {
  let _ = docker(["stop", "--time", timeout_seconds.to_string(), self.id])
}

///|
/// Force-remove the container and its anonymous volumes.
///
/// `nocancel`, so a `defer`red removal still finishes when the surrounding
/// test is cancelled.
pub async fn Container::remove(self : Container) -> Unit nocancel {
  let output = @async.protect_from_cancel(() => {
    docker_command(["rm", "--force", "--volumes", self.id])
  })
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
/// It is also `nocancel`: a `defer` triggered by cancellation still runs the
/// removal to completion instead of leaking the container.
pub async fn Container::cleanup(self : Container) -> Unit noraise + nocancel {
  if self.reusable {
    // Reusable containers outlive the test on purpose; `remove` deletes
    // them explicitly.
    return
  }
  let result : Result[Unit, Error] = Ok(self.remove()) catch { e => Err(e) }
  match result {
    Ok(_) => ()
    Err(e) =>
      println("testcontainers: warning: cleanup failed: \{e.to_string()}")
  }
}

///|
/// Is the container still running?
pub async fn Container::is_running(self : Container) -> Bool {
  self.status() == "running"
}

///|
/// Does the container still exist (running or stopped)? Never raises, so it is
/// safe to use in assertions after `cleanup`.
pub async fn Container::exists(self : Container) -> Bool noraise {
  let result : Result[Json, Error] = Ok(inspect_container(self.id)) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// Container state as reported by docker (`running`, `exited`, ...).
pub async fn Container::status(self : Container) -> String {
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
) -> ExecOutput {
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
) -> String {
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
) -> Unit {
  let _ = docker(["cp", host_path, "\{self.id}:\{container_path}"])
}

///|
/// Copy a file or directory out of the container (`docker cp`), e.g. a log or
/// a database dump produced during the test.
pub async fn Container::copy_from(
  self : Container,
  container_path : String,
  host_path : String,
) -> Unit {
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
async fn ContainerRequest::ensure_image(self : ContainerRequest) -> Unit {
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
  args.push("\{LABEL_MANAGED}=true")
  // The session label is what the resource reaper keys on. Reusable
  // containers must not carry it, or ryuk would delete them between test
  // runs.
  if !self.reuse {
    match current_session_id() {
      Some(session_id) => {
        args.push("--label")
        args.push("\{LABEL_SESSION}=\{session_id}")
      }
      None => ()
    }
  }
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
fn parse_container_id(stdout : String) -> String raise {
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
async fn Container::resolve_ports(self : Container) -> Unit {
  if self.request.ports.length() == 0 {
    return
  }
  let max_attempts = 50
  let mut attempt = 0
  let mut missing : Array[Int32] = []
  // Resolved bindings are collected per attempt and committed only when every
  // requested port is mapped; pushing them into `self.ports` inside the loop
  // would duplicate entries whenever a retry follows a partial resolution.
  let mut resolved : Array[(Int32, Int32)] = []
  while attempt < max_attempts {
    missing = []
    resolved = []
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
            Some(host_port) => resolved.push((port, host_port))
            None => missing.push(port)
          }
        None => missing.push(port)
      }
    }
    if missing.length() == 0 {
      for pair in resolved {
        self.ports.push(pair)
      }
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
/// Host name or IP that reaches the container's published ports.
///
/// Resolution follows testcontainers-go's `DaemonHost`:
/// `TESTCONTAINERS_HOST_OVERRIDE` wins; otherwise a `tcp://`, `http://` or
/// `https://` `DOCKER_HOST` gives the remote daemon's hostname; otherwise
/// (unix/npipe socket or unset) the host is `localhost` — unless the tests
/// themselves run inside a container, where the default network's gateway IP
/// is the host. Never raises: failures fall back to `localhost`.
async fn docker_host() -> String noraise {
  match @env.get_env_var("TESTCONTAINERS_HOST_OVERRIDE") {
    Some(host) if host != "" => return host
    _ => ()
  }
  let docker_host = match @env.get_env_var("DOCKER_HOST") {
    Some(host) => host
    None => ""
  }
  match uri_scheme(docker_host) {
    "tcp" | "http" | "https" => uri_hostname(docker_host)
    _ =>
      if in_a_container() {
        gateway_host() catch {
          _ => "localhost"
        }
      } else {
        "localhost"
      }
  }
}

///|
/// The scheme of a docker host URI: `tcp` for `tcp://host:2375`, `unix` for
/// `unix:///var/run/docker.sock`, or `""` when the value has no `scheme://`
/// prefix (e.g. a bare socket path).
fn uri_scheme(uri : String) -> String {
  let parts = uri.split("://").to_array()
  if parts.length() < 2 {
    return ""
  }
  parts[0].to_owned()
}

///|
/// The hostname of a `tcp://`, `http://` or `https://` docker host URI.
/// Userinfo, port and path are dropped; brackets are stripped from IPv6
/// literals — `join_host_port` puts them back when rendering an endpoint.
fn uri_hostname(uri : String) -> String {
  let after_scheme = uri.split("://").to_array()
  if after_scheme.length() < 2 {
    return uri
  }
  let authority = after_scheme[1].split("/").to_array()[0].to_owned()
  // `ssh://user@host`-style URIs carry a userinfo part; keep only the host.
  let userinfo = authority.split("@").to_array()
  let host_port = userinfo[userinfo.length() - 1].to_owned()
  if host_port.has_prefix("[") {
    let v6 = host_port.split("]").to_array()
    if v6.length() >= 2 {
      return v6[0][1:].to_owned()
    }
  }
  host_port.split(":").to_array()[0].to_owned()
}

///|
/// Are the tests themselves running inside a docker container? Same heuristic
/// as testcontainers-go's `InAContainer`: the `/.dockerenv` marker file.
async fn in_a_container() -> Bool noraise {
  @fs.exists("/.dockerenv") catch {
    _ => false
  }
}

///|
/// Gateway IP of the default `bridge` network — how a container reaches its
/// host. Mirrors testcontainers-go's `getGatewayIP`, which reads it from the
/// network's IPAM config.
async fn gateway_host() -> String {
  let stdout = docker(["network", "inspect", "bridge"])
  let json = @json.parse(stdout) catch {
    e =>
      raise UnexpectedOutput(
        "cannot parse `docker network inspect bridge` output: \{e.to_string()}",
      )
  }
  let config = match json_index(json, 0) {
    Some(network) =>
      match json_field(network, "IPAM") {
        Some(ipam) => json_field(ipam, "Config")
        None => None
      }
    None => None
  }
  if config is Some(Array(entries)) {
    for entry in entries {
      if json_field(entry, "Gateway") is Some(String(ip)) && ip != "" {
        return ip
      }
    }
  }
  raise UnexpectedOutput("no gateway found in `docker network inspect bridge`")
}

///|
fn is_missing_container_error(message : String) -> Bool {
  message.contains("No such container") ||
  message.contains("no such container") ||
  message.contains("is not running")
}
