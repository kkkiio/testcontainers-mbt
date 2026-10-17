///|
test "error messages are the user-facing diagnostics" {
  // Constructed with fixed ids, ports and logs: no Docker involved, no
  // randomness. One labelled transcript documents every variant at once.
  let id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let cases : Array[(String, @testcontainers.TestContainerError)] = [
    (
      "DockerNotAvailable",
      @testcontainers.DockerNotAvailable(
        "OSError(\"@process.run(): No such file or directory\")",
      ),
    ),
    (
      "DockerCommandFailed",
      @testcontainers.DockerCommandFailed(
        command="docker run --detach --publish 5432 postgres:16-alpine",
        code=125,
        stderr="docker: Error response from daemon: No such image",
      ),
    ),
    (
      "ImagePullFailed",
      @testcontainers.ImagePullFailed(
        image="ghcr.io/acme/private:1.0",
        stderr="denied: requested access to the resource is denied",
      ),
    ),
    (
      "WaitTimeout",
      @testcontainers.WaitTimeout(
        strategy="TCP port 5432",
        timeout_ms=60_000,
        logs="booting\nwaiting for connections",
      ),
    ),
    (
      "PortNotMapped",
      @testcontainers.PortNotMapped(container_port=5432, container_id=id),
    ),
    (
      "InvalidRequest",
      @testcontainers.InvalidRequest(
        "bind mount source `data` must be an absolute host path; use `with_volume` for a docker named volume",
      ),
    ),
    (
      "ContainerNotRunning",
      @testcontainers.ContainerNotRunning(container_id=id, status="exited"),
    ),
    (
      "UnexpectedOutput",
      @testcontainers.UnexpectedOutput(
        "expected a container id on stdout, got: pulling from library/alpine",
      ),
    ),
    (
      "IoFailed",
      @testcontainers.IoFailed(
        "cannot create temporary directory: PermissionDenied",
      ),
    ),
  ]
  debug_inspect(
    cases.map(pair => {
      let (name, error) = pair
      "[\{name}]\n\{error.to_string()}"
    }),
    content=(
      #|[
      #|  "[DockerNotAvailable]\nDocker is not available: OSError(\"@process.run(): No such file or directory\")\nInstall Docker and make sure the `docker` CLI is on your PATH:\n  https://docs.docker.com/get-docker/",
      #|  "[DockerCommandFailed]\ndocker command failed with exit code 125:\n  $docker run --detach --publish 5432 postgres:16-alpine\ndocker: Error response from daemon: No such image",
      #|  "[ImagePullFailed]\nfailed to pull image `ghcr.io/acme/private:1.0`:\ndenied: requested access to the resource is denied",
      #|  "[WaitTimeout]\ncontainer did not become ready within 60000 ms (wait strategy: TCP port 5432).\nLast container logs:\nbooting\nwaiting for connections",
      #|  "[PortNotMapped]\ncontainer 0123456789ab does not publish port 5432. Add it with `ContainerRequest::with_port(5432)`.",
      #|  "[InvalidRequest]\ninvalid container request: bind mount source `data` must be an absolute host path; use `with_volume` for a docker named volume",
      #|  "[ContainerNotRunning]\ncontainer 0123456789ab is not running (status: exited)",
      #|  "[UnexpectedOutput]\nunexpected docker output: expected a container id on stdout, got: pulling from library/alpine",
      #|  "[IoFailed]\nI/O error: cannot create temporary directory: PermissionDenied",
      #|]
    ),
  )
}
