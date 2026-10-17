///|
/// Options for `docker logs`.
pub(all) struct LogOptions {
  /// Only the last N lines (`--tail`).
  tail : Int32?
  /// Prefix each line with an RFC3339Nano timestamp (`--timestamps`).
  timestamps : Bool
  /// Show logs since a timestamp or relative duration (`--since`).
  since : String?
  /// Show logs before a timestamp or relative duration (`--until`).
  until : String?
} derive(Debug, Eq)

///|
pub extend LogOptions with Eq::{equal, not_equal}

///|
pub extend LogOptions with Debug::{to_repr}

///|
/// Default options: the whole log, no timestamps. Override any field with a
/// labeled argument, e.g. `LogOptions::new(tail=50, timestamps=true)`.
pub fn LogOptions::new(
  tail? : Int32,
  timestamps~ : Bool = false,
  since? : String,
  until? : String,
) -> LogOptions {
  { tail, timestamps, since, until, }
}

///|
/// `docker logs` arguments for the given options.
fn logs_args(container_id : String, options : LogOptions) -> Array[String] {
  let args : Array[String] = ["logs"]
  if options.timestamps {
    args.push("--timestamps")
  }
  match options.tail {
    Some(lines) => {
      args.push("--tail")
      args.push(lines.to_string())
    }
    None => ()
  }
  match options.since {
    Some(timestamp) => {
      args.push("--since")
      args.push(timestamp)
    }
    None => ()
  }
  match options.until {
    Some(timestamp) => {
      args.push("--until")
      args.push(timestamp)
    }
    None => ()
  }
  args.push(container_id)
  args
}

///|
/// Container logs, stdout and stderr combined.
///
/// Docker keeps the two streams apart; they are concatenated here (stdout
/// first). Use `logs_split` when the distinction matters. For readiness checks
/// this is fine because application logs usually go to stderr.
pub async fn Container::logs(
  self : Container,
  options? : LogOptions,
) -> String raise TestContainerError {
  let options = match options {
    Some(options) => options
    None => LogOptions::new()
  }
  let split = self.logs_split(options~)
  combine_logs(split.stdout, split.stderr)
}

///|
/// Container logs with stdout and stderr kept apart.
pub async fn Container::logs_split(
  self : Container,
  options? : LogOptions,
) -> LogOutput raise TestContainerError {
  let options = match options {
    Some(options) => options
    None => LogOptions::new()
  }
  let output = docker_command(logs_args(self.id, options))
  if output.code != 0 {
    raise DockerCommandFailed(
      command=render_command("docker", logs_args(self.id, options)),
      code=output.code,
      stderr=command_error_text(output),
    )
  }
  { stdout: output.stdout, stderr: output.stderr, }
}

///|
pub(all) struct LogOutput {
  stdout : String
  stderr : String
} derive(Debug, Eq)

///|
pub extend LogOutput with Eq::{equal, not_equal}

///|
pub extend LogOutput with Debug::{to_repr}

///|
fn combine_logs(stdout : String, stderr : String) -> String {
  let stdout = stdout.trim_end().to_owned()
  let stderr = stderr.trim_end().to_owned()
  if stdout == "" {
    stderr
  } else if stderr == "" {
    stdout
  } else {
    stdout + "\n" + stderr
  }
}

///|
/// Stream `docker logs --follow` line by line until the container exits or
/// `f` raises.
///
/// The callback receives each line without its trailing newline.
pub async fn Container::stream_logs(
  self : Container,
  f : (String) -> Unit raise,
) -> Unit {
  @async.with_task_group(group => {
    let (reader, writer) = @process.read_from_process() catch {
      e => raise DockerNotAvailable(e.to_string())
    }
    defer reader.close()
    let _ = @process.spawn(
      group,
      "docker",
      ["logs", "--follow", "--tail", "0", self.id],
      stdout=writer,
      stderr=writer,
    ) catch {
      e => raise DockerNotAvailable(e.to_string())
    }
    defer writer.close()
    while true {
      match reader.read_until("\n") {
        Some(line) => f(line)
        None => break
      }
    }
  })
}

///|
/// Last `lines` lines of the logs, or an empty string when they cannot be read.
/// Used to enrich error messages; never fails.
async fn Container::logs_for_error(self : Container) -> String {
  let result : Result[String, TestContainerError] = Ok(
    self.logs(options=LogOptions::new(tail=200)),
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(logs) => logs
    Err(_) => ""
  }
}
