///|
/// Result of running a docker CLI command.
///
/// `stdout` and `stderr` are kept separate on purpose: `docker run -d` prints
/// the container id on stdout while image pull progress goes to stderr. Mixing
/// them (as a `2>&1` shell would) is the classic source of "container id is not
/// hex" bugs.
pub(all) struct CommandOutput {
  code : Int32
  stdout : String
  stderr : String
}

///|
/// Escape one argument for display in error messages. This is only used for
/// humans; commands are always executed without a shell.
fn quote_arg(arg : String) -> String {
  let needs_quotes = arg == "" ||
    arg.contains(" ") ||
    arg.contains("\t") ||
    arg.contains("\"") ||
    arg.contains("'") ||
    arg.contains("$") ||
    arg.contains("\\")
  if !needs_quotes {
    return arg
  }
  let mut out = "\""
  for c in arg.to_array() {
    if c == '"' || c == '\\' || c == '$' {
      out = out + "\\"
    }
    out = out + c.to_string()
  }
  out + "\""
}

///|
/// Render a command line for error messages.
pub fn render_command(program : String, args : ArrayView[String]) -> String {
  let parts : Array[String] = [program]
  let mut redact_next = false
  for arg in args {
    if redact_next {
      parts.push(quote_arg(redact_env_arg(arg)))
      redact_next = false
    } else {
      parts.push(quote_arg(arg))
    }
    if arg == "--env" || arg == "-e" {
      redact_next = true
    }
  }
  parts.join(" ")
}

///|
/// Hide the value of `NAME=value` so credentials passed with `--env` do not end
/// up in error messages and test logs.
fn redact_env_arg(arg : String) -> String {
  let parts = arg.split("=").to_array()
  if parts.length() >= 2 {
    parts[0].to_owned() + "=***"
  } else {
    "***"
  }
}

///|
/// Run the `docker` CLI. Arguments are passed directly to the process, never
/// through a shell, so spaces and quotes in env values and commands are safe.
///
/// Returns the exit code and both output streams; a non-zero exit code is not
/// turned into an error here because some callers (wait strategies, `exec`)
/// treat it as data.
pub async fn docker_command(args : ArrayView[String]) -> CommandOutput {
  let (code, stdout, stderr) = @process.collect_output("docker", args) catch {
    e => raise DockerNotAvailable(e.to_string())
  }
  let stdout = stdout.text() catch {
    e => raise UnexpectedOutput("cannot read docker stdout: \{e.to_string()}")
  }
  let stderr = stderr.text() catch {
    e => raise UnexpectedOutput("cannot read docker stderr: \{e.to_string()}")
  }
  // A missing docker binary raises from `collect_output` and is mapped to
  // `DockerNotAvailable` above. Do not try to detect it from exit codes: a
  // `docker exec` whose command is missing inside the container also exits with
  // 127 and must stay a normal command failure.
  let output : CommandOutput = { code, stdout, stderr, }
  output
}

///|
/// Run a docker command and fail with `DockerCommandFailed` on a non-zero exit
/// code. Returns stdout.
pub async fn docker(args : ArrayView[String]) -> String {
  let output = docker_command(args)
  if output.code != 0 {
    raise DockerCommandFailed(
      command=render_command("docker", args),
      code=output.code,
      stderr=command_error_text(output),
    )
  }
  output.stdout
}

///|
/// Pick the most useful stream for an error message. docker is inconsistent:
/// most failures go to stderr, but some (`docker port` on an unknown container
/// on old versions, for example) go to stdout.
pub fn command_error_text(output : CommandOutput) -> String {
  let stderr = output.stderr.trim().to_owned()
  let stdout = output.stdout.trim().to_owned()
  if stderr != "" {
    stderr
  } else if stdout != "" {
    stdout
  } else {
    "(no output)"
  }
}

///|
/// `docker inspect` for a container, parsed as JSON.
pub async fn inspect_container(id : String) -> Json {
  let stdout = docker(["inspect", "--type", "container", id])
  @json.parse(stdout) catch {
    e =>
      raise UnexpectedOutput(
        "cannot parse `docker inspect \{short_id(id)}` output: \{e.to_string()}",
      )
  }
}

///|
/// `docker inspect` for an image. Returns `false` when the image is not present
/// locally.
pub async fn image_exists(image : String) -> Bool {
  let output = docker_command(["image", "inspect", "--format", "{{.Id}}", image])
  if output.code == 0 {
    return true
  }
  let text = command_error_text(output)
  if text.contains("No such image") || text.contains("No such object") {
    return false
  }
  // A broken docker installation should not be reported as "image missing".
  raise DockerCommandFailed(
    command=render_command("docker", ["image", "inspect", image]),
    code=output.code,
    stderr=text,
  )
}

///|
/// Pull `image`, unless it is already present locally and the request allows
/// reusing it.
pub async fn pull_image(image : String) -> Unit {
  let output = docker_command(["pull", image])
  if output.code != 0 {
    raise ImagePullFailed(image~, stderr=command_error_text(output))
  }
}
