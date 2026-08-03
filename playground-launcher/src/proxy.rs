//! Public RESP proxy.
//!
//! The launcher — not Ferrite — owns the public Redis-compatible port. Every
//! client command is parsed, classified by the shared playground policy, and
//! only then forwarded to the internal Ferrite child, whose reply is decoded
//! and re-encoded back to the client. Administrative and lifecycle commands
//! are refused here, so an unauthenticated client cannot stop, reconfigure,
//! or replicate the shared playground instance through the public port.

use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, Semaphore};
use tokio::time::timeout;

use crate::policy;
use crate::resp::{self, RespValue, MAX_ARGUMENTS};

pub const PUBLIC_RESP_ADDR: &str = "0.0.0.0:6379";
/// Maximum size of one inline command line or one protocol header line.
pub const MAX_REQUEST_LINE: usize = 64 * 1024;
/// Maximum size of a single command argument sent by a client.
pub const MAX_REQUEST_BULK: usize = 1024 * 1024;
/// Maximum total size of one command, across all its arguments.
pub const MAX_REQUEST_BYTES: usize = 8 * 1024 * 1024;
/// Maximum number of simultaneous public RESP clients.
pub const MAX_CONNECTIONS: usize = 64;
/// A client that sends nothing for this long is disconnected.
pub const CLIENT_IDLE_TIMEOUT: Duration = Duration::from_secs(300);

/// A decoded client request, or the end of the client's stream.
#[derive(Debug, PartialEq)]
pub enum Request {
    Command(Vec<Vec<u8>>),
    Eof,
}

/// Accept public RESP clients until `shutdown` resolves.
pub async fn serve(
    listener: TcpListener,
    upstream_addr: &'static str,
    backend_permits: Arc<Semaphore>,
    shutdown: oneshot::Receiver<()>,
) -> Result<(), String> {
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            _ = &mut shutdown => return Ok(()),
            accepted = listener.accept() => {
                let (stream, peer) = match accepted {
                    Ok(accepted) => accepted,
                    Err(error) => {
                        eprintln!("warning: public RESP accept failed: {error}");
                        continue;
                    }
                };

                let permit = match Arc::clone(&permits).try_acquire_owned() {
                    Ok(permit) => permit,
                    Err(_) => {
                        let mut stream = stream;
                        let _ = stream
                            .write_all(&resp::encode_error(
                                "ERR the Ferrite playground has too many connections; try again shortly",
                            ))
                            .await;
                        let _ = stream.shutdown().await;
                        continue;
                    }
                };

                let backend_permits = Arc::clone(&backend_permits);
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(error) =
                        handle_connection(stream, upstream_addr, backend_permits).await
                    {
                        eprintln!("warning: public RESP client {peer} failed: {error}");
                    }
                });
            }
        }
    }
}

/// Serve one public client until it disconnects or violates the protocol.
pub async fn handle_connection(
    client: TcpStream,
    upstream_addr: &str,
    backend_permits: Arc<Semaphore>,
) -> Result<(), String> {
    let (client_read, mut client_write) = client.into_split();
    let mut client_read = BufReader::new(client_read);
    // One upstream connection per client keeps connection-scoped state (such
    // as SELECT or MULTI) consistent for that client.
    let mut upstream: Option<BufReader<TcpStream>> = None;

    loop {
        let request = match timeout(CLIENT_IDLE_TIMEOUT, read_request(&mut client_read)).await {
            Ok(Ok(request)) => request,
            Ok(Err(error)) => {
                let _ = client_write.write_all(&resp::encode_error(&error)).await;
                let _ = client_write.shutdown().await;
                return Ok(());
            }
            Err(_) => {
                let _ = client_write
                    .write_all(&resp::encode_error("ERR playground client idle timeout"))
                    .await;
                let _ = client_write.shutdown().await;
                return Ok(());
            }
        };

        let arguments = match request {
            Request::Eof => return Ok(()),
            Request::Command(arguments) => arguments,
        };
        if arguments.is_empty() {
            continue;
        }

        let decision = policy::classify_bytes_arguments(&arguments);
        if !decision.is_allowed() {
            client_write
                .write_all(&resp::encode_error(&decision.message()))
                .await
                .map_err(|error| format!("failed to write policy rejection: {error}"))?;
            continue;
        }

        let permit = match Arc::clone(&backend_permits).try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                client_write
                    .write_all(&resp::encode_error(
                        "ERR the Ferrite playground backend is busy; try again shortly",
                    ))
                    .await
                    .map_err(|error| format!("failed to write saturation rejection: {error}"))?;
                continue;
            }
        };

        let reply = forward(&mut upstream, upstream_addr, &arguments).await;
        drop(permit);
        let encoded = match reply {
            Ok(value) => {
                let mut encoded = Vec::new();
                match resp::encode_value(&value, &mut encoded, resp::MAX_RESPONSE_BYTES) {
                    Ok(()) => encoded,
                    Err(error) => {
                        upstream = None;
                        resp::encode_error(&format!("ERR playground backend error: {error}"))
                    }
                }
            }
            Err(error) => {
                // The upstream stream may be desynchronized after a failure,
                // so drop it; the next command reconnects.
                upstream = None;
                resp::encode_error(&format!("ERR playground backend error: {error}"))
            }
        };
        client_write
            .write_all(&encoded)
            .await
            .map_err(|error| format!("failed to write RESP reply: {error}"))?;
    }
}

async fn forward(
    upstream: &mut Option<BufReader<TcpStream>>,
    upstream_addr: &str,
    arguments: &[Vec<u8>],
) -> Result<RespValue, String> {
    if upstream.is_none() {
        let stream = timeout(resp::RESP_TIMEOUT, TcpStream::connect(upstream_addr))
            .await
            .map_err(|_| format!("timed out connecting to {upstream_addr}"))?
            .map_err(|error| format!("could not connect to {upstream_addr}: {error}"))?;
        *upstream = Some(BufReader::new(stream));
    }
    let stream = upstream
        .as_mut()
        .expect("upstream connection was just established");

    let request = resp::encode_command(arguments);
    timeout(resp::RESP_TIMEOUT, async {
        stream
            .get_mut()
            .write_all(&request)
            .await
            .map_err(|error| format!("failed to forward RESP command: {error}"))?;
        stream
            .get_mut()
            .flush()
            .await
            .map_err(|error| format!("failed to flush RESP command: {error}"))?;

        // Every reply forwarded to a public client is bounded by one
        // cumulative byte budget, so no single command can make the proxy
        // buffer an unbounded response.
        let mut budget = resp::ResponseBudget::default();
        resp::read_value_budgeted(stream, 0, &mut budget)
            .await
            .map_err(|error| format!("{error} (read {} bytes)", budget.used()))
    })
    .await
    .map_err(|_| {
        format!(
            "upstream RESP timeout after {} seconds",
            resp::RESP_TIMEOUT.as_secs()
        )
    })?
}

/// Decode one client command in either RESP array or inline form.
pub async fn read_request<R>(reader: &mut R) -> Result<Request, String>
where
    R: AsyncBufRead + Unpin + Send,
{
    let line = match read_line(reader, MAX_REQUEST_LINE).await? {
        Some(line) => line,
        None => return Ok(Request::Eof),
    };

    if !line.starts_with(b"*") {
        return Ok(Request::Command(parse_inline(&line)));
    }

    let count = parse_number(&line[1..], "argument count")?;
    if count <= 0 {
        return Ok(Request::Command(Vec::new()));
    }
    if count as usize > MAX_ARGUMENTS {
        return Err(format!(
            "ERR command has too many arguments (maximum {MAX_ARGUMENTS})"
        ));
    }

    let mut arguments = Vec::with_capacity(count as usize);
    let mut total = 0usize;
    for _ in 0..count {
        let header = read_line(reader, MAX_REQUEST_LINE)
            .await?
            .ok_or_else(|| "ERR unexpected end of RESP command".to_string())?;
        if !header.starts_with(b"$") {
            return Err("ERR Protocol error: expected '$', got something else".to_string());
        }
        let length = parse_number(&header[1..], "bulk length")?;
        if length < 0 || length as usize > MAX_REQUEST_BULK {
            return Err(format!(
                "ERR Protocol error: invalid bulk length (maximum {MAX_REQUEST_BULK} bytes)"
            ));
        }
        total = total.saturating_add(length as usize);
        if total > MAX_REQUEST_BYTES {
            return Err(format!(
                "ERR command is too large (maximum {MAX_REQUEST_BYTES} bytes)"
            ));
        }

        let mut data = vec![0u8; length as usize + 2];
        reader
            .read_exact(&mut data)
            .await
            .map_err(|error| format!("ERR failed to read RESP argument: {error}"))?;
        if !data.ends_with(b"\r\n") {
            return Err("ERR Protocol error: unbalanced argument terminator".to_string());
        }
        data.truncate(length as usize);
        arguments.push(data);
    }

    Ok(Request::Command(arguments))
}

/// Read one CRLF/LF-terminated line, refusing lines longer than `limit`.
async fn read_line<R>(reader: &mut R, limit: usize) -> Result<Option<Vec<u8>>, String>
where
    R: AsyncBufRead + Unpin + Send,
{
    let mut line = Vec::new();
    let read = {
        let mut limited = reader.take(limit as u64 + 1);
        limited
            .read_until(b'\n', &mut line)
            .await
            .map_err(|error| format!("ERR failed to read command: {error}"))?
    };
    if read == 0 {
        return Ok(None);
    }
    if !line.ends_with(b"\n") {
        return Err(format!(
            "ERR Protocol error: command line exceeds {limit} bytes"
        ));
    }
    line.pop();
    if line.ends_with(b"\r") {
        line.pop();
    }
    Ok(Some(line))
}

fn parse_inline(line: &[u8]) -> Vec<Vec<u8>> {
    line.split(|byte| byte.is_ascii_whitespace())
        .filter(|token| !token.is_empty())
        .take(MAX_ARGUMENTS)
        .map(|token| token.to_vec())
        .collect()
}

fn parse_number(payload: &[u8], field: &str) -> Result<i64, String> {
    std::str::from_utf8(payload)
        .map_err(|_| format!("ERR Protocol error: invalid {field}"))?
        .trim()
        .parse::<i64>()
        .map_err(|_| format!("ERR Protocol error: invalid {field}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::MockFerrite;
    use tokio::io::BufReader as IoBufReader;

    async fn decode(input: &[u8]) -> Result<Request, String> {
        let mut reader = IoBufReader::new(input);
        read_request(&mut reader).await
    }

    #[tokio::test]
    async fn decodes_array_and_inline_requests() {
        assert_eq!(
            decode(b"*2\r\n$3\r\nGET\r\n$1\r\na\r\n").await.unwrap(),
            Request::Command(vec![b"GET".to_vec(), b"a".to_vec()])
        );
        assert_eq!(
            decode(b"PING\r\n").await.unwrap(),
            Request::Command(vec![b"PING".to_vec()])
        );
        assert_eq!(decode(b"").await.unwrap(), Request::Eof);
        assert_eq!(
            decode(b"*0\r\n").await.unwrap(),
            Request::Command(Vec::new())
        );
    }

    #[tokio::test]
    async fn rejects_malformed_and_oversized_requests() {
        assert!(decode(b"*2\r\n+GET\r\n").await.unwrap_err().contains("$"));
        assert!(decode(b"*abc\r\n")
            .await
            .unwrap_err()
            .contains("invalid argument count"));
        assert!(decode(format!("*{}\r\n", MAX_ARGUMENTS + 1).as_bytes())
            .await
            .unwrap_err()
            .contains("too many arguments"));
        assert!(
            decode(format!("*1\r\n${}\r\n", MAX_REQUEST_BULK + 1).as_bytes())
                .await
                .unwrap_err()
                .contains("invalid bulk length")
        );

        let long_line = format!("{}\r\n", "A".repeat(MAX_REQUEST_LINE + 10));
        assert!(decode(long_line.as_bytes())
            .await
            .unwrap_err()
            .contains("exceeds"));
    }

    async fn start_proxy_with_permits(
        upstream: &'static str,
        backend_permits: Arc<Semaphore>,
    ) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        tokio::spawn(async move {
            let (client, _) = listener.accept().await.unwrap();
            let _ = handle_connection(client, upstream, backend_permits).await;
        });
        addr
    }

    async fn start_proxy(upstream: &'static str) -> String {
        start_proxy_with_permits(upstream, Arc::new(Semaphore::new(4))).await
    }

    #[tokio::test]
    async fn rejects_non_allowlisted_and_unbounded_commands_without_forwarding_them() {
        let upstream = MockFerrite::start().await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        for command in [
            vec!["SHUTDOWN"],
            vec!["PLUGIN", "LIST"],
            vec!["AUDIT", "START"],
            vec!["MIGRATE.START", "redis://example.invalid"],
            vec!["MIGRATE", "START", "redis://example.invalid"],
            vec!["LRANGE", "list", "0", "-1"],
            vec!["XRANGE", "stream", "-", "+"],
        ] {
            let reply = client.command(&command).await;
            match reply {
                RespValue::Error(message) => {
                    assert!(
                        message.contains("playground"),
                        "{command:?} rejection should explain the playground policy: {message}"
                    );
                }
                other => panic!("{command:?} should have been rejected, got {other:?}"),
            }
        }

        assert_eq!(upstream.received_commands().await, Vec::<String>::new());
        assert!(!upstream.was_shutdown().await);
    }

    #[tokio::test]
    async fn forwards_ordinary_commands_and_returns_real_replies() {
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
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        assert_eq!(
            client.command(&["PING"]).await,
            RespValue::Simple("PONG".into())
        );
        assert_eq!(
            client.command(&["ECHO", "hello"]).await,
            RespValue::Bulk(Some(b"hello".to_vec()))
        );
        assert_eq!(
            client.command(&["SET", "proxy-key", "proxy-value"]).await,
            RespValue::Simple("OK".into())
        );
        assert_eq!(
            client.command(&["GET", "proxy-key"]).await,
            RespValue::Bulk(Some(b"proxy-value".to_vec()))
        );
        assert_eq!(
            client.command(&["GET", "missing"]).await,
            RespValue::Bulk(None)
        );
        assert!(matches!(
            client.command(&["LRANGE", "list", "0", "99"]).await,
            RespValue::Array(Some(values)) if values.len() == 100
        ));
        assert!(matches!(
            client
                .command(&["XRANGE", "stream", "-", "+", "COUNT", "100"])
                .await,
            RespValue::Array(Some(values)) if values.len() == 100
        ));

        assert_eq!(
            upstream.received_commands().await,
            vec!["PING", "ECHO", "SET", "GET", "GET", "LRANGE", "XRANGE"]
        );
    }

    #[tokio::test]
    async fn keeps_serving_after_a_rejected_command() {
        let upstream = MockFerrite::start().await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        assert!(matches!(
            client.command(&["SHUTDOWN"]).await,
            RespValue::Error(_)
        ));
        assert_eq!(
            client.command(&["SET", "after", "reject"]).await,
            RespValue::Simple("OK".into())
        );
        assert_eq!(
            client.command(&["GET", "after"]).await,
            RespValue::Bulk(Some(b"reject".to_vec()))
        );
        assert!(!upstream.was_shutdown().await);
    }

    #[tokio::test]
    async fn public_replies_are_bounded_by_the_cumulative_response_budget() {
        let upstream = MockFerrite::start().await;
        upstream
            .seed_string("oversized", &"x".repeat(resp::MAX_RESPONSE_BYTES + 1))
            .await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        let reply = client.command(&["GET", "oversized"]).await;
        match reply {
            RespValue::Error(message) => assert!(
                message.contains("response budget"),
                "unexpected error: {message}"
            ),
            other => panic!("oversized reply should have been refused, got {other:?}"),
        }

        // The connection recovers: the desynchronized upstream is dropped and
        // the next command is served on a fresh one.
        assert_eq!(
            client.command(&["PING"]).await,
            RespValue::Simple("PONG".into())
        );
    }

    #[tokio::test]
    async fn inline_administrative_commands_are_rejected_too() {
        let upstream = MockFerrite::start().await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut stream = TcpStream::connect(&addr).await.unwrap();
        stream.write_all(b"shutdown nosave\r\n").await.unwrap();

        let mut reader = BufReader::new(stream);
        let reply = resp::read_value_budgeted(&mut reader, 0, &mut resp::ResponseBudget::default())
            .await
            .unwrap();
        assert!(matches!(reply, RespValue::Error(_)));
        assert!(!upstream.was_shutdown().await);
    }

    #[tokio::test]
    async fn returns_an_error_without_forwarding_when_backend_pool_is_saturated() {
        let upstream = MockFerrite::start().await;
        let permits = Arc::new(Semaphore::new(1));
        let held = Arc::clone(&permits).acquire_owned().await.unwrap();
        let addr = start_proxy_with_permits(upstream.leaked_addr(), permits).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        match client.command(&["PING"]).await {
            RespValue::Error(message) => assert!(message.contains("backend is busy")),
            other => panic!("saturated proxy should return an error, got {other:?}"),
        }
        assert!(upstream.received_commands().await.is_empty());

        drop(held);
        assert_eq!(
            client.command(&["PING"]).await,
            RespValue::Simple("PONG".into())
        );
    }
}
