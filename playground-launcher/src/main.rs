use std::future::Future;
use std::pin::Pin;
use std::process::{ExitCode, ExitStatus};
use std::time::Duration;

use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, Command};
use tokio::sync::oneshot;
use tokio::time::{sleep, timeout, Instant};

const FERRITE_BIN: &str = "/usr/local/bin/ferrite";
const RESP_ADDR: &str = "127.0.0.1:6379";
const HTTP_ADDR: &str = "0.0.0.0:8080";
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
const HTTP_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const RESP_TIMEOUT: Duration = Duration::from_secs(5);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_COMMAND_LENGTH: usize = 16 * 1024;
const MAX_ARGUMENTS: usize = 256;
const MAX_RESP_BULK_LENGTH: usize = 16 * 1024 * 1024;
const MAX_RESP_ARRAY_LENGTH: usize = 1_000_000;
const MAX_RESP_DEPTH: usize = 64;

#[derive(Clone)]
struct AppState {
    resp_addr: &'static str,
    version: String,
}

#[derive(Debug, Deserialize)]
struct ExecuteRequest {
    command: String,
}

#[derive(Debug, Serialize)]
struct ApiResponse {
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

#[derive(Debug, PartialEq)]
enum RespValue {
    Simple(String),
    Error(String),
    Integer(i64),
    Bulk(Option<Vec<u8>>),
    Array(Option<Vec<RespValue>>),
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("playground launcher error: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let mut ferrite = spawn_ferrite()?;
    if let Err(error) = wait_for_resp(&mut ferrite).await {
        stop_child(&mut ferrite).await;
        return Err(error);
    }

    let listener = match TcpListener::bind(HTTP_ADDR).await {
        Ok(listener) => listener,
        Err(error) => {
            stop_child(&mut ferrite).await;
            return Err(format!(
                "failed to bind HTTP playground to {HTTP_ADDR}: {error}"
            ));
        }
    };

    let state = AppState {
        resp_addr: RESP_ADDR,
        version: std::env::var("FERRITE_VERSION").unwrap_or_else(|_| "unknown".to_string()),
    };
    let app = Router::new()
        .route("/", get(index))
        .route("/api/health", get(health))
        .route("/api/execute", post(execute))
        .route("/api/command", post(execute))
        .route("/api/keys/detail/{key}", get(key_detail))
        .layer(DefaultBodyLimit::max(64 * 1024))
        .with_state(state);

    let (http_shutdown_tx, http_shutdown_rx) = oneshot::channel::<()>();
    let mut http_server = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = http_shutdown_rx.await;
            })
            .await
            .map_err(|error| format!("HTTP playground server failed: {error}"))
    });

    eprintln!("Ferrite Playground ready: HTTP {HTTP_ADDR}, RESP 0.0.0.0:6379");

    tokio::select! {
        status = ferrite.wait() => {
            let _ = http_shutdown_tx.send(());
            wait_for_http_server(&mut http_server).await?;
            let status = status
                .map_err(|error| format!("failed to wait for Ferrite RESP server: {error}"))?;
            validate_child_status(status)
        }
        signal = shutdown_signal() => {
            signal?;
            let _ = http_shutdown_tx.send(());
            stop_child(&mut ferrite).await;
            wait_for_http_server(&mut http_server).await
        }
        result = &mut http_server => {
            stop_child(&mut ferrite).await;
            match result {
                Ok(Ok(())) => Err("HTTP playground server exited unexpectedly".to_string()),
                Ok(Err(error)) => Err(error),
                Err(error) => Err(format!("HTTP playground task failed: {error}")),
            }
        }
    }
}

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

async fn health(State(state): State<AppState>) -> Response {
    match execute_resp(state.resp_addr, &["PING".to_string()]).await {
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
    let arguments = match parse_command(&request.command) {
        Ok(arguments) => arguments,
        Err(error) => return api_response(StatusCode::BAD_REQUEST, ApiResponse::error(error)),
    };

    match execute_resp(state.resp_addr, &arguments).await {
        Ok(value) => match resp_to_json(value) {
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

    match fetch_key_detail(state.resp_addr, &key).await {
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

async fn fetch_key_detail(addr: &str, key: &str) -> Result<Option<Value>, String> {
    let key_arg = key.to_string();
    let key_type = resp_as_string(
        execute_resp(addr, &["TYPE".to_string(), key_arg.clone()]).await?,
        "TYPE",
    )?;
    if key_type == "none" {
        return Ok(None);
    }

    let ttl = resp_as_integer(
        execute_resp(addr, &["TTL".to_string(), key_arg.clone()]).await?,
        "TTL",
    )?;

    let (value_command, length_command): (Vec<String>, Option<Vec<String>>) =
        match key_type.as_str() {
            "string" => (
                vec!["GET".to_string(), key_arg.clone()],
                Some(vec!["STRLEN".to_string(), key_arg.clone()]),
            ),
            "list" => (
                vec![
                    "LRANGE".to_string(),
                    key_arg.clone(),
                    "0".to_string(),
                    "-1".to_string(),
                ],
                Some(vec!["LLEN".to_string(), key_arg.clone()]),
            ),
            "set" => (
                vec!["SMEMBERS".to_string(), key_arg.clone()],
                Some(vec!["SCARD".to_string(), key_arg.clone()]),
            ),
            "hash" => (
                vec!["HGETALL".to_string(), key_arg.clone()],
                Some(vec!["HLEN".to_string(), key_arg.clone()]),
            ),
            "zset" => (
                vec![
                    "ZRANGE".to_string(),
                    key_arg.clone(),
                    "0".to_string(),
                    "-1".to_string(),
                    "WITHSCORES".to_string(),
                ],
                Some(vec!["ZCARD".to_string(), key_arg.clone()]),
            ),
            "stream" => (
                vec![
                    "XRANGE".to_string(),
                    key_arg.clone(),
                    "-".to_string(),
                    "+".to_string(),
                    "COUNT".to_string(),
                    "100".to_string(),
                ],
                Some(vec!["XLEN".to_string(), key_arg.clone()]),
            ),
            _ => {
                return Err(format!(
                    "unsupported RESP key type returned by Ferrite: {key_type}"
                ));
            }
        };

    let value = resp_to_json(execute_resp(addr, &value_command).await?)?;
    let length = match length_command {
        Some(command) => Some(resp_as_integer(
            execute_resp(addr, &command).await?,
            "length",
        )?),
        None => None,
    };

    Ok(Some(json!({
        "key": key,
        "key_type": key_type,
        "ttl": ttl,
        "length": length,
        "value": value
    })))
}

fn spawn_ferrite() -> Result<Child, String> {
    Command::new(FERRITE_BIN)
        .args([
            "--bind",
            "0.0.0.0",
            "--port",
            "6379",
            "--data-dir",
            "/var/lib/ferrite/data",
        ])
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("failed to start {FERRITE_BIN}: {error}"))
}

async fn wait_for_resp(child: &mut Child) -> Result<(), String> {
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("failed to inspect Ferrite child: {error}"))?
        {
            return Err(format!(
                "Ferrite RESP server exited during startup with {status}"
            ));
        }

        if matches!(
            execute_resp(RESP_ADDR, &["PING".to_string()]).await,
            Ok(RespValue::Simple(reply)) if reply == "PONG"
        ) {
            return Ok(());
        }

        if Instant::now() >= deadline {
            return Err(format!(
                "Ferrite RESP server did not become ready at {RESP_ADDR} within {} seconds",
                STARTUP_TIMEOUT.as_secs()
            ));
        }
        sleep(Duration::from_millis(100)).await;
    }
}

fn validate_child_status(status: ExitStatus) -> Result<(), String> {
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "Ferrite RESP server exited unexpectedly with {status}"
        ))
    }
}

async fn wait_for_http_server(
    server: &mut tokio::task::JoinHandle<Result<(), String>>,
) -> Result<(), String> {
    match timeout(HTTP_SHUTDOWN_TIMEOUT, &mut *server).await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => Err(format!("HTTP playground task failed: {error}")),
        Err(_) => {
            server.abort();
            Err("timed out waiting for HTTP playground shutdown".to_string())
        }
    }
}

async fn stop_child(child: &mut Child) {
    if let Err(error) = stop_child_with_timeout(child, SHUTDOWN_TIMEOUT).await {
        eprintln!("warning: {error}");
    }
}

async fn stop_child_with_timeout(child: &mut Child, grace: Duration) -> Result<ExitStatus, String> {
    if let Some(status) = child
        .try_wait()
        .map_err(|error| format!("failed to inspect Ferrite child before shutdown: {error}"))?
    {
        return Ok(status);
    }

    let pid = child
        .id()
        .ok_or_else(|| "Ferrite child has no process ID".to_string())?;
    kill(Pid::from_raw(pid as i32), Signal::SIGTERM)
        .map_err(|error| format!("failed to send SIGTERM to Ferrite child {pid}: {error}"))?;

    match timeout(grace, child.wait()).await {
        Ok(result) => result.map_err(|error| format!("failed to wait for Ferrite child: {error}")),
        Err(_) => {
            eprintln!(
                "warning: Ferrite child {pid} did not exit within {} seconds; escalating to SIGKILL",
                grace.as_secs_f64()
            );
            child
                .start_kill()
                .map_err(|error| format!("failed to SIGKILL Ferrite child {pid}: {error}"))?;
            child
                .wait()
                .await
                .map_err(|error| format!("failed to reap Ferrite child {pid}: {error}"))
        }
    }
}

async fn execute_resp(addr: &str, arguments: &[String]) -> Result<RespValue, String> {
    if arguments.is_empty() {
        return Err("command must contain at least one argument".to_string());
    }
    if arguments.len() > MAX_ARGUMENTS {
        return Err(format!(
            "command has too many arguments (maximum {MAX_ARGUMENTS})"
        ));
    }

    timeout(RESP_TIMEOUT, async {
        let mut stream = TcpStream::connect(addr)
            .await
            .map_err(|error| format!("could not connect to {addr}: {error}"))?;
        let request = encode_resp_command(arguments);
        stream
            .write_all(&request)
            .await
            .map_err(|error| format!("failed to write RESP command: {error}"))?;
        stream
            .flush()
            .await
            .map_err(|error| format!("failed to flush RESP command: {error}"))?;

        let mut reader = BufReader::new(stream);
        read_resp(&mut reader, 0).await
    })
    .await
    .map_err(|_| {
        format!(
            "RESP operation timed out after {} seconds",
            RESP_TIMEOUT.as_secs()
        )
    })?
}

fn encode_resp_command(arguments: &[String]) -> Vec<u8> {
    let mut encoded = format!("*{}\r\n", arguments.len()).into_bytes();
    for argument in arguments {
        encoded.extend_from_slice(format!("${}\r\n", argument.len()).as_bytes());
        encoded.extend_from_slice(argument.as_bytes());
        encoded.extend_from_slice(b"\r\n");
    }
    encoded
}

fn read_resp<'a, R>(
    reader: &'a mut R,
    depth: usize,
) -> Pin<Box<dyn Future<Output = Result<RespValue, String>> + Send + 'a>>
where
    R: AsyncBufRead + Unpin + Send + 'a,
{
    Box::pin(async move {
        if depth > MAX_RESP_DEPTH {
            return Err("RESP response nesting is too deep".to_string());
        }

        let mut line = Vec::new();
        let read = reader
            .read_until(b'\n', &mut line)
            .await
            .map_err(|error| format!("failed to read RESP response: {error}"))?;
        if read == 0 {
            return Err("Ferrite closed the connection without a response".to_string());
        }
        if !line.ends_with(b"\r\n") {
            return Err("RESP response line did not end with CRLF".to_string());
        }
        line.truncate(line.len() - 2);
        let (&prefix, payload) = line
            .split_first()
            .ok_or_else(|| "received an empty RESP response line".to_string())?;

        match prefix {
            b'+' => Ok(RespValue::Simple(
                String::from_utf8(payload.to_vec())
                    .map_err(|_| "RESP simple string was not valid UTF-8".to_string())?,
            )),
            b'-' => Ok(RespValue::Error(
                String::from_utf8_lossy(payload).into_owned(),
            )),
            b':' => Ok(RespValue::Integer(parse_resp_number(payload, "integer")?)),
            b'$' => {
                let length = parse_resp_number(payload, "bulk length")?;
                if length == -1 {
                    return Ok(RespValue::Bulk(None));
                }
                if length < -1 || length as usize > MAX_RESP_BULK_LENGTH {
                    return Err(format!("invalid RESP bulk length: {length}"));
                }

                let mut data = vec![0; length as usize + 2];
                reader
                    .read_exact(&mut data)
                    .await
                    .map_err(|error| format!("failed to read RESP bulk data: {error}"))?;
                if !data.ends_with(b"\r\n") {
                    return Err("RESP bulk data did not end with CRLF".to_string());
                }
                data.truncate(length as usize);
                Ok(RespValue::Bulk(Some(data)))
            }
            b'*' => {
                let length = parse_resp_number(payload, "array length")?;
                if length == -1 {
                    return Ok(RespValue::Array(None));
                }
                if length < -1 || length as usize > MAX_RESP_ARRAY_LENGTH {
                    return Err(format!("invalid RESP array length: {length}"));
                }

                let mut values = Vec::with_capacity(length as usize);
                for _ in 0..length {
                    values.push(read_resp(reader, depth + 1).await?);
                }
                Ok(RespValue::Array(Some(values)))
            }
            _ => Err(format!("unsupported RESP response prefix: {prefix:#x}")),
        }
    })
}

fn parse_resp_number(payload: &[u8], field: &str) -> Result<i64, String> {
    std::str::from_utf8(payload)
        .map_err(|_| format!("RESP {field} was not valid UTF-8"))?
        .parse::<i64>()
        .map_err(|error| format!("invalid RESP {field}: {error}"))
}

fn resp_to_json(value: RespValue) -> Result<Value, String> {
    match value {
        RespValue::Simple(value) => Ok(Value::String(value)),
        RespValue::Error(error) => Err(error),
        RespValue::Integer(value) => Ok(json!(value)),
        RespValue::Bulk(None) | RespValue::Array(None) => Ok(Value::Null),
        RespValue::Bulk(Some(value)) => match String::from_utf8(value) {
            Ok(value) => Ok(Value::String(value)),
            Err(error) => Ok(Value::Array(
                error
                    .into_bytes()
                    .into_iter()
                    .map(|byte| json!(byte))
                    .collect(),
            )),
        },
        RespValue::Array(Some(values)) => values
            .into_iter()
            .map(resp_to_json)
            .collect::<Result<Vec<_>, _>>()
            .map(Value::Array),
    }
}

fn resp_as_string(value: RespValue, command: &str) -> Result<String, String> {
    match value {
        RespValue::Simple(value) => Ok(value),
        RespValue::Bulk(Some(value)) => {
            String::from_utf8(value).map_err(|_| format!("{command} returned a non-UTF-8 string"))
        }
        RespValue::Error(error) => Err(error),
        other => Err(format!("{command} returned unexpected response: {other:?}")),
    }
}

fn resp_as_integer(value: RespValue, command: &str) -> Result<i64, String> {
    match value {
        RespValue::Integer(value) => Ok(value),
        RespValue::Error(error) => Err(error),
        other => Err(format!("{command} returned unexpected response: {other:?}")),
    }
}

fn parse_command(command: &str) -> Result<Vec<String>, String> {
    if command.len() > MAX_COMMAND_LENGTH {
        return Err(format!(
            "command is too long (maximum {MAX_COMMAND_LENGTH} bytes)"
        ));
    }

    let mut arguments = Vec::new();
    let mut current = String::new();
    let mut chars = command.chars().peekable();
    let mut quote = None;
    let mut argument_started = false;

    while let Some(character) = chars.next() {
        match quote {
            Some('\'') => {
                if character == '\'' {
                    quote = None;
                } else {
                    current.push(character);
                }
            }
            Some('"') => match character {
                '"' => quote = None,
                '\\' => {
                    let escaped = chars
                        .next()
                        .ok_or_else(|| "command ends with an incomplete escape".to_string())?;
                    current.push(unescape(escaped));
                }
                _ => current.push(character),
            },
            Some(_) => unreachable!(),
            None => match character {
                '\'' | '"' => {
                    quote = Some(character);
                    argument_started = true;
                }
                '\\' => {
                    let escaped = chars
                        .next()
                        .ok_or_else(|| "command ends with an incomplete escape".to_string())?;
                    current.push(unescape(escaped));
                    argument_started = true;
                }
                c if c.is_whitespace() => {
                    if argument_started {
                        arguments.push(std::mem::take(&mut current));
                        argument_started = false;
                    }
                }
                _ => {
                    current.push(character);
                    argument_started = true;
                }
            },
        }
    }

    if quote.is_some() {
        return Err("command contains an unterminated quote".to_string());
    }
    if argument_started {
        arguments.push(current);
    }
    if arguments.is_empty() {
        return Err("command must not be empty".to_string());
    }
    if arguments.len() > MAX_ARGUMENTS {
        return Err(format!(
            "command has too many arguments (maximum {MAX_ARGUMENTS})"
        ));
    }
    Ok(arguments)
}

fn unescape(character: char) -> char {
    match character {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        other => other,
    }
}

#[cfg(unix)]
async fn shutdown_signal() -> Result<(), String> {
    use tokio::signal::unix::{signal, SignalKind};

    let mut terminate = signal(SignalKind::terminate())
        .map_err(|error| format!("failed to register SIGTERM handler: {error}"))?;

    tokio::select! {
        result = tokio::signal::ctrl_c() => {
            result.map_err(|error| format!("failed to wait for Ctrl-C: {error}"))
        }
        _ = terminate.recv() => Ok(()),
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() -> Result<(), String> {
    tokio::signal::ctrl_c()
        .await
        .map_err(|error| format!("failed to wait for Ctrl-C: {error}"))
}

const INDEX_HTML: &str = r##"<!doctype html>
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
    use tokio::io::BufReader;

    #[test]
    fn parses_quoted_and_escaped_commands() {
        assert_eq!(
            parse_command(r#"SET "hello world" 'value with spaces'"#).unwrap(),
            vec!["SET", "hello world", "value with spaces"]
        );
        assert_eq!(
            parse_command(r#"SET escaped\ key line\nbreak"#).unwrap(),
            vec!["SET", "escaped key", "line\nbreak"]
        );
        assert_eq!(
            parse_command(r#"SET empty """#).unwrap(),
            vec!["SET", "empty", ""]
        );
    }

    #[test]
    fn rejects_invalid_commands() {
        assert!(parse_command("   ").unwrap_err().contains("empty"));
        assert!(parse_command(r#"GET "missing"#)
            .unwrap_err()
            .contains("unterminated"));
        assert!(parse_command("GET trailing\\")
            .unwrap_err()
            .contains("incomplete escape"));
    }

    #[test]
    fn encodes_resp_commands() {
        assert_eq!(
            encode_resp_command(&["SET".into(), "key".into(), "value".into()]),
            b"*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n"
        );
    }

    #[tokio::test]
    async fn parses_and_converts_resp_values() {
        let input = b"*5\r\n+OK\r\n:42\r\n$5\r\nhello\r\n$-1\r\n*2\r\n$1\r\na\r\n$1\r\nb\r\n";
        let mut reader = BufReader::new(&input[..]);
        let value = read_resp(&mut reader, 0).await.unwrap();
        assert_eq!(
            resp_to_json(value).unwrap(),
            json!(["OK", 42, "hello", null, ["a", "b"]])
        );
    }

    #[test]
    fn converts_binary_bulk_values_without_data_loss() {
        assert_eq!(
            resp_to_json(RespValue::Bulk(Some(vec![0xff, 0x00]))).unwrap(),
            json!([255, 0])
        );
        assert_eq!(
            resp_to_json(RespValue::Error("ERR failure".into())).unwrap_err(),
            "ERR failure"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn sends_sigterm_and_reaps_cooperative_child() {
        let mut child = Command::new("sh")
            .args(["-c", "trap 'exit 0' TERM; while :; do :; done"])
            .spawn()
            .unwrap();
        sleep(Duration::from_millis(50)).await;

        let status = stop_child_with_timeout(&mut child, Duration::from_secs(1))
            .await
            .unwrap();
        assert!(status.success());
        assert!(child.try_wait().unwrap().is_some());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn escalates_to_sigkill_and_reaps_uncooperative_child() {
        let mut child = Command::new("sh")
            .args(["-c", "trap '' TERM; while :; do :; done"])
            .spawn()
            .unwrap();
        sleep(Duration::from_millis(50)).await;

        let status = stop_child_with_timeout(&mut child, Duration::from_millis(100))
            .await
            .unwrap();
        assert!(!status.success());
        assert!(child.try_wait().unwrap().is_some());
    }
}
