//! HTTP playground API.
//!
//! Every command submitted here is classified by the same playground policy
//! that guards the public RESP port, so neither entry point can administer the
//! shared Ferrite instance.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{header, StatusCode};
use axum::response::{Html, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{sleep, Sleep};

use crate::resp::{self, RespValue};
use crate::{command, keys, policy};

pub const HTTP_ADDR: &str = "0.0.0.0:8080";
pub const MAX_BODY_BYTES: usize = 64 * 1024;
pub const MAX_RESPONSE_BODY_BYTES: usize = 64 * 1024;
pub const MAX_HTTP_CONNECTIONS: usize = 32;
pub const HTTP_CONNECTION_LIFETIME: Duration = Duration::from_secs(30);

pub struct LimitedListener {
    listener: TcpListener,
    permits: Arc<Semaphore>,
    connection_lifetime: Duration,
}

impl LimitedListener {
    pub fn new(listener: TcpListener) -> Self {
        Self::with_limits(listener, MAX_HTTP_CONNECTIONS, HTTP_CONNECTION_LIFETIME)
    }

    fn with_limits(listener: TcpListener, max_connections: usize, lifetime: Duration) -> Self {
        Self {
            listener,
            permits: Arc::new(Semaphore::new(max_connections)),
            connection_lifetime: lifetime,
        }
    }
}

pub struct LimitedIo {
    stream: TcpStream,
    _permit: OwnedSemaphorePermit,
    deadline: Pin<Box<Sleep>>,
}

impl LimitedIo {
    fn poll_expired(&mut self, cx: &mut Context<'_>) -> io::Result<()> {
        if self.deadline.as_mut().poll(cx).is_ready() {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "HTTP connection lifetime exceeded",
            ))
        } else {
            Ok(())
        }
    }
}

impl AsyncRead for LimitedIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if let Err(error) = self.poll_expired(cx) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut self.stream).poll_read(cx, buffer)
    }
}

impl AsyncWrite for LimitedIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        if let Err(error) = self.poll_expired(cx) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut self.stream).poll_write(cx, buffer)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        if let Err(error) = self.poll_expired(cx) {
            return Poll::Ready(Err(error));
        }
        Pin::new(&mut self.stream).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

impl axum::serve::Listener for LimitedListener {
    type Io = LimitedIo;
    type Addr = std::net::SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        let permit = Arc::clone(&self.permits)
            .acquire_owned()
            .await
            .expect("HTTP connection semaphore is never closed");
        loop {
            match self.listener.accept().await {
                Ok((stream, address)) => {
                    let _ = stream.set_nodelay(true);
                    return (
                        LimitedIo {
                            stream,
                            _permit: permit,
                            deadline: Box::pin(sleep(self.connection_lifetime)),
                        },
                        address,
                    );
                }
                Err(error) => {
                    eprintln!("warning: HTTP playground accept failed: {error}");
                    sleep(Duration::from_millis(100)).await;
                }
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.listener.local_addr()
    }
}

#[derive(Clone)]
pub struct AppState {
    pub resp_addr: String,
    pub version: String,
    pub backend_permits: Arc<Semaphore>,
}

#[derive(Debug, Deserialize)]
pub struct ExecuteRequest {
    command: String,
}

#[derive(Debug, Serialize)]
pub struct ApiResponse {
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl ApiResponse {
    fn ok(data: Value) -> Self {
        Self {
            success: true,
            data: Some(data),
            error: None,
        }
    }

    fn error(error: impl Into<String>) -> Self {
        Self {
            success: false,
            data: None,
            error: Some(error.into()),
        }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/api/health", get(health))
        .route("/api/execute", post(execute))
        .route("/api/command", post(execute))
        .route("/api/keys/detail/{key}", get(key_detail))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .with_state(state)
}

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

async fn health(State(state): State<AppState>) -> Response {
    // Health uses the same backend-operation pool as user traffic, but it
    // never waits for a permit. Returning 429 under saturation avoids a probe
    // deadlock and lets the orchestrator distinguish overload from a dead
    // Ferrite child.
    let _permit = match try_backend_permit(&state) {
        Some(permit) => permit,
        None => return backend_busy_response(),
    };

    match resp::execute(&state.resp_addr, &["PING".to_string()]).await {
        Ok(RespValue::Simple(reply)) if reply == "PONG" => api_response(
            StatusCode::OK,
            ApiResponse::ok(json!({
                "status": "ok",
                "version": state.version,
                "resp": reply
            })),
        ),
        Ok(reply) => api_response(
            StatusCode::BAD_GATEWAY,
            ApiResponse::error(format!(
                "Ferrite PING returned unexpected response: {reply:?}"
            )),
        ),
        Err(error) => api_response(
            StatusCode::SERVICE_UNAVAILABLE,
            ApiResponse::error(format!("Ferrite RESP health check failed: {error}")),
        ),
    }
}

async fn execute(State(state): State<AppState>, Json(request): Json<ExecuteRequest>) -> Response {
    let arguments = match command::parse(&request.command) {
        Ok(arguments) => arguments,
        Err(error) => return api_response(StatusCode::BAD_REQUEST, ApiResponse::error(error)),
    };

    let decision = policy::classify_arguments(&arguments);
    if !decision.is_allowed() {
        return api_response(
            StatusCode::FORBIDDEN,
            ApiResponse::error(decision.message()),
        );
    }

    let _permit = match try_backend_permit(&state) {
        Some(permit) => permit,
        None => return backend_busy_response(),
    };

    match resp::execute(&state.resp_addr, &arguments).await {
        Ok(value) => match resp::to_json(value) {
            Ok(value) => api_response(StatusCode::OK, ApiResponse::ok(value)),
            Err(error) => api_response(StatusCode::UNPROCESSABLE_ENTITY, ApiResponse::error(error)),
        },
        Err(error) => api_response(
            StatusCode::BAD_GATEWAY,
            ApiResponse::error(format!("Ferrite command failed: {error}")),
        ),
    }
}

async fn key_detail(State(state): State<AppState>, Path(key): Path<String>) -> Response {
    if key.is_empty() {
        return api_response(
            StatusCode::BAD_REQUEST,
            ApiResponse::error("key must not be empty"),
        );
    }

    let _permit = match try_backend_permit(&state) {
        Some(permit) => permit,
        None => return backend_busy_response(),
    };

    match keys::detail(&state.resp_addr, &key).await {
        Ok(Some(detail)) => api_response(StatusCode::OK, ApiResponse::ok(detail)),
        Ok(None) => api_response(StatusCode::NOT_FOUND, ApiResponse::error("Key not found")),
        Err(error) => api_response(
            StatusCode::BAD_GATEWAY,
            ApiResponse::error(format!("Failed to read key from Ferrite: {error}")),
        ),
    }
}

fn api_response(status: StatusCode, body: ApiResponse) -> Response {
    let mut status = status;
    let mut encoded = serde_json::to_vec(&body).unwrap_or_else(|_| {
        br#"{"success":false,"error":"failed to serialize API response"}"#.to_vec()
    });
    if encoded.len() > MAX_RESPONSE_BODY_BYTES {
        status = StatusCode::PAYLOAD_TOO_LARGE;
        encoded =
            br#"{"success":false,"error":"response exceeds the playground output limit"}"#.to_vec();
    }
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(encoded))
        .expect("static API response headers are valid")
}

fn try_backend_permit(state: &AppState) -> Option<OwnedSemaphorePermit> {
    Arc::clone(&state.backend_permits).try_acquire_owned().ok()
}

fn backend_busy_response() -> Response {
    api_response(
        StatusCode::TOO_MANY_REQUESTS,
        ApiResponse::error(
            "Ferrite playground backend is busy; retry after an in-flight operation completes",
        ),
    )
}

pub const INDEX_HTML: &str = r##"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ferrite Playground</title>
  <style>
    :root { color-scheme: dark; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    body { max-width: 860px; margin: 0 auto; padding: 3rem 1.25rem; background: #111827; color: #e5e7eb; }
    h1 { color: #f97316; }
    form { display: flex; gap: .75rem; }
    input { flex: 1; padding: .85rem; border: 1px solid #4b5563; border-radius: .5rem; background: #1f2937; color: inherit; }
    button { padding: .85rem 1.25rem; border: 0; border-radius: .5rem; background: #f97316; color: #111827; font-weight: 700; cursor: pointer; }
    pre { min-height: 10rem; padding: 1rem; overflow: auto; border-radius: .5rem; background: #030712; white-space: pre-wrap; }
    .status { margin-bottom: 1rem; color: #9ca3af; }
    .note { margin-top: 1rem; color: #9ca3af; font-size: .85rem; }
  </style>
</head>
<body>
  <h1>Ferrite Playground</h1>
  <p class="status" id="status">Connecting to Ferrite…</p>
  <form id="command-form">
    <input id="command" name="command" value="PING" autocomplete="off" aria-label="RESP command">
    <button type="submit">Execute</button>
  </form>
  <pre id="output" aria-live="polite">Enter a Redis-compatible command.</pre>
  <p class="note">
    This is a shared, unauthenticated playground: administrative and lifecycle
    commands (for example SHUTDOWN, CONFIG, DEBUG, MODULE, ACL, SAVE, BGSAVE,
    BGREWRITEAOF, REPLICAOF) are rejected on both the HTTP API and the public
    Redis-compatible port.
  </p>
  <script>
    const status = document.querySelector("#status");
    const form = document.querySelector("#command-form");
    const command = document.querySelector("#command");
    const output = document.querySelector("#output");

    fetch("/api/health")
      .then(response => response.json())
      .then(body => {
        status.textContent = body.success
          ? `Ferrite ${body.data.version} — ${body.data.status}`
          : body.error;
      })
      .catch(error => { status.textContent = `Unavailable: ${error}`; });

    form.addEventListener("submit", async event => {
      event.preventDefault();
      output.textContent = "Executing…";
      try {
        const response = await fetch("/api/execute", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ command: command.value })
        });
        const body = await response.json();
        output.textContent = body.success
          ? JSON.stringify(body.data, null, 2)
          : `Error: ${body.error}`;
      } catch (error) {
        output.textContent = `Request failed: ${error}`;
      }
    });
  </script>
</body>
</html>
"##;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::MockFerrite;
    use axum::body::{to_bytes, Body};
    use axum::http::Request;
    use axum::serve::Listener;
    use tokio::io::AsyncWriteExt;
    use tokio::sync::Semaphore;
    use tokio::time::timeout;
    use tower::ServiceExt;

    async fn call(state: AppState, request: Request<Body>) -> (StatusCode, Value) {
        let response = router(state).oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (status, serde_json::from_slice(&bytes).unwrap())
    }

    fn execute_request(command: &str) -> Request<Body> {
        Request::builder()
            .method("POST")
            .uri("/api/execute")
            .header("content-type", "application/json")
            .body(Body::from(json!({ "command": command }).to_string()))
            .unwrap()
    }

    fn state(upstream: &MockFerrite, version: &str) -> AppState {
        AppState {
            resp_addr: upstream.addr(),
            version: version.into(),
            backend_permits: Arc::new(Semaphore::new(4)),
        }
    }

    #[tokio::test]
    async fn rejects_non_allowlisted_and_unbounded_commands_over_http() {
        let upstream = MockFerrite::start().await;
        let state = state(&upstream, "test");

        for command in [
            "SHUTDOWN",
            "PLUGIN LIST",
            "AUDIT START",
            "MIGRATE.START redis://example.invalid",
            "migrate start redis://example.invalid",
            "LRANGE list 0 -1",
            "XRANGE stream - +",
            "COPY source destination DB 16",
            "XTRIM stream MAXLEN =",
            "XTRIM stream MAXLEN 100 LIMIT 10",
            "XADD stream MAXLEN = 100 LIMIT 10 * field value",
            "XADD stream 18446744073709551615-18446744073709551615 field value",
            "SETBIT bitmap 4294967288 1",
            "SCAN 0 COUNT 100",
            "SSCAN set 0 COUNT 100",
            "HSCAN hash 0 COUNT 100",
            "ZSCAN zset 0 COUNT 100",
            "XREAD COUNT 10 STREAMS stream 0-0",
            "XREAD STREAMS COUNT 10 stream 0-0",
            "XREADGROUP GROUP group consumer COUNT 10 STREAMS stream >",
        ] {
            let (status, body) = call(state.clone(), execute_request(command)).await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{command} must be forbidden");
            assert_eq!(body["success"], json!(false));
            assert!(body["error"].as_str().unwrap().contains("playground"));
        }

        assert_eq!(upstream.received_commands().await, Vec::<String>::new());
        assert!(!upstream.was_shutdown().await);
    }

    #[tokio::test]
    async fn executes_ordinary_commands_over_http() {
        let upstream = MockFerrite::start().await;
        upstream
            .seed_list(
                "list",
                (0..150).map(|index| format!("item-{index}")).collect(),
            )
            .await;
        upstream
            .seed_stream(
                "stream",
                (0..150)
                    .map(|index| {
                        (
                            format!("{index}-0"),
                            vec!["field".to_string(), format!("value-{index}")],
                        )
                    })
                    .collect(),
            )
            .await;
        let state = state(&upstream, "test");

        let (status, body) = call(state.clone(), execute_request("PING")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"], json!("PONG"));

        let (status, body) = call(state.clone(), execute_request("ECHO hello")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"], json!("hello"));

        let (status, body) = call(state.clone(), execute_request("SET http-key http-value")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"], json!("OK"));

        let (status, body) = call(state.clone(), execute_request("GET http-key")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"], json!("http-value"));

        let (status, body) = call(state.clone(), execute_request("LRANGE list 0 99")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"].as_array().unwrap().len(), 100);

        let (status, body) = call(state, execute_request("XRANGE stream - + COUNT 100")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"].as_array().unwrap().len(), 100);
        assert_eq!(
            upstream.received_commands().await,
            vec!["PING", "ECHO", "SET", "GET", "LRANGE", "XRANGE"]
        );
    }

    #[tokio::test]
    async fn hash_key_detail_omits_values_without_scanning() {
        let upstream = MockFerrite::start().await;
        let values: Vec<(String, String)> = (0..150)
            .map(|index| (format!("field-{index:03}"), format!("value-{index}")))
            .collect();
        upstream.seed_hash("big-hash", values).await;
        let state = state(&upstream, "test");

        let request = Request::builder()
            .uri("/api/keys/detail/big-hash")
            .body(Body::empty())
            .unwrap();
        let (status, body) = call(state.clone(), request).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"]["length"], json!(150));
        assert_eq!(body["data"]["returned"], json!(0));
        assert_eq!(body["data"]["truncated"], json!(true));
        assert_eq!(body["data"]["value"], json!(null));
        assert_eq!(body["data"]["value_omitted"], json!(true));
        assert!(body["data"]["detail"].as_str().unwrap().contains("HSCAN"));
        assert_eq!(
            upstream.received_commands().await,
            vec!["TYPE", "TTL", "HLEN"]
        );
    }

    #[tokio::test]
    async fn missing_keys_return_not_found() {
        let upstream = MockFerrite::start().await;
        let state = state(&upstream, "test");
        let request = Request::builder()
            .uri("/api/keys/detail/absent")
            .body(Body::empty())
            .unwrap();
        let (status, body) = call(state, request).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body["success"], json!(false));
    }

    #[tokio::test]
    async fn reports_health_from_the_real_resp_server() {
        let upstream = MockFerrite::start().await;
        let state = state(&upstream, "9.9.9");
        let request = Request::builder()
            .uri("/api/health")
            .body(Body::empty())
            .unwrap();
        let (status, body) = call(state, request).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"]["resp"], json!("PONG"));
        assert_eq!(body["data"]["version"], json!("9.9.9"));
    }

    #[tokio::test]
    async fn all_http_backend_paths_fail_fast_when_the_shared_pool_is_saturated() {
        let upstream = MockFerrite::start().await;
        upstream.seed_string("key", "value").await;
        let permits = Arc::new(Semaphore::new(1));
        let held = Arc::clone(&permits).acquire_owned().await.unwrap();
        let state = AppState {
            resp_addr: upstream.addr(),
            version: "test".into(),
            backend_permits: permits,
        };

        let requests = [
            execute_request("PING"),
            Request::builder()
                .uri("/api/keys/detail/key")
                .body(Body::empty())
                .unwrap(),
            Request::builder()
                .uri("/api/health")
                .body(Body::empty())
                .unwrap(),
        ];
        for request in requests {
            let (status, body) = call(state.clone(), request).await;
            assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
            assert_eq!(body["success"], json!(false));
            assert!(body["error"].as_str().unwrap().contains("busy"));
        }
        assert!(upstream.received_commands().await.is_empty());

        drop(held);
        let request = Request::builder()
            .uri("/api/health")
            .body(Body::empty())
            .unwrap();
        let (status, body) = call(state, request).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"]["resp"], json!("PONG"));
    }

    #[tokio::test]
    async fn oversized_http_results_are_replaced_with_a_bounded_error_body() {
        let upstream = MockFerrite::start().await;
        upstream
            .seed_string("large", &"x".repeat(MAX_RESPONSE_BODY_BYTES + 1))
            .await;
        let state = state(&upstream, "test");

        let response = router(state)
            .oneshot(execute_request("GET large"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        let bytes = to_bytes(response.into_body(), MAX_RESPONSE_BODY_BYTES)
            .await
            .unwrap();
        assert!(bytes.len() <= MAX_RESPONSE_BODY_BYTES);
    }

    #[tokio::test]
    async fn accepted_http_connections_are_limited_for_their_full_lifetime() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let listener = LimitedListener::with_limits(listener, 1, Duration::from_secs(1));
        let first_accept = tokio::spawn(async move {
            let mut listener = listener;
            let accepted = listener.accept().await;
            (listener, accepted)
        });
        let first_client = TcpStream::connect(address).await.unwrap();
        let (mut listener, (first_io, _)) = first_accept.await.unwrap();

        let mut second_accept = tokio::spawn(async move {
            let accepted = listener.accept().await;
            (listener, accepted)
        });
        let _queued_client = TcpStream::connect(address).await.unwrap();
        assert!(timeout(Duration::from_millis(50), &mut second_accept)
            .await
            .is_err());

        drop(first_io);
        let (_listener, (_second_io, _)) = timeout(Duration::from_secs(1), second_accept)
            .await
            .expect("queued connection should be accepted after the lifetime permit is released")
            .unwrap();
        drop(first_client);
    }

    #[tokio::test]
    async fn http_connection_deadline_closes_slow_connections() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut listener = LimitedListener::with_limits(listener, 1, Duration::from_millis(30));
        let accepted = tokio::spawn(async move { listener.accept().await });
        let client = TcpStream::connect(address).await.unwrap();
        let (mut server, _) = accepted.await.unwrap();

        sleep(Duration::from_millis(50)).await;
        let error = server
            .write_all(b"HTTP/1.1 200 OK\r\n\r\n")
            .await
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);

        drop(server);
        drop(client);
    }
}
