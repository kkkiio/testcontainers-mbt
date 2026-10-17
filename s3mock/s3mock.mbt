// Adobe S3Mock: an in-process S3 API implementation for tests.
//
// Upstream reference: modules/s3mock in testcontainers-go.

///|
/// Container port serving the S3 HTTP API.
const S3MOCK_HTTP_PORT : Int32 = 9090

///|
/// Container port serving the S3 HTTPS API.
const S3MOCK_HTTPS_PORT : Int32 = 9191

///|
/// Configuration for the S3Mock module. All fields have sensible test
/// defaults; pass labeled arguments to `new` to change them.
pub(all) struct S3MockConfig {
  /// Docker image. Defaults to `adobe/s3mock:3.9.1`.
  image : String
  /// Buckets created on startup.
  initial_buckets : Array[String]
  /// Readiness timeout in milliseconds. S3Mock is a JVM application, so give it
  /// some time on a cold start.
  wait_timeout_ms : Int32
} derive(Debug, Eq)

///|
pub extend S3MockConfig with Eq::{equal, not_equal}

///|
pub extend S3MockConfig with Debug::{to_repr}

///|
/// Default configuration: `adobe/s3mock:3.9.1` without any pre-created
/// buckets. Override any field with a labeled argument, e.g.
/// `S3MockConfig::new(initial_buckets=["assets"])`.
pub fn S3MockConfig::new(
  image~ : String = "adobe/s3mock:3.9.1",
  initial_buckets~ : ArrayView[String] = [],
  wait_timeout_ms~ : Int32 = 60_000,
) -> S3MockConfig {
  { image, initial_buckets: initial_buckets.to_owned(), wait_timeout_ms, }
}

///|
/// A running S3Mock container.
pub struct S3MockContainer {
  container : @testcontainers.Container
  config : S3MockConfig
}

///|
/// Start S3Mock and wait until its HTTP API answers.
///
/// ```mbt nocheck
/// let s3 = @s3mock.run(initial_buckets=["assets"])
/// defer s3.cleanup()
/// let endpoint = s3.endpoint() // http://localhost:<random port>
/// ```
///
/// `reuse` forwards to `ContainerRequest::with_reuse`.
pub async fn run(
  image~ : String = "adobe/s3mock:3.9.1",
  initial_buckets~ : ArrayView[String] = [],
  wait_timeout_ms~ : Int32 = 60_000,
  reuse~ : Bool = false,
) -> S3MockContainer raise @testcontainers.TestContainerError {
  let config = S3MockConfig::new(image~, initial_buckets~, wait_timeout_ms~)
  let mut request = @testcontainers.ContainerRequest::new(config.image)
    .with_reuse(reuse~)
    .with_port(S3MOCK_HTTP_PORT)
    .with_port(S3MOCK_HTTPS_PORT)
  if config.initial_buckets.length() > 0 {
    let joined = config.initial_buckets.join(",")
    // 3.x / 4.x uses the `domain` prefix, 5.x+ the `store` prefix. Setting both
    // keeps the module working across image versions, like testcontainers-go.
    request = request
      .with_env("COM_ADOBE_TESTING_S3MOCK_DOMAIN_INITIAL_BUCKETS", joined)
      .with_env("COM_ADOBE_TESTING_S3MOCK_STORE_INITIAL_BUCKETS", joined)
  }
  // S3Mock answers /favicon.ico with 200 as soon as the API is up; this is the
  // readiness path used by testcontainers-go.
  let request = request
    .with_wait_for(
      @testcontainers.WaitStrategy::All([
        @testcontainers.WaitStrategy::TcpPort(S3MOCK_HTTP_PORT),
        @testcontainers.WaitStrategy::HttpGet(
          S3MOCK_HTTP_PORT,
          "/favicon.ico",
          200,
        ),
      ]),
    )
    .with_wait_timeout_ms(config.wait_timeout_ms)
  let container = request.start()
  { container, config, }
}

///|
/// The underlying generic container, for exec, logs and so on.
pub fn S3MockContainer::container(
  self : S3MockContainer,
) -> @testcontainers.Container {
  self.container
}

///|
/// HTTP endpoint of the S3 API, e.g. `http://localhost:32768`.
pub fn S3MockContainer::endpoint(
  self : S3MockContainer,
) -> String raise @testcontainers.TestContainerError {
  "http://" + self.container.endpoint(S3MOCK_HTTP_PORT)
}

///|
/// HTTPS endpoint of the S3 API. S3Mock uses a self-signed certificate, so
/// clients need to disable certificate verification.
pub fn S3MockContainer::https_endpoint(
  self : S3MockContainer,
) -> String raise @testcontainers.TestContainerError {
  "https://" + self.container.endpoint(S3MOCK_HTTPS_PORT)
}

///|
/// Buckets created on startup.
pub fn S3MockContainer::initial_buckets(
  self : S3MockContainer,
) -> Array[String] {
  self.config.initial_buckets.copy()
}

///|
/// Access key accepted by S3Mock. Any non-empty pair works; S3Mock does not
/// validate credentials.
pub fn S3MockContainer::access_key(_self : S3MockContainer) -> String {
  "foo"
}

///|
/// Secret key accepted by S3Mock.
pub fn S3MockContainer::secret_key(_self : S3MockContainer) -> String {
  "bar"
}

///|
/// Region to configure in the S3 client. S3Mock accepts any region.
pub fn S3MockContainer::region(_self : S3MockContainer) -> String {
  "us-east-1"
}

///|
/// Stop the container.
pub async fn S3MockContainer::stop(
  self : S3MockContainer,
) -> Unit raise @testcontainers.TestContainerError {
  self.container.stop()
}

///|
/// Force-remove the container. Never raises, safe for `defer`.
pub async fn S3MockContainer::cleanup(self : S3MockContainer) -> Unit {
  self.container.cleanup()
}
