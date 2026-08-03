//! HTTP playground API.
//!
//! Every command submitted here is classified by the same playground policy
//! that guards the public RESP port, so neither entry point can administer the
//! shared Ferrite instance.

use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::resp::{self, RespValue};
use crate::{command, keys, policy};

pub const HTTP_ADDR: &str = "0.0.0.0:8080";
pub const MAX_BODY_BYTES: usize = 64 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub resp_addr: String,
    pub version: String,
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
    (status, Json(body)).into_response()
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

    #[tokio::test]
    async fn rejects_administrative_commands_over_http() {
        let upstream = MockFerrite::start().await;
        let state = AppState {
            resp_addr: upstream.addr(),
            version: "test".into(),
        };

        for command in [
            "SHUTDOWN",
            "shutdown nosave",
            "DEBUG SLEEP 0",
            "MODULE LIST",
            "ACL WHOAMI",
            "CONFIG SET appendonly yes",
            "SAVE",
            "BGSAVE",
            "BGREWRITEAOF",
            "REPLICAOF 127.0.0.1 1",
            "SLAVEOF 127.0.0.1 1",
            "FLUSHALL",
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
        let state = AppState {
            resp_addr: upstream.addr(),
            version: "test".into(),
        };

        let (status, body) = call(state.clone(), execute_request("SET http-key http-value")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"], json!("OK"));

        let (status, body) = call(state.clone(), execute_request("GET http-key")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"], json!("http-value"));
        assert_eq!(upstream.received_commands().await, vec!["SET", "GET"]);
    }

    #[tokio::test]
    async fn reports_health_from_the_real_resp_server() {
        let upstream = MockFerrite::start().await;
        let state = AppState {
            resp_addr: upstream.addr(),
            version: "9.9.9".into(),
        };
        let request = Request::builder()
            .uri("/api/health")
            .body(Body::empty())
            .unwrap();
        let (status, body) = call(state, request).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"]["resp"], json!("PONG"));
        assert_eq!(body["data"]["version"], json!("9.9.9"));
    }
}
