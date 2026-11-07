///|
/// Every fallible testcontainers operation raises `TestContainerError`.
///
/// The payloads carry enough context to debug a failed test without re-running
/// it: the exact docker command, the exit status, the container's output and,
/// for wait timeouts, the container logs.
#derive(Debug)
pub suberror TestContainerError {
  /// The `docker` executable could not be spawned at all. This usually means
  /// Docker is not installed or not on `PATH`.
  DockerNotAvailable(String)
  /// A docker command exited with a non-zero status.
  DockerCommandFailed(command~ : String, code~ : Int32, stderr~ : String)
  /// Pulling the image failed.
  ImagePullFailed(image~ : String, stderr~ : String)
  /// The container never became ready before the wait timeout expired.
  WaitTimeout(strategy~ : String, timeout_ms~ : Int32, logs~ : String)
  /// The container port was not published, so no host port could be resolved.
  PortNotMapped(container_port~ : Int32, container_id~ : String)
  /// The container request is malformed (bad mount, bad port, ...).
  InvalidRequest(String)
  /// The container was expected to be running but is not.
  ContainerNotRunning(container_id~ : String, status~ : String)
  /// Output of a docker command could not be parsed.
  UnexpectedOutput(String)
}

///|
pub impl Show for TestContainerError with fn to_string(self) {
  match self {
    DockerNotAvailable(message) =>
      "Docker is not available: \{message}\n" +
      "Install Docker and make sure the `docker` CLI is on your PATH:\n" +
      "  https://docs.docker.com/get-docker/"
    DockerCommandFailed(command~, code~, stderr~) =>
      "docker command failed with exit code \{code}:\n" +
      "  $\{command}\n" +
      (if stderr == "" { "(no output)" } else { stderr })
    ImagePullFailed(image~, stderr~) =>
      "failed to pull image `\{image}`:\n" + stderr
    WaitTimeout(strategy~, timeout_ms~, logs~) =>
      "container did not become ready within \{timeout_ms} ms " +
      "(wait strategy: \{strategy}).\n" +
      "Last container logs:\n" +
      (if logs == "" { "(no logs)" } else { logs })
    PortNotMapped(container_port~, container_id~) =>
      "container \{short_id(container_id)} does not publish port \{container_port}. " +
      "Add it with `ContainerRequest::with_port(\{container_port})`."
    InvalidRequest(message) => "invalid container request: \{message}"
    ContainerNotRunning(container_id~, status~) =>
      "container \{short_id(container_id)} is not running (status: \{status})"
    UnexpectedOutput(message) => "unexpected docker output: \{message}"
  }
}

///|
/// Promote the trait methods to inherent methods so `err.to_string()` works
/// without importing the traits.
pub extend TestContainerError with Show::{to_string, output}

///|
pub extend TestContainerError with Debug::{to_repr}

///|
/// Abbreviate a container id the way docker does (first 12 characters).
pub fn short_id(id : String) -> String {
  if id.length() <= 12 {
    return id
  }
  let chars = id.to_array()
  let out : Array[Char] = []
  for i = 0; i < 12; i = i + 1 {
    out.push(chars[i])
  }
  String::from_array(out)
}
