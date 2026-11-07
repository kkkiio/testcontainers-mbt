///|
/// Configuration for the Postgres module. All fields have sensible test
/// defaults; pass labeled arguments to `new` to change them.
#derive(Debug, Eq)
pub(all) struct PostgresConfig {
  /// Docker image. Defaults to `postgres:16-alpine`.
  image : String
  /// Database created on first start (`POSTGRES_DB`).
  database : String
  /// Superuser name (`POSTGRES_USER`).
  username : String
  /// Superuser password (`POSTGRES_PASSWORD`).
  password : String
  /// Container port. Published on a random host port.
  port : Int32
  /// Readiness timeout in milliseconds.
  wait_timeout_ms : Int32
}

///|
pub extend PostgresConfig with Eq::{equal, not_equal}

///|
pub extend PostgresConfig with Debug::{to_repr}

///|
/// Default configuration: `postgres:16-alpine` with user, password and database
/// all set to `postgres`, like the other testcontainers implementations.
/// Override any field with a labeled argument, e.g.
/// `PostgresConfig::new(image="postgis/postgis:16-3.4")`.
pub fn PostgresConfig::new(
  image~ : String = "postgres:16-alpine",
  database~ : String = "postgres",
  username~ : String = "postgres",
  password~ : String = "postgres",
  port~ : Int32 = 5432,
  wait_timeout_ms~ : Int32 = 60_000,
) -> PostgresConfig {
  { image, database, username, password, port, wait_timeout_ms, }
}

///|
/// A running Postgres container.
pub struct PostgresContainer {
  container : @testcontainers.Container
  config : PostgresConfig
}

///|
/// Start Postgres and wait until it accepts connections.
///
/// ```mbt nocheck
/// let pg = @postgres.run()
/// defer pg.cleanup()
/// let dsn = pg.connection_string(ssl_mode="disable")
/// ```
///
/// Every option has a test-friendly default and can be overridden with a
/// labeled argument, e.g. `@postgres.run(image="postgis/postgis:16-3.4",
/// database="appdb")`. `reuse` forwards to `ContainerRequest::with_reuse`.
pub async fn run(
  image~ : String = "postgres:16-alpine",
  database~ : String = "postgres",
  username~ : String = "postgres",
  password~ : String = "postgres",
  port~ : Int32 = 5432,
  wait_timeout_ms~ : Int32 = 60_000,
  reuse~ : Bool = false,
) -> PostgresContainer {
  let config = PostgresConfig::new(
    image~,
    database~,
    username~,
    password~,
    port~,
    wait_timeout_ms~,
  )
  let request = @testcontainers.ContainerRequest::new(config.image)
    .with_reuse(reuse~)
    .with_port(config.port)
    .with_env("POSTGRES_USER", config.username)
    .with_env("POSTGRES_PASSWORD", config.password)
    .with_env("POSTGRES_DB", config.database)
    // fsync=off is what testcontainers-go does too: throwaway test data does
    // not need to survive a crash, and it makes initdb noticeably faster.
    .with_cmd(["postgres", "-c", "fsync=off"])
    .with_wait_for(
      @testcontainers.WaitStrategy::All([
        // pg_isready with -h 127.0.0.1 forces a TCP connection. Without -h it
        // would talk to the Unix socket of initdb's temporary server and
        // report ready while the real server is still starting.
        @testcontainers.WaitStrategy::Exec([
          "pg_isready",
          "-h",
          "127.0.0.1",
          "-U",
          config.username,
          "-d",
          config.database,
        ]),
        @testcontainers.WaitStrategy::TcpPort(config.port),
      ]),
    )
    .with_wait_timeout_ms(config.wait_timeout_ms)
  let container = request.start()
  { container, config, }
}

///|
/// The underlying generic container, for exec, logs and so on.
pub fn PostgresContainer::container(
  self : PostgresContainer,
) -> @testcontainers.Container {
  self.container
}

///|
/// Host that reaches the published Postgres port.
pub fn PostgresContainer::host(self : PostgresContainer) -> String {
  self.container.host()
}

///|
/// Host port the container's 5432 is published on.
pub fn PostgresContainer::port(self : PostgresContainer) -> Int32 raise {
  self.container.host_port(self.config.port)
}

///|
/// Database name.
pub fn PostgresContainer::database(self : PostgresContainer) -> String {
  self.config.database
}

///|
/// User name.
pub fn PostgresContainer::username(self : PostgresContainer) -> String {
  self.config.username
}

///|
/// Password.
pub fn PostgresContainer::password(self : PostgresContainer) -> String {
  self.config.password
}

///|
/// `postgres://user:password@host:port/database`, optionally with
/// `?sslmode=<mode>`.
///
/// Pass `ssl_mode="disable"` for plain local test containers; the default adds
/// no query parameter at all.
pub fn PostgresContainer::connection_string(
  self : PostgresContainer,
  ssl_mode? : String,
) -> String raise {
  let port = self.port()
  let base = "postgres://" +
    @percent.encode(self.config.username) +
    ":" +
    @percent.encode(self.config.password) +
    "@" +
    @testcontainers.join_host_port(self.container.host(), port) +
    "/" +
    @percent.encode(self.config.database)
  match ssl_mode {
    Some(mode) => base + "?sslmode=" + @percent.encode(mode)
    None => base
  }
}

///|
/// Stop the container.
pub async fn PostgresContainer::stop(self : PostgresContainer) -> Unit {
  self.container.stop()
}

///|
/// Force-remove the container. Never raises, safe for `defer`.
pub async fn PostgresContainer::cleanup(
  self : PostgresContainer,
) -> Unit noraise + nocancel {
  self.container.cleanup()
}
