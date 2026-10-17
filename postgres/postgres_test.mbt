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
  let dsn = pg.connection_string(ssl_mode="disable")
  assert_true(dsn.has_prefix("postgres://postgres:postgres@"))
  assert_true(dsn.has_suffix("/postgres?sslmode=disable"))
  assert_true(dsn.contains(":\{pg.port()}"))
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
test "postgres config defaults match the other testcontainers modules" {
  let config = @postgres.PostgresConfig::new()
  assert_eq(config.image, "postgres:16-alpine")
  assert_eq(config.username, "postgres")
  assert_eq(config.password, "postgres")
  assert_eq(config.database, "postgres")
  assert_eq(config.port, 5432)
}
