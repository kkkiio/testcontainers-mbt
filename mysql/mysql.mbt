///|
/// Configuration for the MySQL module.
pub(all) struct MySqlConfig {
  /// Docker image. Defaults to `mysql:8.4` (the current LTS release).
  image : String
  /// Database created on first start (`MYSQL_DATABASE`).
  database : String
  /// Application user (`MYSQL_USER`).
  username : String
  /// Application user's password (`MYSQL_PASSWORD`).
  password : String
  /// Root password (`MYSQL_ROOT_PASSWORD`). Ignored when `username` is
  /// `root`: in that case `password` is used, because the root account is the
  /// application account.
  root_password : String
  /// Container port. Published on a random host port.
  port : Int32
  /// Readiness timeout in milliseconds.
  wait_timeout_ms : Int32
} derive(Debug, Eq)

///|
pub extend MySqlConfig with Eq::{equal, not_equal}

///|
pub extend MySqlConfig with Debug::{to_repr}

///|
/// Default configuration: `mysql:8.4` with user, password and database all set
/// to `test` and root password `test`.
pub fn MySqlConfig::new() -> MySqlConfig {
  {
    image: "mysql:8.4",
    database: "test",
    username: "test",
    password: "test",
    root_password: "test",
    port: 3306,
    wait_timeout_ms: 90_000,
  }
}

///|
/// Use another image, e.g. `mysql:8.0`, `mariadb:11` or a Percona image.
pub fn MySqlConfig::with_image(
  self : MySqlConfig,
  image : String,
) -> MySqlConfig {
  { ..self, image, }
}

///|
/// Set database name and application credentials.
pub fn MySqlConfig::with_credentials(
  self : MySqlConfig,
  username : String,
  password : String,
) -> MySqlConfig {
  { ..self, username, password, }
}

///|
/// Set the database name.
pub fn MySqlConfig::with_database(
  self : MySqlConfig,
  database : String,
) -> MySqlConfig {
  { ..self, database, }
}

///|
/// Set the root password.
pub fn MySqlConfig::with_root_password(
  self : MySqlConfig,
  root_password : String,
) -> MySqlConfig {
  { ..self, root_password, }
}

///|
/// Use a different container port. Rarely needed.
pub fn MySqlConfig::with_port(self : MySqlConfig, port : Int32) -> MySqlConfig {
  { ..self, port, }
}

///|
/// Set the readiness timeout in milliseconds. MySQL initialization is slower
/// than Postgres, hence the larger default (90 seconds).
pub fn MySqlConfig::with_wait_timeout_ms(
  self : MySqlConfig,
  timeout_ms : Int32,
) -> MySqlConfig {
  { ..self, wait_timeout_ms: timeout_ms, }
}

///|
/// A running MySQL container.
pub struct MySqlContainer {
  container : @testcontainers.Container
  config : MySqlConfig
}

///|
/// Start MySQL and wait until the database accepts TCP connections from the
/// configured application user.
pub async fn run(
  config? : MySqlConfig,
) -> MySqlContainer raise @testcontainers.TestContainerError {
  let config = match config {
    Some(config) => config
    None => MySqlConfig::new()
  }
  let mut request = @testcontainers.ContainerRequest::new(config.image)
    .with_port(config.port)
    .with_env("MYSQL_DATABASE", config.database)
  let uses_root = config.username == "root"
  if uses_root {
    // The MySQL image refuses to create MYSQL_USER=root; the root account
    // already exists, so only its password needs to be set.
    request = request.with_env("MYSQL_ROOT_PASSWORD", config.password)
  } else {
    request = request
      .with_env("MYSQL_ROOT_PASSWORD", config.root_password)
      .with_env("MYSQL_USER", config.username)
      .with_env("MYSQL_PASSWORD", config.password)
  }
  // A real query over TCP is the only reliable readiness signal: MySQL runs a
  // temporary server during initialization that is reachable on the socket but
  // not yet on the network port, and its log messages differ between 8.0, 8.4
  // and MariaDB. The credentials are read from the container environment, so
  // they never show up in the docker command line of the wait probe.
  let port_arg = "-P" + config.port.to_string()
  let wait_query = if uses_root {
    "mysql -h127.0.0.1 \{port_arg} -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e 'SELECT 1' \"$MYSQL_DATABASE\""
  } else {
    "mysql -h127.0.0.1 \{port_arg} -u\"$MYSQL_USER\" -p\"$MYSQL_PASSWORD\" -e 'SELECT 1' \"$MYSQL_DATABASE\""
  }
  let request = request
    .with_wait_for(
      @testcontainers.WaitStrategy::All([
        @testcontainers.WaitStrategy::TcpPort(config.port),
        @testcontainers.WaitStrategy::Exec(["sh", "-c", wait_query]),
      ]),
    )
    .with_wait_timeout_ms(config.wait_timeout_ms)
  let container = request.start()
  { container, config, }
}

///|
/// The underlying generic container, for exec, logs and so on.
pub fn MySqlContainer::container(
  self : MySqlContainer,
) -> @testcontainers.Container {
  self.container
}

///|
/// Host that reaches the published MySQL port.
pub fn MySqlContainer::host(self : MySqlContainer) -> String {
  self.container.host()
}

///|
/// Host port the container's 3306 is published on.
pub fn MySqlContainer::port(
  self : MySqlContainer,
) -> Int32 raise @testcontainers.TestContainerError {
  self.container.host_port(self.config.port)
}

///|
/// Database name.
pub fn MySqlContainer::database(self : MySqlContainer) -> String {
  self.config.database
}

///|
/// Application user name.
pub fn MySqlContainer::username(self : MySqlContainer) -> String {
  self.config.username
}

///|
/// Application user's password.
pub fn MySqlContainer::password(self : MySqlContainer) -> String {
  self.config.password
}

///|
/// `mysql://user:password@host:port/database`.
pub fn MySqlContainer::connection_string(
  self : MySqlContainer,
) -> String raise @testcontainers.TestContainerError {
  "mysql://" +
  @percent.encode(self.config.username) +
  ":" +
  @percent.encode(self.config.password) +
  "@" +
  @testcontainers.join_host_port(self.container.host(), self.port()) +
  "/" +
  @percent.encode(self.config.database)
}

///|
/// Go-style DSN used by `go-sql-driver/mysql` and several MoonBit drivers:
/// `user:password@tcp(host:port)/database`.
pub fn MySqlContainer::dsn(
  self : MySqlContainer,
) -> String raise @testcontainers.TestContainerError {
  self.config.username +
  ":" +
  self.config.password +
  "@tcp(" +
  @testcontainers.join_host_port(self.container.host(), self.port()) +
  ")/" +
  self.config.database
}

///|
/// Stop the container.
pub async fn MySqlContainer::stop(
  self : MySqlContainer,
) -> Unit raise @testcontainers.TestContainerError {
  self.container.stop()
}

///|
/// Force-remove the container. Never raises, safe for `defer`.
pub async fn MySqlContainer::cleanup(self : MySqlContainer) -> Unit {
  self.container.cleanup()
}
