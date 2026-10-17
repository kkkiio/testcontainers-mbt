///|
async test "s3mock serves the S3 API" {
  let s3 = @s3mock.run(
    config=@s3mock.S3MockConfig::new().with_initial_buckets(["test-bucket"]),
  )
  defer s3.cleanup()
  let url = s3.endpoint()
  assert_true(url.has_prefix("http://localhost:"))
  assert_true(s3.https_endpoint().has_prefix("https://"))
  assert_eq(s3.initial_buckets(), ["test-bucket"])
  // ListBuckets is XML and includes the bucket created on startup.
  let (list_response, list_body) = @http.get(url + "/")
  assert_eq(list_response.code, 200)
  assert_true(list_body.text().contains("test-bucket"))
  // Round-trip an object through the S3 API.
  let (put_response, _) = @http.put(url + "/test-bucket/hello.txt", "hello s3")
  assert_eq(put_response.code, 200)
  let (get_response, get_body) = @http.get(url + "/test-bucket/hello.txt")
  assert_eq(get_response.code, 200)
  assert_eq(get_body.text(), "hello s3")
}

///|
test "s3mock config defaults" {
  let config = @s3mock.S3MockConfig::new()
  assert_eq(config.image, "adobe/s3mock:3.9.1")
  assert_eq(config.initial_buckets, [])
}
