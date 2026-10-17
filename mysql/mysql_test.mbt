///|
async test "mysql starts and answers queries" {
  let db = @mysql.run()
  defer db.cleanup()
  let container = db.container()
  assert_true(container.is_running())
  let result = container.exec([
    "sh", "-c", "mysql -h127.0.0.1 -u\"$MYSQL_USER\" -p\"$MYSQL_PASSWORD\" -N -e 'SELECT 42' \"$MYSQL_DATABASE\" 2>/dev/null",
  ])
  assert_eq(result.code, 0)
  assert_true(result.stdout.contains("42"))
  let dsn = db.dsn()
  assert_true(dsn.has_prefix("test:test@tcp(localhost:"))
  assert_true(dsn.has_suffix(")/test"))
  assert_true(db.connection_string().has_prefix("mysql://test:test@"))
}

///|
test "mysql config defaults" {
  let config = @mysql.MySqlConfig::new()
  assert_eq(config.image, "mysql:8.4")
  assert_eq(config.username, "test")
  assert_eq(config.password, "test")
  assert_eq(config.database, "test")
  assert_eq(config.port, 3306)
}
