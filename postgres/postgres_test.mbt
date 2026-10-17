///|
async test "postgres starts and answers queries" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let container = pg.container()
  assert_true(container.is_running())
  let result = container.exec([
    "psql", "-U", "postgres", "-d", "postgres", "-tAc", "SELECT 42",
  ])
  assert_eq(result.code, 0)
  assert_eq(result.stdout.trim().to_owned(), "42")
  // The only Docker-assigned part is the port, so build the complete expected
  // DSN from the observed port instead of asserting fragments.
  assert_eq(
    pg.connection_string(ssl_mode="disable"),
    "postgres://postgres:postgres@localhost:\{pg.port()}/postgres?sslmode=disable",
  )
}

///|
async test "postgres honours custom credentials and database" {
  let pg = @postgres.run(
    config=@postgres.PostgresConfig::new()
      .with_credentials("app", "s3cr3t")
      .with_database("appdb"),
  )
  defer pg.cleanup()
  let result = pg
    .container()
    .exec(["psql", "-U", "app", "-d", "appdb", "-tAc", "SELECT current_user"])
  assert_eq(result.code, 0)
  assert_eq(result.stdout.trim().to_owned(), "app")
  assert_eq(pg.database(), "appdb")
  assert_eq(pg.username(), "app")
}

///|
test "postgres config defaults" {
  // One snapshot documents every default; adding a field shows up here.
  debug_inspect(
    @postgres.PostgresConfig::new(),
    content=(
      #|{
      #|  image: "postgres:16-alpine",
      #|  database: "postgres",
      #|  username: "postgres",
      #|  password: "postgres",
      #|  port: 5432,
      #|  wait_timeout_ms: 60000,
      #|}
    ),
  )
}
