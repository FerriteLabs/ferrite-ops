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
use tokio::sync::{oneshot, OwnedSemaphorePermit, Semaphore};
use tokio::time::timeout;

use crate::policy;
use crate::resp::{self, RespValue, MAX_ARGUMENTS};

pub const PUBLIC_RESP_ADDR: &str = "0.0.0.0:6379";
/// Maximum size of one RESP protocol header line.
pub const MAX_REQUEST_LINE: usize = 64 * 1024;
/// Maximum size of a single command argument sent by a client. Kept small
/// because it is also the largest single reservation any one client can hold
/// against the shared [`MAX_IN_FLIGHT_REQUEST_BYTES`] budget at once.
pub const MAX_REQUEST_BULK: usize = 256 * 1024;
/// Maximum total size of one command, across all its arguments.
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;
/// Global byte budget for declared bulk/array request sizes, shared across
/// every public RESP client. This — not the per-connection or per-command
/// limits above — is what actually bounds worst-case unauthenticated request
/// memory to a single-digit number of mebibytes, regardless of how many
/// connections are open or how many of them declare large commands at once.
pub const MAX_IN_FLIGHT_REQUEST_BYTES: usize = 4 * 1024 * 1024;
/// Bookkeeping overhead charged per declared argument slot (covers the
/// `Vec<u8>` header and allocator rounding) before the argument vector or any
/// bulk buffer is allocated, so a large declared array count is charged
/// against the budget even before its element sizes are known.
const ARGUMENT_SLOT_OVERHEAD_BYTES: usize = 64;
/// Maximum number of simultaneous public RESP clients.
pub const MAX_CONNECTIONS: usize = 64;
/// A client that sends nothing at all for this long is disconnected. This
/// only bounds the wait for a brand new command to begin; a conservative
/// playground value keeps an idle unauthenticated connection cheap.
pub const CLIENT_IDLE_TIMEOUT: Duration = Duration::from_secs(20);
/// Once a client has started sending a command (its header line has
/// arrived), each subsequent read — a further header line or bulk payload
/// bytes — must make progress within this deadline. This is deliberately
/// tighter than [`CLIENT_IDLE_TIMEOUT`] so a client that declares a bulk
/// length and then trickles its bytes in slowly cannot hold its
/// [`MAX_IN_FLIGHT_REQUEST_BYTES`] reservation, or the buffer it guards,
/// open indefinitely.
pub const CLIENT_READ_TIMEOUT: Duration = Duration::from_secs(5);
/// A client must accept each bounded response within this deadline.
pub const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// Error returned once an upstream operation can no longer preserve this
/// client's connection-scoped state. Keep this static so it is always a
/// bounded public response regardless of the upstream parse/I/O error.
const UPSTREAM_STATE_LOSS_ERROR: &str =
    "ERR playground upstream state was lost; reconnect before sending another command";
/// Error returned when the shared in-flight request-byte budget is already
/// exhausted by other clients' declared bulk/array sizes. Kept static so
/// rejection is always immediate and bounded, never itself allocating in
/// proportion to the offending request.
const REQUEST_BUDGET_EXHAUSTED_ERROR: &str =
    "ERR the Ferrite playground request budget is exhausted; try again shortly";

/// A decoded client request, or the end of the client's stream.
#[derive(Debug, PartialEq)]
pub enum Request {
    Command(Vec<Vec<u8>>),
    Eof,
}

/// Global in-flight byte budget for declared bulk/array request sizes,
/// shared across every public RESP client on this launcher instance.
///
/// Bytes are reserved from declared `$<length>` bulk headers and the
/// declared `*<count>` argument count *before* any payload buffer is
/// allocated, and the reservation is held by the caller through backend
/// execution and response delivery — released only once that reservation is
/// dropped. This means a slow client, or many clients declaring large
/// commands concurrently, can never commit more memory than this one budget
/// allows, regardless of per-connection or per-command limits.
#[derive(Clone)]
pub struct RequestByteBudget {
    permits: Arc<Semaphore>,
}

impl RequestByteBudget {
    pub fn new(capacity_bytes: usize) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(capacity_bytes)),
        }
    }

    /// Reserve `bytes` from the shared budget, failing immediately — without
    /// waiting — if the budget is currently exhausted by other clients. A
    /// reservation of zero bytes never touches the semaphore and always
    /// succeeds with no permit to hold.
    fn reserve(&self, bytes: usize) -> Result<Option<OwnedSemaphorePermit>, String> {
        if bytes == 0 {
            return Ok(None);
        }
        let permits = u32::try_from(bytes).unwrap_or(u32::MAX);
        Arc::clone(&self.permits)
            .try_acquire_many_owned(permits)
            .map(Some)
            .map_err(|_| REQUEST_BUDGET_EXHAUSTED_ERROR.to_string())
    }

    /// Bytes currently free in the shared budget. Test-only: production code
    /// only ever reserves and releases (by dropping) permits.
    #[cfg(test)]
    fn available_bytes(&self) -> usize {
        self.permits.available_permits()
    }
}

/// Accept public RESP clients until `shutdown` resolves.
pub async fn serve(
    listener: TcpListener,
    upstream_addr: &'static str,
    backend_permits: Arc<Semaphore>,
    shutdown: oneshot::Receiver<()>,
) -> Result<(), String> {
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    // One budget for the whole launcher instance: every public RESP client
    // spawned from this accept loop reserves from it, so it is what actually
    // bounds worst-case declared-request memory, not the per-connection cap.
    let request_budget = Arc::new(RequestByteBudget::new(MAX_IN_FLIGHT_REQUEST_BYTES));
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
                        let _ = write_response(
                            &mut stream,
                            &resp::encode_error(
                                "ERR the Ferrite playground has too many connections; try again shortly",
                            ),
                            CLIENT_WRITE_TIMEOUT,
                        ).await;
                        let _ = stream.shutdown().await;
                        continue;
                    }
                };

                let backend_permits = Arc::clone(&backend_permits);
                let request_budget = Arc::clone(&request_budget);
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(error) =
                        handle_connection(stream, upstream_addr, backend_permits, request_budget).await
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
    request_budget: Arc<RequestByteBudget>,
) -> Result<(), String> {
    let (client_read, mut client_write) = client.into_split();
    let mut client_read = BufReader::new(client_read);
    // One upstream connection per client keeps connection-scoped state (such
    // as SELECT or MULTI) consistent for that client.
    let mut upstream: Option<BufReader<TcpStream>> = None;

    loop {
        let request = match timeout(
            CLIENT_IDLE_TIMEOUT,
            read_request(&mut client_read, &request_budget),
        )
        .await
        {
            Ok(Ok(request)) => request,
            Ok(Err(error)) => {
                let _ = write_response(
                    &mut client_write,
                    &resp::encode_error(&error),
                    CLIENT_WRITE_TIMEOUT,
                )
                .await;
                let _ = client_write.shutdown().await;
                return Ok(());
            }
            Err(_) => {
                let _ = write_response(
                    &mut client_write,
                    &resp::encode_error("ERR playground client idle timeout"),
                    CLIENT_WRITE_TIMEOUT,
                )
                .await;
                let _ = client_write.shutdown().await;
                return Ok(());
            }
        };

        // Held for the rest of this iteration — through policy checks,
        // backend forwarding, and response delivery — and only released
        // when it goes out of scope at the end of the loop body (or on an
        // early `continue`/`return`), so the reservation for this command's
        // declared size always covers its whole lifetime on this launcher.
        let (request, _request_reservation) = request;

        let arguments = match request {
            Request::Eof => return Ok(()),
            Request::Command(arguments) => arguments,
        };
        if arguments.is_empty() {
            continue;
        }

        let decision = policy::classify_bytes_arguments(&arguments);
        if !decision.is_allowed() {
            write_response(
                &mut client_write,
                &resp::encode_error(&decision.message()),
                CLIENT_WRITE_TIMEOUT,
            )
            .await
            .map_err(|error| format!("failed to write policy rejection: {error}"))?;
            continue;
        }

        let permit = match Arc::clone(&backend_permits).try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                write_response(
                    &mut client_write,
                    &resp::encode_error(
                        "ERR the Ferrite playground backend is busy; try again shortly",
                    ),
                    CLIENT_WRITE_TIMEOUT,
                )
                .await
                .map_err(|error| format!("failed to write saturation rejection: {error}"))?;
                continue;
            }
        };

        let reply = forward(&mut upstream, upstream_addr, &arguments).await;
        let (encoded, close_client) = match reply {
            Ok(value) => {
                let mut encoded = Vec::new();
                match resp::encode_value(&value, &mut encoded, resp::MAX_RESPONSE_BYTES) {
                    Ok(()) => (encoded, false),
                    Err(error) => {
                        eprintln!(
                            "warning: closing public RESP client after oversized upstream response: {error}"
                        );
                        (resp::encode_error(UPSTREAM_STATE_LOSS_ERROR), true)
                    }
                }
            }
            Err(error) => {
                // A timeout, oversized reply, parse failure, or upstream I/O
                // error can leave unread bytes on the child connection. A
                // reconnect would silently discard SELECT/HELLO/MULTI state,
                // so return one bounded error and close this public client.
                eprintln!("warning: closing public RESP client after upstream state loss: {error}");
                (resp::encode_error(UPSTREAM_STATE_LOSS_ERROR), true)
            }
        };
        write_backend_response(&mut client_write, &encoded, permit, CLIENT_WRITE_TIMEOUT)
            .await
            .map_err(|error| format!("failed to write RESP reply: {error}"))?;
        if close_client {
            let _ = client_write.shutdown().await;
            return Ok(());
        }
    }
}

async fn write_backend_response<W>(
    writer: &mut W,
    encoded: &[u8],
    permit: OwnedSemaphorePermit,
    deadline: Duration,
) -> Result<(), String>
where
    W: AsyncWriteExt + Unpin,
{
    let result = write_response(writer, encoded, deadline).await;
    drop(permit);
    result
}

async fn write_response<W>(writer: &mut W, encoded: &[u8], deadline: Duration) -> Result<(), String>
where
    W: AsyncWriteExt + Unpin,
{
    timeout(deadline, async {
        writer
            .write_all(encoded)
            .await
            .map_err(|error| error.to_string())?;
        writer.flush().await.map_err(|error| error.to_string())
    })
    .await
    .map_err(|_| {
        format!(
            "client write timeout after {} seconds",
            deadline.as_secs_f64()
        )
    })?
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

/// Decode one RESP-array client command.
///
/// Every declared bulk length, and the declared argument count itself, is
/// reserved from `budget` immediately after being parsed and *before* the
/// corresponding buffer is allocated. Reservations accumulate in the
/// returned `Vec<OwnedSemaphorePermit>`; the caller must keep it alive for as
/// long as this command's memory is in use (through backend execution and
/// response delivery), and dropping it is what releases the budget.
///
/// Once the leading `*<count>` line has arrived — meaning a command has
/// begun — every subsequent read (further header lines and bulk payload
/// bytes) is bounded by [`CLIENT_READ_TIMEOUT`] rather than the more
/// generous idle wait for a brand new command, so a client that declares a
/// length and then trickles its bytes in slowly cannot hold its reservation
/// indefinitely.
pub async fn read_request<R>(
    reader: &mut R,
    budget: &RequestByteBudget,
) -> Result<(Request, Vec<OwnedSemaphorePermit>), String>
where
    R: AsyncBufRead + Unpin + Send,
{
    let line = match read_line(reader, MAX_REQUEST_LINE).await? {
        Some(line) => line,
        None => return Ok((Request::Eof, Vec::new())),
    };

    if !line.starts_with(b"*") {
        return Err(
            "ERR Protocol error: inline commands are not supported; use RESP arrays".to_string(),
        );
    }

    let count = parse_number(&line[1..], "argument count")?;
    if count <= 0 {
        return Ok((Request::Command(Vec::new()), Vec::new()));
    }
    if count as usize > MAX_ARGUMENTS {
        return Err(format!(
            "ERR command has too many arguments (maximum {MAX_ARGUMENTS})"
        ));
    }

    let mut reservation = Vec::new();
    // Charge the declared array shape itself before allocating its backing
    // vector below.
    if let Some(permit) = budget.reserve((count as usize) * ARGUMENT_SLOT_OVERHEAD_BYTES)? {
        reservation.push(permit);
    }

    let mut arguments = Vec::with_capacity(count as usize);
    let mut total = 0usize;
    for _ in 0..count {
        let header = timeout(CLIENT_READ_TIMEOUT, read_line(reader, MAX_REQUEST_LINE))
            .await
            .map_err(|_| read_timeout_error())??
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

        // Reserve this argument's declared size from the shared budget
        // before allocating the buffer that will hold it.
        if let Some(permit) = budget.reserve(length as usize)? {
            reservation.push(permit);
        }

        let mut data = vec![0u8; length as usize + 2];
        timeout(CLIENT_READ_TIMEOUT, reader.read_exact(&mut data))
            .await
            .map_err(|_| read_timeout_error())?
            .map_err(|error| format!("ERR failed to read RESP argument: {error}"))?;
        if !data.ends_with(b"\r\n") {
            return Err("ERR Protocol error: unbalanced argument terminator".to_string());
        }
        data.truncate(length as usize);
        arguments.push(data);
    }

    Ok((Request::Command(arguments), reservation))
}

fn read_timeout_error() -> String {
    format!(
        "ERR Protocol error: timed out reading command after {} seconds",
        CLIENT_READ_TIMEOUT.as_secs()
    )
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
    use tokio::io::{duplex, BufReader as IoBufReader};
    use tokio::time::sleep;

    async fn decode(input: &[u8]) -> Result<Request, String> {
        let budget = RequestByteBudget::new(MAX_IN_FLIGHT_REQUEST_BYTES);
        let mut reader = IoBufReader::new(input);
        read_request(&mut reader, &budget)
            .await
            .map(|(request, _reservation)| request)
    }

    #[tokio::test]
    async fn decodes_resp_array_arguments_without_text_reparsing() {
        assert_eq!(
            decode(b"*2\r\n$3\r\nGET\r\n$1\r\na\r\n").await.unwrap(),
            Request::Command(vec![b"GET".to_vec(), b"a".to_vec()])
        );
        assert_eq!(
            decode(&resp::encode_command(&[
                &b"SET"[..],
                &b"literal \"quoted\" argument"[..],
                &[0xff, 0x00, b' '][..],
            ]))
            .await
            .unwrap(),
            Request::Command(vec![
                b"SET".to_vec(),
                b"literal \"quoted\" argument".to_vec(),
                vec![0xff, 0x00, b' '],
            ])
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

        for inline in [b"PING\r\n".as_slice(), b"SET \"unterminated\r\n".as_slice()] {
            assert!(decode(inline)
                .await
                .unwrap_err()
                .contains("inline commands are not supported"));
        }
    }

    async fn start_proxy_with_permits(
        upstream: &'static str,
        backend_permits: Arc<Semaphore>,
    ) -> String {
        start_proxy_with_permits_and_budget(
            upstream,
            backend_permits,
            Arc::new(RequestByteBudget::new(MAX_IN_FLIGHT_REQUEST_BYTES)),
        )
        .await
    }

    async fn start_proxy_with_permits_and_budget(
        upstream: &'static str,
        backend_permits: Arc<Semaphore>,
        request_budget: Arc<RequestByteBudget>,
    ) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        tokio::spawn(async move {
            let (client, _) = listener.accept().await.unwrap();
            let _ = handle_connection(client, upstream, backend_permits, request_budget).await;
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
            vec!["COPY", "source", "destination", "DB", "16"],
            vec!["XTRIM", "stream", "MAXLEN", "="],
            vec!["XTRIM", "stream", "MAXLEN", "100", "LIMIT", "10"],
            vec![
                "XADD", "stream", "MAXLEN", "=", "100", "LIMIT", "10", "*", "field", "value",
            ],
            vec![
                "XADD",
                "stream",
                "18446744073709551615-18446744073709551615",
                "field",
                "value",
            ],
            vec!["SETBIT", "bitmap", "4294967288", "1"],
            vec!["SCAN", "0", "COUNT", "100"],
            vec!["SSCAN", "set", "0", "COUNT", "100"],
            vec!["HSCAN", "hash", "0", "COUNT", "100"],
            vec!["ZSCAN", "zset", "0", "COUNT", "100"],
            vec!["XREAD", "COUNT", "10", "STREAMS", "stream", "0-0"],
            vec!["XREAD", "STREAMS", "COUNT", "10", "stream", "0-0"],
            vec![
                "XREADGROUP",
                "GROUP",
                "group",
                "consumer",
                "COUNT",
                "10",
                "STREAMS",
                "stream",
                ">",
            ],
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
    async fn oversized_reply_closes_a_selected_client_without_resetting_to_database_zero() {
        let upstream = MockFerrite::start().await;
        upstream
            .seed_bytes("oversized", vec![0xff; resp::MAX_RESPONSE_BYTES + 1])
            .await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        assert_eq!(
            client.command(&["SELECT", "5"]).await,
            RespValue::Simple("OK".into())
        );
        let reply = client.command(&["GET", "oversized"]).await;
        match reply {
            RespValue::Error(message) => assert!(message.contains("state was lost")),
            other => panic!("oversized reply should have been refused, got {other:?}"),
        }
        assert!(
            client
                .try_command(&["GET", "must-not-run-on-database-zero"])
                .await
                .is_err(),
            "the proxy must close instead of reconnecting after state loss"
        );

        sleep(Duration::from_millis(20)).await;
        let commands = upstream.session_commands().await;
        assert!(commands.iter().any(|command| {
            command.name == "GET"
                && command.arguments == ["oversized"]
                && command.database == 5
                && command.protocol == 2
        }));
        assert!(
            !commands.iter().any(|command| {
                command.arguments == ["must-not-run-on-database-zero"] && command.database == 0
            }),
            "a state-losing reconnect must not execute the next command on database 0: {commands:?}"
        );
    }

    #[tokio::test]
    async fn malformed_reply_closes_a_resp3_client_without_resetting_the_protocol() {
        let upstream = MockFerrite::start().await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut client = crate::testing::RespClient::connect(&addr).await;

        assert!(matches!(
            client.command(&["HELLO", "3"]).await,
            RespValue::Map(_)
        ));
        assert!(matches!(
            client.command(&["GET", "__mock_malformed__"]).await,
            RespValue::Error(message) if message.contains("state was lost")
        ));
        assert!(
            client
                .try_command(&["GET", "must-not-run-with-default-protocol"])
                .await
                .is_err(),
            "the proxy must close instead of reconnecting after a parse error"
        );

        sleep(Duration::from_millis(20)).await;
        let commands = upstream.session_commands().await;
        assert!(commands.iter().any(|command| {
            command.name == "GET"
                && command.arguments == ["__mock_malformed__"]
                && command.protocol == 3
        }));
        assert!(
            !commands.iter().any(|command| {
                command.arguments == ["must-not-run-with-default-protocol"] && command.protocol == 2
            }),
            "a state-losing reconnect must not execute the next command as RESP2: {commands:?}"
        );
    }

    #[tokio::test]
    async fn inline_wire_commands_are_rejected_and_the_connection_is_closed() {
        let upstream = MockFerrite::start().await;
        let addr = start_proxy(upstream.leaked_addr()).await;
        let mut stream = TcpStream::connect(&addr).await.unwrap();
        stream
            .write_all(b"SET \"quoted key\" value\r\n")
            .await
            .unwrap();

        let mut reader = BufReader::new(stream);
        let reply = resp::read_value_budgeted(&mut reader, 0, &mut resp::ResponseBudget::default())
            .await
            .unwrap();
        assert!(matches!(
            reply,
            RespValue::Error(message) if message.contains("inline commands are not supported")
        ));

        let mut stream = reader.into_inner();
        let follow_up = stream.write_all(&resp::encode_command(&["PING"])).await;
        if follow_up.is_ok() {
            let mut reader = BufReader::new(stream);
            assert!(
                resp::read_value_budgeted(&mut reader, 0, &mut resp::ResponseBudget::default())
                    .await
                    .is_err(),
                "an inline protocol error closes the public connection"
            );
        }
        sleep(Duration::from_millis(20)).await;
        assert!(upstream.received_commands().await.is_empty());
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

    #[tokio::test]
    async fn backend_permit_is_held_until_a_slow_client_write_times_out() {
        let permits = Arc::new(Semaphore::new(1));
        let permit = Arc::clone(&permits).acquire_owned().await.unwrap();
        let (mut writer, _slow_reader) = duplex(8);
        let payload = vec![b'x'; 1024];

        let write = tokio::spawn(async move {
            write_backend_response(&mut writer, &payload, permit, Duration::from_millis(50)).await
        });
        tokio::task::yield_now().await;
        assert!(
            Arc::clone(&permits).try_acquire_owned().is_err(),
            "the backend permit must remain held while the response write is blocked"
        );
        assert!(write.await.unwrap().unwrap_err().contains("write timeout"));
        assert!(Arc::clone(&permits).try_acquire_owned().is_ok());
    }

    #[tokio::test]
    async fn public_resp_connections_cannot_accumulate_past_the_limit() {
        let upstream = MockFerrite::start().await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let service = tokio::spawn(serve(
            listener,
            upstream.leaked_addr(),
            Arc::new(Semaphore::new(4)),
            shutdown_rx,
        ));

        let mut held = Vec::new();
        for _ in 0..MAX_CONNECTIONS {
            held.push(TcpStream::connect(address).await.unwrap());
        }

        let excess = TcpStream::connect(address).await.unwrap();
        let mut excess = BufReader::new(excess);
        let reply = timeout(
            Duration::from_secs(1),
            resp::read_value_budgeted(&mut excess, 0, &mut resp::ResponseBudget::default()),
        )
        .await
        .expect("excess connection must be rejected promptly")
        .unwrap();
        assert!(
            matches!(reply, RespValue::Error(message) if message.contains("too many connections"))
        );

        drop(held.pop());
        tokio::time::sleep(Duration::from_millis(20)).await;
        let mut replacement = crate::testing::RespClient::connect(&address.to_string()).await;
        assert_eq!(
            replacement.command(&["PING"]).await,
            RespValue::Simple("PONG".into())
        );

        let _ = shutdown_tx.send(());
        service.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn concurrent_declared_bulk_requests_are_capped_by_the_shared_request_budget() {
        // A budget sized for a bit more than one 2,000-byte declared bulk
        // (plus its small array-shape overhead), but not two at once.
        let budget = RequestByteBudget::new(2_100);

        let mut first_input = b"*1\r\n$2000\r\n".to_vec();
        first_input.extend(vec![b'a'; 2000]);
        first_input.extend(b"\r\n");
        let mut first_reader = IoBufReader::new(first_input.as_slice());
        let (first_request, first_reservation) = read_request(&mut first_reader, &budget)
            .await
            .expect("the first declared bulk fits the shared budget");
        assert_eq!(first_request, Request::Command(vec![vec![b'a'; 2000]]));
        assert!(
            !first_reservation.is_empty(),
            "a non-zero declared bulk must hold at least one budget permit"
        );

        // A second, concurrently-arriving client declaring another
        // similarly sized bulk no longer fits in the remaining shared
        // budget and is rejected immediately, without waiting, and without
        // ever allocating its payload buffer.
        let mut second_input = b"*1\r\n$2000\r\n".to_vec();
        second_input.extend(vec![b'b'; 2000]);
        second_input.extend(b"\r\n");
        let mut second_reader = IoBufReader::new(second_input.as_slice());
        let second_result = timeout(
            Duration::from_millis(200),
            read_request(&mut second_reader, &budget),
        )
        .await
        .expect("an over-budget request must be rejected immediately, not after waiting");
        assert!(
            second_result
                .unwrap_err()
                .contains("request budget is exhausted"),
            "a concurrent declared bulk that no longer fits the shared budget must be refused"
        );

        // Releasing the first reservation — as happens once its command's
        // response has been delivered — frees the budget back up for a
        // subsequent client.
        drop(first_reservation);
        let mut third_input = b"*1\r\n$2000\r\n".to_vec();
        third_input.extend(vec![b'c'; 2000]);
        third_input.extend(b"\r\n");
        let mut third_reader = IoBufReader::new(third_input.as_slice());
        let (third_request, _third_reservation) = read_request(&mut third_reader, &budget)
            .await
            .expect("the budget must be available again once the prior reservation is released");
        assert_eq!(third_request, Request::Command(vec![vec![b'c'; 2000]]));
    }

    #[tokio::test(start_paused = true)]
    async fn slow_partial_client_holds_its_reservation_only_until_the_read_deadline() {
        let budget = RequestByteBudget::new(4096);
        let (mut writer, reader) = duplex(4096);
        let mut reader = IoBufReader::new(reader);

        // Declare one 2,000-byte bulk argument, then send only a few of its
        // bytes and stall — simulating a slow or malicious client that
        // trickles data in rather than sending it promptly.
        writer.write_all(b"*1\r\n$2000\r\n").await.unwrap();
        writer.write_all(&[b'x'; 10]).await.unwrap();

        let read_budget = budget.clone();
        let read = tokio::spawn(async move { read_request(&mut reader, &read_budget).await });

        // Let the reader task run until it genuinely blocks waiting for the
        // rest of the declared bulk.
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;
        assert!(
            budget.available_bytes() < 4096,
            "the declared bulk length must be reserved before all of its bytes arrive"
        );

        // The client never sends the remaining bytes; once the read
        // deadline elapses the stalled read must fail with a bounded error
        // rather than hang, and its reservation must be released.
        tokio::time::advance(CLIENT_READ_TIMEOUT + Duration::from_secs(1)).await;
        let result = read.await.unwrap();
        assert!(
            result.unwrap_err().contains("timed out"),
            "a stalled partial client must be disconnected with a bounded timeout error"
        );
        assert_eq!(
            budget.available_bytes(),
            4096,
            "the reservation held by a stalled client must be released once it times out"
        );
    }
}
