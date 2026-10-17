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
  assert_eq(result.stdout.trim().to_owned(), "42")
  assert_eq(db.dsn(), "test:test@tcp(localhost:\{db.port()})/test")
  assert_eq(
    db.connection_string(),
    "mysql://test:test@localhost:\{db.port()}/test",
  )
}

///|
test "mysql config defaults" {
  debug_inspect(
    @mysql.MySqlConfig::new(),
    content=(
      #|{
      #|  image: "mysql:8.4",
      #|  database: "test",
      #|  username: "test",
      #|  password: "test",
      #|  root_password: "test",
      #|  port: 3306,
      #|  wait_timeout_ms: 90000,
      #|}
    ),
  )
}
