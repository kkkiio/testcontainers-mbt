// Wait strategies.
//
// All strategies share one polling loop: every `WAIT_POLL_INTERVAL_MS` the
// strategy is evaluated once until it reports ready, the deadline passes or the
// container dies. Polling (instead of blocking waits) keeps timeout handling
// uniform and makes `All` / `Any` compositions trivial.
//
// Errors raised while probing (connection refused, `docker exec` failing while
// the container is still starting, ...) are treated as "not ready yet". Only
// explicit `Probe::Fatal` results fail the wait immediately.

///|
/// How often a wait strategy is evaluated.
const WAIT_POLL_INTERVAL_MS : Int32 = 100

///|
/// How many log lines a `LogMessage` wait looks at. Reading unbounded logs on
/// every poll would be wasteful for chatty containers; the last 2000 lines are
/// plenty for a readiness banner.
const WAIT_LOG_TAIL : Int32 = 2000

///|
/// Outcome of one readiness probe.
priv enum Probe {
  Ready
  NotReady
  /// The container can never become ready (died, unhealthy, missing health
  /// check). Reported immediately instead of waiting for the timeout.
  Fatal(String)
}

///|
/// Wait for the request's wait strategy. Called by `ContainerRequest::start`.
pub async fn Container::wait_ready(
  self : Container,
) -> Unit raise TestContainerError {
  let timeout_ms = self.request.wait_timeout_ms
  let start = @async.now()
  let deadline = start + timeout_ms.to_int64()
  self.wait_until(self.request.wait, start, deadline, timeout_ms)
}

///|
/// Wait for another readiness condition, using the request's timeout by default.
///
/// Useful for multi-phase startup: wait for the port first, then for a migration
/// to finish, and so on.
pub async fn Container::wait_for(
  self : Container,
  strategy : WaitStrategy,
  timeout_ms? : Int32,
) -> Unit raise TestContainerError {
  let timeout_ms = match timeout_ms {
    Some(timeout_ms) => timeout_ms
    None => self.request.wait_timeout_ms
  }
  let start = @async.now()
  self.wait_until(strategy, start, start + timeout_ms.to_int64(), timeout_ms)
}

///|
async fn Container::wait_until(
  self : Container,
  strategy : WaitStrategy,
  start : Int64,
  deadline : Int64,
  timeout_ms : Int32,
) -> Unit raise TestContainerError {
  if strategy is NoWait {
    return
  }
  let mut rounds = 0
  while true {
    let remaining = deadline - @async.now()
    if remaining <= 0 {
      break
    }
    // Bound the probe itself: a hanging `docker exec` (or a stalled daemon)
    // must not keep the wait alive past its deadline. `with_timeout_opt`
    // cancels the task running the probe.
    let probed : Result[Probe?, Error] = Ok(
      @async.with_timeout_opt(remaining.to_int(), () => {
        self.probe(strategy, start)
      }),
    ) catch {
      e => Err(e)
    }
    let outcome = match probed {
      Ok(Some(probe)) => probe
      _ => NotReady
    }
    match outcome {
      Ready => return
      Fatal(message) =>
        raise ContainerNotRunning(container_id=self.id, status=message)
      NotReady => ()
    }
    if @async.now() >= deadline {
      break
    }
    // Fail fast when the container exited instead of waiting for the full
    // timeout. Checking the state costs an extra docker call, so only do it
    // about once per second.
    rounds = rounds + 1
    if rounds % 10 == 0 && !is_exit_strategy(strategy) {
      let status = match (Ok(self.status()) catch { e => Err(e) }) {
        Ok(status) => status
        Err(_) => "unknown"
      }
      if status == "exited" || status == "dead" {
        raise ContainerNotRunning(container_id=self.id, status~)
      }
    }
    let remaining = deadline - @async.now()
    let sleep_ms = if remaining < WAIT_POLL_INTERVAL_MS.to_int64() {
      remaining.to_int()
    } else {
      WAIT_POLL_INTERVAL_MS
    }
    if sleep_ms > 0 {
      @async.sleep(sleep_ms)
    }
  }
  let logs = match (Ok(self.logs_for_error()) catch { e => Err(e) }) {
    Ok(logs) => logs
    Err(_) => ""
  }
  raise WaitTimeout(strategy=strategy.describe(), timeout_ms~, logs~)
}

///|
fn is_exit_strategy(strategy : WaitStrategy) -> Bool {
  match strategy {
    Exit(_) => true
    All(strategies) => strategies.any(s => is_exit_strategy(s))
    Any(strategies) => strategies.all(s => is_exit_strategy(s))
    _ => false
  }
}

///|
async fn Container::probe(
  self : Container,
  strategy : WaitStrategy,
  start : Int64,
) -> Probe {
  match strategy {
    NoWait => Ready
    Seconds(seconds) =>
      if @async.now() - start >= (seconds * 1000).to_int64() {
        Ready
      } else {
        NotReady
      }
    TcpPort(container_port) => self.probe_tcp(container_port)
    HttpGet(container_port, path, status) =>
      self.probe_http(container_port, path, status)
    LogMessage(message) => self.probe_log(message)
    Exec(cmd) => self.probe_exec(cmd)
    Healthy => self.probe_healthy()
    Exit(code) => self.probe_exit(code)
    All(strategies) => {
      let mut pending : Probe = Ready
      for strategy in strategies {
        match self.probe(strategy, start) {
          Ready => ()
          other => {
            pending = other
            break
          }
        }
      }
      pending
    }
    Any(strategies) => {
      if strategies.length() == 0 {
        return Ready
      }
      let mut fatal : Probe? = None
      for strategy in strategies {
        match self.probe(strategy, start) {
          Ready => return Ready
          Fatal(message) => fatal = Some(Fatal(message))
          NotReady => ()
        }
      }
      match fatal {
        Some(result) => result
        None => NotReady
      }
    }
  }
}

///|
/// Outcome of the in-container listening check.
priv enum ListeningState {
  Listening
  NotListening
  /// The image has no usable procfs/`cat`, so the caller must probe the host
  /// port instead.
  Unknown
  /// The container is no longer running; waiting can never succeed.
  Dead(String)
}

///|
/// Is `container_port` in LISTEN state inside the container?
///
/// A plain TCP connect from the host is not a reliable readiness signal: when
/// docker uses its userland proxy, connections to a published port are accepted
/// even when nothing inside the container listens on it. Reading `/proc/net/tcp`
/// inside the container avoids that false positive.
async fn Container::listening_inside(
  self : Container,
  container_port : Int32,
) -> ListeningState {
  let output = self.exec(["cat", "/proc/net/tcp", "/proc/net/tcp6"])
  // Docker reports a failed `exec` on *stdout* ("OCI runtime exec failed:
  // ... executable file not found"), so an empty stdout is not enough to
  // distinguish "no procfs in the image" from a real listing.
  if output.stdout.contains("local_address") {
    return if parse_listening_ports(output.stdout).contains(container_port) {
      Listening
    } else {
      NotListening
    }
  }
  // The exec failed: the image may have no `cat`, or the container may be
  // dead. Never fall through to a host connect for a dead container: the
  // userland proxy would accept the connection and report a stopped service as
  // ready.
  let status = match (Ok(self.status()) catch { e => Err(e) }) {
    Ok(status) => status
    Err(_) => "gone"
  }
  if status == "running" {
    Unknown
  } else {
    Dead(status)
  }
}

///|
async fn Container::probe_tcp(
  self : Container,
  container_port : Int32,
) -> Probe {
  let host_port = match self.host_port_opt(container_port) {
    Some(port) => port
    None => return Fatal("port \{container_port} is not published")
  }
  match self.listening_inside(container_port) {
    Listening => Ready
    NotListening => NotReady
    Unknown => self.probe_tcp_from_host(host_port)
    Dead(status) => Fatal(status)
  }
}

///|
async fn Container::probe_tcp_from_host(
  self : Container,
  host_port : Int32,
) -> Probe {
  // Bound the connect attempt: a filtered port can otherwise hang until the
  // kernel gives up, long after the wait deadline.
  let tcp = @async.with_timeout_opt(2_000, () => {
    @socket.Tcp::connect_to_host(self.host, port=host_port)
  })
  match tcp {
    Some(tcp) => {
      tcp.close()
      Ready
    }
    None => NotReady
  }
}

///|
/// Ports in LISTEN state from the contents of `/proc/net/tcp` and
/// `/proc/net/tcp6`. Lines look like
/// `   0: 00000000:1F90 00000000:0000 0A ...`, where the local address ends in
/// the port as four uppercase hex digits.
fn parse_listening_ports(content : String) -> Array[Int32] {
  let ports : Array[Int32] = []
  for line in content.split("\n") {
    let fields = split_whitespace(line)
    if fields.length() >= 4 && fields[3] == "0A" {
      let parts = fields[1].split(":").to_array()
      if parts.length() == 2 {
        match parse_hex_port(parts[1]) {
          Some(port) => if !ports.contains(port) { ports.push(port) }
          None => ()
        }
      }
    }
  }
  ports
}

///|
fn parse_hex_port(value : StringView) -> Int32? {
  if value.length() == 0 || value.length() > 4 {
    return None
  }
  let mut port = 0
  for c in value.to_array() {
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else {
      return None
    }
    port = port * 16 + digit
  }
  Some(port)
}

///|
fn split_whitespace(line : StringView) -> Array[String] {
  let fields : Array[String] = []
  let current = StringBuilder()
  let mut has_current = false
  for c in line.to_array() {
    if c == ' ' || c == '\t' || c == '\r' {
      if has_current {
        fields.push(current.to_string())
        current.reset()
        has_current = false
      }
    } else {
      current.write_char(c)
      has_current = true
    }
  }
  if has_current {
    fields.push(current.to_string())
  }
  fields
}

///|
async fn Container::probe_http(
  self : Container,
  container_port : Int32,
  path : String,
  status : Int32,
) -> Probe {
  let host_port = match self.host_port_opt(container_port) {
    Some(port) => port
    None => return Fatal("port \{container_port} is not published")
  }
  let url = "http://" + join_host_port(self.host, host_port) + path
  let response = @async.with_timeout_opt(2_000, () => @http.get(url))
  match response {
    Some((response, _body)) =>
      if response.code == status {
        Ready
      } else {
        NotReady
      }
    None => NotReady
  }
}

///|
async fn Container::probe_log(self : Container, message : String) -> Probe {
  let result : Result[String, TestContainerError] = Ok(
    self.logs(options=LogOptions::default().with_tail(WAIT_LOG_TAIL)),
  ) catch {
    e => Err(e)
  }
  let logs = match result {
    Ok(logs) => logs
    Err(_) => return NotReady
  }
  if logs.contains(message) {
    Ready
  } else {
    NotReady
  }
}

///|
async fn Container::probe_exec(self : Container, cmd : Array[String]) -> Probe {
  let output = self.exec(cmd)
  if output.code == 0 {
    Ready
  } else {
    NotReady
  }
}

///|
async fn Container::probe_healthy(self : Container) -> Probe {
  let json = inspect_container(self.id)
  let state = match json_index(json, 0) {
    Some(container) => json_field(container, "State")
    None => None
  }
  let health = match state {
    Some(state) => json_field(state, "Health")
    None => None
  }
  match health {
    None =>
      Fatal(
        "the image has no HEALTHCHECK; use another WaitStrategy or add a HEALTHCHECK to the image",
      )
    Some(health) =>
      match json_field(health, "Status") {
        Some(status) =>
          match json_as_string(status) {
            Some("healthy") => Ready
            Some("unhealthy") => Fatal("container is unhealthy")
            Some(_) => NotReady
            None => NotReady
          }
        None => NotReady
      }
  }
}

///|
async fn Container::probe_exit(self : Container, expected : Int32) -> Probe {
  let json = inspect_container(self.id)
  let state = match json_index(json, 0) {
    Some(container) => json_field(container, "State")
    None => None
  }
  let state = match state {
    Some(state) => state
    None => return NotReady
  }
  let status = match json_field(state, "Status") {
    Some(status) => json_as_string(status) |> unwrap_or("unknown")
    None => "unknown"
  }
  // Anything that is not a final state can still change; only exited/dead
  // containers have a meaningful exit code.
  if status != "exited" && status != "dead" {
    return NotReady
  }
  let exit_code = match json_field(state, "ExitCode") {
    Some(code) => json_as_int(code) |> unwrap_or(-1)
    None => -1
  }
  if exit_code == expected {
    Ready
  } else {
    Fatal("container exited with code \{exit_code}, expected \{expected}")
  }
}
