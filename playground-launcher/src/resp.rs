//! RESP protocol codec and a minimal request/response client.
//!
//! The launcher speaks RESP in two directions: it decodes replies from the
//! Ferrite child and it re-encodes them for public RESP clients, so encoding
//! and decoding live together here and nowhere else.

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::time::timeout;

/// Upper bound on a single bulk string in a reply.
pub const MAX_RESP_BULK_LENGTH: usize = 16 * 1024 * 1024;
/// Upper bound on the number of elements in a single reply array.
pub const MAX_RESP_ARRAY_LENGTH: usize = 4 * 1024;
/// Upper bound on reply nesting.
pub const MAX_RESP_DEPTH: usize = 64;
/// Upper bound on decoded RESP values in one reply, including aggregate roots.
pub const MAX_RESPONSE_NODES: usize = 8 * 1024;
/// Upper bound on aggregate child slots claimed across one decoded reply.
pub const MAX_RESPONSE_ELEMENTS: usize = 8 * 1024;
/// Cumulative byte budget for one decoded reply.
///
/// This bounds the *whole* reply — every header line, every bulk payload, and
/// every element of every nested array together — rather than each element
/// individually, so a reply made of many individually small elements (for
/// example `KEYS *` on a large keyspace) cannot exhaust the launcher's memory.
pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
/// Maximum number of arguments accepted in one command.
pub const MAX_ARGUMENTS: usize = 256;
/// Time bound for a full connect/write/read cycle against the Ferrite child.
pub const RESP_TIMEOUT: Duration = Duration::from_secs(5);

/// Cumulative byte budget consumed while decoding a single reply.
#[derive(Debug)]
pub struct ResponseBudget {
    byte_limit: usize,
    bytes_used: usize,
    node_limit: usize,
    nodes_used: usize,
    element_limit: usize,
    elements_used: usize,
}

impl ResponseBudget {
    pub fn new(byte_limit: usize) -> Self {
        Self::with_limits(byte_limit, MAX_RESPONSE_NODES, MAX_RESPONSE_ELEMENTS)
    }

    pub fn with_limits(byte_limit: usize, node_limit: usize, element_limit: usize) -> Self {
        Self {
            byte_limit,
            bytes_used: 0,
            node_limit,
            nodes_used: 0,
            element_limit,
            elements_used: 0,
        }
    }

    /// Charge `bytes` to the budget, failing once the cumulative total for
    /// this reply exceeds the limit.
    pub fn consume_bytes(&mut self, bytes: usize) -> Result<(), String> {
        let next = self.bytes_used.saturating_add(bytes);
        if next > self.byte_limit {
            return Err(format!(
                "response exceeds the playground response budget of {} bytes",
                self.byte_limit
            ));
        }
        self.bytes_used = next;
        Ok(())
    }

    /// Charge one decoded RESP value before constructing it.
    pub fn consume_node(&mut self) -> Result<(), String> {
        let next = self.nodes_used.saturating_add(1);
        if next > self.node_limit {
            return Err(format!(
                "response exceeds the playground decoded-node budget of {} values",
                self.node_limit
            ));
        }
        self.nodes_used = next;
        Ok(())
    }

    /// Reserve aggregate child slots before allocating their backing vector.
    pub fn reserve_elements(&mut self, elements: usize) -> Result<(), String> {
        let next = self.elements_used.saturating_add(elements);
        if next > self.element_limit {
            return Err(format!(
                "response exceeds the playground decoded-element budget of {} elements",
                self.element_limit
            ));
        }
        self.elements_used = next;
        Ok(())
    }

    /// Bytes charged to this budget so far.
    pub fn used(&self) -> usize {
        self.bytes_used
    }

    #[cfg(test)]
    fn nodes_used(&self) -> usize {
        self.nodes_used
    }

    #[cfg(test)]
    fn elements_used(&self) -> usize {
        self.elements_used
    }
}

impl Default for ResponseBudget {
    fn default() -> Self {
        Self::new(MAX_RESPONSE_BYTES)
    }
}

/// A decoded RESP2 or RESP3 value.
///
/// Clients may negotiate RESP3 with `HELLO 3` on the public port, so every
/// RESP3 reply type is decoded and re-encoded byte-for-byte. Numeric types
/// keep their original text so re-encoding never reformats a value.
#[derive(Debug, PartialEq, Clone)]
pub enum RespValue {
    Simple(String),
    Error(String),
    Integer(i64),
    Bulk(Option<Vec<u8>>),
    Array(Option<Vec<RespValue>>),
    /// RESP3 `_` null.
    Null,
    /// RESP3 `#` boolean.
    Boolean(bool),
    /// RESP3 `,` double, kept as its original text.
    Double(String),
    /// RESP3 `(` big number, kept as its original text.
    BigNumber(String),
    /// RESP3 `!` blob error.
    BlobError(Vec<u8>),
    /// RESP3 `=` verbatim string, including its `txt:`/`mkd:` prefix.
    Verbatim(Vec<u8>),
    /// RESP3 `%` map.
    Map(Vec<(RespValue, RespValue)>),
    /// RESP3 `~` set.
    Set(Vec<RespValue>),
    /// RESP3 `>` out-of-band push.
    Push(Vec<RespValue>),
}

/// Encode an argv-style command as a RESP array of bulk strings.
pub fn encode_command<S: AsRef<[u8]>>(arguments: &[S]) -> Vec<u8> {
    let mut encoded = format!("*{}\r\n", arguments.len()).into_bytes();
    for argument in arguments {
        let argument = argument.as_ref();
        encoded.extend_from_slice(format!("${}\r\n", argument.len()).as_bytes());
        encoded.extend_from_slice(argument);
        encoded.extend_from_slice(b"\r\n");
    }
    encoded
}

/// Serialize a decoded value back onto the wire without allowing `out` to
/// exceed `limit`.
pub fn encode_value(value: &RespValue, out: &mut Vec<u8>, limit: usize) -> Result<(), String> {
    match value {
        RespValue::Simple(value) => {
            append(out, b"+", limit)?;
            append(out, value.as_bytes(), limit)?;
            append(out, b"\r\n", limit)?;
        }
        RespValue::Error(error) => {
            append(out, b"-", limit)?;
            append(out, error.as_bytes(), limit)?;
            append(out, b"\r\n", limit)?;
        }
        RespValue::Integer(value) => {
            append(out, format!(":{value}\r\n").as_bytes(), limit)?;
        }
        RespValue::Bulk(None) => append(out, b"$-1\r\n", limit)?,
        RespValue::Bulk(Some(data)) => {
            append(out, format!("${}\r\n", data.len()).as_bytes(), limit)?;
            append(out, data, limit)?;
            append(out, b"\r\n", limit)?;
        }
        RespValue::Array(None) => append(out, b"*-1\r\n", limit)?,
        RespValue::Array(Some(values)) => {
            append(out, format!("*{}\r\n", values.len()).as_bytes(), limit)?;
            for value in values {
                encode_value(value, out, limit)?;
            }
        }
        RespValue::Null => append(out, b"_\r\n", limit)?,
        RespValue::Boolean(value) => {
            append(out, if *value { b"#t\r\n" } else { b"#f\r\n" }, limit)?;
        }
        RespValue::Double(value) => {
            append(out, format!(",{value}\r\n").as_bytes(), limit)?;
        }
        RespValue::BigNumber(value) => {
            append(out, format!("({value}\r\n").as_bytes(), limit)?;
        }
        RespValue::BlobError(data) => {
            append(out, format!("!{}\r\n", data.len()).as_bytes(), limit)?;
            append(out, data, limit)?;
            append(out, b"\r\n", limit)?;
        }
        RespValue::Verbatim(data) => {
            append(out, format!("={}\r\n", data.len()).as_bytes(), limit)?;
            append(out, data, limit)?;
            append(out, b"\r\n", limit)?;
        }
        RespValue::Map(entries) => {
            append(out, format!("%{}\r\n", entries.len()).as_bytes(), limit)?;
            for (key, value) in entries {
                encode_value(key, out, limit)?;
                encode_value(value, out, limit)?;
            }
        }
        RespValue::Set(values) => {
            append(out, format!("~{}\r\n", values.len()).as_bytes(), limit)?;
            for value in values {
                encode_value(value, out, limit)?;
            }
        }
        RespValue::Push(values) => {
            append(out, format!(">{}\r\n", values.len()).as_bytes(), limit)?;
            for value in values {
                encode_value(value, out, limit)?;
            }
        }
    }
    Ok(())
}

fn append(out: &mut Vec<u8>, bytes: &[u8], limit: usize) -> Result<(), String> {
    if out.len().saturating_add(bytes.len()) > limit {
        return Err(format!(
            "encoded response exceeds the playground output budget of {limit} bytes"
        ));
    }
    out.extend_from_slice(bytes);
    Ok(())
}

/// Encode an error reply for a command the playground refuses to forward.
pub fn encode_error(message: &str) -> Vec<u8> {
    let mut out = Vec::new();
    encode_value(
        &RespValue::Error(message.to_string()),
        &mut out,
        MAX_RESPONSE_BYTES,
    )
    .expect("playground-generated error replies are bounded");
    out
}

/// Decode a single reply, charging every byte read to `budget`.
pub fn read_value_budgeted<'a, R>(
    reader: &'a mut R,
    depth: usize,
    budget: &'a mut ResponseBudget,
) -> Pin<Box<dyn Future<Output = Result<RespValue, String>> + Send + 'a>>
where
    R: AsyncBufRead + Unpin + Send + 'a,
{
    Box::pin(async move {
        if depth > MAX_RESP_DEPTH {
            return Err("RESP response nesting is too deep".to_string());
        }
        budget.consume_node()?;

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
        budget.consume_bytes(line.len())?;
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
            b':' => Ok(RespValue::Integer(parse_number(payload, "integer")?)),
            b'$' => {
                let length = parse_number(payload, "bulk length")?;
                if length == -1 {
                    return Ok(RespValue::Bulk(None));
                }
                if length < -1 || length as usize > MAX_RESP_BULK_LENGTH {
                    return Err(format!("invalid RESP bulk length: {length}"));
                }

                budget.consume_bytes(length as usize + 2)?;
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
                let length = parse_number(payload, "array length")?;
                if length == -1 {
                    return Ok(RespValue::Array(None));
                }
                if length < -1 || length as usize > MAX_RESP_ARRAY_LENGTH {
                    return Err(format!("invalid RESP array length: {length}"));
                }

                let length = length as usize;
                budget.reserve_elements(length)?;
                let mut values = Vec::with_capacity(length);
                for _ in 0..length {
                    values.push(read_value_budgeted(reader, depth + 1, budget).await?);
                }
                Ok(RespValue::Array(Some(values)))
            }
            b'_' => Ok(RespValue::Null),
            b'#' => match payload {
                b"t" => Ok(RespValue::Boolean(true)),
                b"f" => Ok(RespValue::Boolean(false)),
                _ => Err("invalid RESP boolean value".to_string()),
            },
            b',' => Ok(RespValue::Double(parse_text(payload, "double")?)),
            b'(' => Ok(RespValue::BigNumber(parse_text(payload, "big number")?)),
            b'!' | b'=' => {
                let length = parse_number(payload, "blob length")?;
                if length < 0 || length as usize > MAX_RESP_BULK_LENGTH {
                    return Err(format!("invalid RESP blob length: {length}"));
                }
                budget.consume_bytes(length as usize + 2)?;
                let mut data = vec![0; length as usize + 2];
                reader
                    .read_exact(&mut data)
                    .await
                    .map_err(|error| format!("failed to read RESP blob data: {error}"))?;
                if !data.ends_with(b"\r\n") {
                    return Err("RESP blob data did not end with CRLF".to_string());
                }
                data.truncate(length as usize);
                if prefix == b'!' {
                    Ok(RespValue::BlobError(data))
                } else {
                    Ok(RespValue::Verbatim(data))
                }
            }
            b'%' => {
                let length = parse_number(payload, "map length")?;
                if length < 0 || length as usize > MAX_RESP_ARRAY_LENGTH {
                    return Err(format!("invalid RESP map length: {length}"));
                }
                let length = length as usize;
                let child_nodes = length
                    .checked_mul(2)
                    .ok_or_else(|| "RESP map length overflow".to_string())?;
                budget.reserve_elements(child_nodes)?;
                let mut entries = Vec::with_capacity(length);
                for _ in 0..length {
                    let key = read_value_budgeted(reader, depth + 1, budget).await?;
                    let value = read_value_budgeted(reader, depth + 1, budget).await?;
                    entries.push((key, value));
                }
                Ok(RespValue::Map(entries))
            }
            b'~' | b'>' => {
                let length = parse_number(payload, "aggregate length")?;
                if length < 0 || length as usize > MAX_RESP_ARRAY_LENGTH {
                    return Err(format!("invalid RESP aggregate length: {length}"));
                }
                let length = length as usize;
                budget.reserve_elements(length)?;
                let mut values = Vec::with_capacity(length);
                for _ in 0..length {
                    values.push(read_value_budgeted(reader, depth + 1, budget).await?);
                }
                if prefix == b'~' {
                    Ok(RespValue::Set(values))
                } else {
                    Ok(RespValue::Push(values))
                }
            }
            _ => Err(format!("unsupported RESP response prefix: {prefix:#x}")),
        }
    })
}

fn parse_text(payload: &[u8], field: &str) -> Result<String, String> {
    std::str::from_utf8(payload)
        .map(|value| value.to_string())
        .map_err(|_| format!("RESP {field} was not valid UTF-8"))
}

fn parse_number(payload: &[u8], field: &str) -> Result<i64, String> {
    std::str::from_utf8(payload)
        .map_err(|_| format!("RESP {field} was not valid UTF-8"))?
        .parse::<i64>()
        .map_err(|error| format!("invalid RESP {field}: {error}"))
}

/// Execute a single command against `addr` on a fresh connection, bounding
/// the reply with the default cumulative response budget.
pub async fn execute(addr: &str, arguments: &[String]) -> Result<RespValue, String> {
    execute_within(addr, arguments, MAX_RESPONSE_BYTES).await
}

/// Execute a single command against `addr`, bounding the reply with an
/// explicit cumulative byte budget.
pub async fn execute_within(
    addr: &str,
    arguments: &[String],
    budget_bytes: usize,
) -> Result<RespValue, String> {
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
        let request = encode_command(arguments);
        stream
            .write_all(&request)
            .await
            .map_err(|error| format!("failed to write RESP command: {error}"))?;
        stream
            .flush()
            .await
            .map_err(|error| format!("failed to flush RESP command: {error}"))?;

        let mut reader = BufReader::new(stream);
        let mut budget = ResponseBudget::new(budget_bytes);
        read_value_budgeted(&mut reader, 0, &mut budget).await
    })
    .await
    .map_err(|_| {
        format!(
            "RESP operation timed out after {} seconds",
            RESP_TIMEOUT.as_secs()
        )
    })?
}

/// Convert a RESP value to JSON while bounding the encoded JSON value.
///
/// The budget is charged before allocating base64 or JSON container data.
/// This is required for HTTP callers: a valid RESP bulk value can be much
/// larger than the HTTP response cap, and invalid UTF-8 must not turn into an
/// array containing one JSON number per input byte.
pub fn to_json_with_budget(value: RespValue, byte_limit: usize) -> Result<Value, String> {
    let mut budget = JsonBudget::new(byte_limit);
    to_json_budgeted(value, &mut budget)
}

/// Convert a RESP value to JSON with the normal RESP response ceiling.
///
/// HTTP handlers must use [`to_json_with_budget`] with their smaller response
/// budget. Keeping this convenience API bounded prevents other callers from
/// accidentally expanding a binary bulk string into an unbounded JSON value.
pub fn to_json(value: RespValue) -> Result<Value, String> {
    to_json_with_budget(value, MAX_RESPONSE_BYTES)
}

struct JsonBudget {
    byte_limit: usize,
    bytes_used: usize,
}

impl JsonBudget {
    fn new(byte_limit: usize) -> Self {
        Self {
            byte_limit,
            bytes_used: 0,
        }
    }

    fn consume(&mut self, bytes: usize) -> Result<(), String> {
        let next = self.bytes_used.saturating_add(bytes);
        if next > self.byte_limit {
            return Err(format!(
                "JSON conversion exceeds the playground output budget of {} bytes",
                self.byte_limit
            ));
        }
        self.bytes_used = next;
        Ok(())
    }

    fn consume_json_string(&mut self, value: &str) -> Result<(), String> {
        // serde_json leaves ordinary UTF-8 bytes intact and escapes quotes,
        // backslashes, and ASCII controls. Charge the exact byte count before
        // Value::String or the serializer can allocate the output.
        let mut encoded = 2usize;
        for byte in value.bytes() {
            encoded = encoded.saturating_add(match byte {
                b'"' | b'\\' | b'\x08' | b'\t' | b'\n' | b'\x0c' | b'\r' => 2,
                0x00..=0x1f => 6,
                _ => 1,
            });
        }
        self.consume(encoded)
    }
}

fn to_json_budgeted(value: RespValue, budget: &mut JsonBudget) -> Result<Value, String> {
    match value {
        RespValue::Simple(value) => {
            budget.consume_json_string(&value)?;
            Ok(Value::String(value))
        }
        RespValue::Error(error) => Err(error),
        RespValue::Integer(value) => {
            budget.consume(value.to_string().len())?;
            Ok(json!(value))
        }
        RespValue::Bulk(None) | RespValue::Array(None) | RespValue::Null => {
            budget.consume(4)?;
            Ok(Value::Null)
        }
        RespValue::Bulk(Some(value)) => bulk_to_json(value, budget),
        RespValue::Array(Some(values)) | RespValue::Set(values) | RespValue::Push(values) => {
            values_to_json(values, budget)
        }
        RespValue::Boolean(value) => {
            budget.consume(if value { 4 } else { 5 })?;
            Ok(json!(value))
        }
        RespValue::Double(value) => Ok(match value.parse::<f64>() {
            Ok(parsed) if parsed.is_finite() => {
                budget.consume(value.len())?;
                json!(parsed)
            }
            // inf/-inf/nan have no JSON number representation.
            _ => {
                budget.consume_json_string(&value)?;
                Value::String(value)
            }
        }),
        RespValue::BigNumber(value) => {
            budget.consume_json_string(&value)?;
            Ok(Value::String(value))
        }
        RespValue::BlobError(error) => Err(String::from_utf8_lossy(&error).into_owned()),
        RespValue::Verbatim(data) => {
            let text = std::str::from_utf8(&data)
                .map_err(|_| "RESP verbatim string was not valid UTF-8".to_string())?;
            // Verbatim strings are `<3-char format>:<content>`.
            let text = match text.get(3..4) {
                Some(":") => &text[4..],
                _ => text,
            };
            budget.consume_json_string(text)?;
            Ok(Value::String(text.to_string()))
        }
        RespValue::Map(entries) => {
            budget.consume(2)?;
            let mut object = serde_json::Map::with_capacity(entries.len());
            for (index, (key, value)) in entries.into_iter().enumerate() {
                if index > 0 {
                    budget.consume(1)?;
                }
                let key = match to_json_budgeted(key, budget)? {
                    Value::String(key) => key,
                    other => serde_json::to_string(&other)
                        .map_err(|error| format!("failed to serialize RESP map key: {error}"))?,
                };
                budget.consume_json_string(&key)?;
                budget.consume(1)?;
                object.insert(key, to_json_budgeted(value, budget)?);
            }
            Ok(Value::Object(object))
        }
    }
}

fn values_to_json(values: Vec<RespValue>, budget: &mut JsonBudget) -> Result<Value, String> {
    budget.consume(2)?;
    let mut json_values = Vec::with_capacity(values.len());
    for (index, value) in values.into_iter().enumerate() {
        if index > 0 {
            budget.consume(1)?;
        }
        json_values.push(to_json_budgeted(value, budget)?);
    }
    Ok(Value::Array(json_values))
}

fn bulk_to_json(value: Vec<u8>, budget: &mut JsonBudget) -> Result<Value, String> {
    if let Ok(text) = std::str::from_utf8(&value) {
        budget.consume_json_string(text)?;
        return Ok(Value::String(
            String::from_utf8(value).expect("UTF-8 was checked"),
        ));
    }

    // The base64 alphabet has no JSON-escaped bytes. Reserve the whole
    // compact object before allocating its encoded payload.
    let encoded_length = base64_encoded_length(value.len())?;
    const PREFIX: &str = r#"{"encoding":"base64","data":""#;
    const SUFFIX: &str = r#""}"#;
    budget.consume(
        PREFIX
            .len()
            .saturating_add(encoded_length)
            .saturating_add(SUFFIX.len()),
    )?;

    let mut object = serde_json::Map::with_capacity(2);
    object.insert("encoding".to_string(), Value::String("base64".to_string()));
    object.insert("data".to_string(), Value::String(base64_encode(&value)));
    Ok(Value::Object(object))
}

fn base64_encoded_length(length: usize) -> Result<usize, String> {
    length
        .checked_add(2)
        .and_then(|value| value.checked_div(3))
        .and_then(|value| value.checked_mul(4))
        .ok_or_else(|| "binary response is too large to encode as base64".to_string())
}

fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let output_length =
        base64_encoded_length(bytes.len()).expect("slice lengths always have a base64 length");
    let mut output = String::with_capacity(output_length);

    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        output.push(ALPHABET[(first >> 2) as usize] as char);
        output.push(ALPHABET[(((first & 0x03) << 4) | (second >> 4)) as usize] as char);
        output.push(if chunk.len() > 1 {
            ALPHABET[(((second & 0x0f) << 2) | (third >> 6)) as usize] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            ALPHABET[(third & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    output
}

pub fn as_string(value: RespValue, command: &str) -> Result<String, String> {
    match value {
        RespValue::Simple(value) => Ok(value),
        RespValue::Verbatim(value) => {
            String::from_utf8(value).map_err(|_| format!("{command} returned a non-UTF-8 string"))
        }
        RespValue::Bulk(Some(value)) => {
            String::from_utf8(value).map_err(|_| format!("{command} returned a non-UTF-8 string"))
        }
        RespValue::Error(error) => Err(error),
        other => Err(format!("{command} returned unexpected response: {other:?}")),
    }
}

pub fn as_integer(value: RespValue, command: &str) -> Result<i64, String> {
    match value {
        RespValue::Integer(value) => Ok(value),
        RespValue::Error(error) => Err(error),
        other => Err(format!("{command} returned unexpected response: {other:?}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_resp_commands() {
        assert_eq!(
            encode_command(&["SET".to_string(), "key".to_string(), "value".to_string()]),
            b"*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n"
        );
    }

    #[tokio::test]
    async fn parses_and_converts_resp_values() {
        let input = b"*5\r\n+OK\r\n:42\r\n$5\r\nhello\r\n$-1\r\n*2\r\n$1\r\na\r\n$1\r\nb\r\n";
        let mut reader = BufReader::new(&input[..]);
        let value = read_value_budgeted(&mut reader, 0, &mut ResponseBudget::default())
            .await
            .unwrap();
        assert_eq!(
            to_json(value).unwrap(),
            json!(["OK", 42, "hello", null, ["a", "b"]])
        );
    }

    #[tokio::test]
    async fn re_encodes_decoded_values_byte_for_byte() {
        let input: &[u8] = b"*4\r\n+OK\r\n:-7\r\n$3\r\nabc\r\n*-1\r\n";
        let mut reader = BufReader::new(input);
        let value = read_value_budgeted(&mut reader, 0, &mut ResponseBudget::default())
            .await
            .unwrap();
        let mut out = Vec::new();
        encode_value(&value, &mut out, MAX_RESPONSE_BYTES).unwrap();
        assert_eq!(out, input);
    }

    #[test]
    fn converts_binary_bulk_values_to_compact_base64_without_data_loss() {
        assert_eq!(
            to_json(RespValue::Bulk(Some(vec![0xff, 0x00]))).unwrap(),
            json!({ "encoding": "base64", "data": "/wA=" })
        );
        assert_eq!(
            to_json(RespValue::Error("ERR failure".into())).unwrap_err(),
            "ERR failure"
        );
    }

    #[test]
    fn refuses_oversized_binary_json_before_base64_allocation() {
        let error = to_json_with_budget(RespValue::Bulk(Some(vec![0xff; 1024])), 128).unwrap_err();
        assert!(
            error.contains("JSON conversion exceeds"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn budget_bounds_the_whole_response_not_each_element() {
        // 20 individually tiny elements: no single element is anywhere near
        // the budget, but together they exceed it.
        let mut input = b"*20\r\n".to_vec();
        for _ in 0..20 {
            input.extend_from_slice(b"$8\r\nabcdefgh\r\n");
        }

        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::new(120);
        let error = read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err();
        assert!(
            error.contains("response budget"),
            "unexpected error: {error}"
        );

        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::new(4096);
        let value = read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap();
        assert!(matches!(value, RespValue::Array(Some(ref values)) if values.len() == 20));
        assert!(budget.used() > 0);
    }

    #[tokio::test]
    async fn budget_bounds_a_single_oversized_bulk_reply() {
        let payload = vec![b'z'; 4096];
        let mut input = format!("${}\r\n", payload.len()).into_bytes();
        input.extend_from_slice(&payload);
        input.extend_from_slice(b"\r\n");

        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::new(1024);
        assert!(read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err()
            .contains("response budget"));
    }

    #[tokio::test]
    async fn nested_arrays_share_one_cumulative_budget() {
        let mut input = b"*4\r\n".to_vec();
        for _ in 0..4 {
            input.extend_from_slice(b"*2\r\n$4\r\nabcd\r\n$4\r\nefgh\r\n");
        }
        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::new(60);
        assert!(read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err()
            .contains("response budget"));
    }

    #[tokio::test]
    async fn rejects_large_declared_aggregates_before_allocating_or_reading_children() {
        let input = format!("*{}\r\n", MAX_RESP_ARRAY_LENGTH + 1);
        let mut reader = BufReader::new(input.as_bytes());
        let mut budget = ResponseBudget::default();
        let error = read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err();
        assert!(error.contains("invalid RESP array length"));
        assert_eq!(budget.nodes_used(), 1);
        assert_eq!(budget.elements_used(), 0);
    }

    #[tokio::test]
    async fn decoded_element_budget_rejects_many_empty_values_from_the_header() {
        let mut input = b"*1000\r\n".to_vec();
        for _ in 0..1000 {
            input.extend_from_slice(b"$0\r\n\r\n");
        }

        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::with_limits(input.len(), 2000, 64);
        let error = read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err();
        assert!(error.contains("decoded-element budget"));
        assert_eq!(budget.nodes_used(), 1);
        assert_eq!(budget.elements_used(), 0);
    }

    #[tokio::test]
    async fn decoded_node_budget_bounds_deeply_nested_empty_aggregates() {
        let mut input = Vec::new();
        for _ in 0..32 {
            input.extend_from_slice(b"*1\r\n");
        }
        input.extend_from_slice(b"*0\r\n");

        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::with_limits(input.len(), 8, 64);
        let error = read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err();
        assert!(error.contains("decoded-node budget"));
        assert_eq!(budget.nodes_used(), 8);
        assert!(budget.elements_used() <= 8);
    }

    #[test]
    fn re_encoding_never_grows_beyond_its_output_budget() {
        let value = RespValue::Bulk(Some(vec![b'x'; 1024]));
        let mut out = Vec::new();
        let error = encode_value(&value, &mut out, 128).unwrap_err();
        assert!(error.contains("output budget"));
        assert!(out.len() <= 128);
    }

    #[tokio::test]
    async fn execute_within_applies_the_requested_budget() {
        let upstream = crate::testing::MockFerrite::start().await;
        let addr = upstream.addr();

        let error = execute_within(&addr, &["MOCKBULK".to_string(), "8192".to_string()], 1024)
            .await
            .unwrap_err();
        assert!(error.contains("response budget"), "unexpected: {error}");

        let value = execute_within(
            &addr,
            &["MOCKBULK".to_string(), "512".to_string()],
            1024 * 1024,
        )
        .await
        .unwrap();
        assert!(matches!(value, RespValue::Bulk(Some(ref data)) if data.len() == 512));
    }

    #[tokio::test]
    async fn decodes_and_re_encodes_resp3_replies_byte_for_byte() {
        // A HELLO 3 style map reply plus the remaining RESP3 types.
        let input: &[u8] =
            b"%3\r\n$5\r\nproto\r\n:3\r\n$4\r\nbool\r\n#t\r\n$3\r\nagg\r\n~2\r\n,3.25\r\n_\r\n";
        let mut reader = BufReader::new(input);
        let value = read_value_budgeted(&mut reader, 0, &mut ResponseBudget::default())
            .await
            .unwrap();

        let mut out = Vec::new();
        encode_value(&value, &mut out, MAX_RESPONSE_BYTES).unwrap();
        assert_eq!(out, input, "RESP3 replies must be forwarded unchanged");

        assert_eq!(
            to_json(value).unwrap(),
            json!({ "proto": 3, "bool": true, "agg": [3.25, null] })
        );
    }

    #[tokio::test]
    async fn decodes_resp3_verbatim_big_number_and_push_types() {
        let input: &[u8] = b">2\r\n=8\r\ntxt:done\r\n(12345678901234567890\r\n";
        let mut reader = BufReader::new(input);
        let value = read_value_budgeted(&mut reader, 0, &mut ResponseBudget::default())
            .await
            .unwrap();

        let mut out = Vec::new();
        encode_value(&value, &mut out, MAX_RESPONSE_BYTES).unwrap();
        assert_eq!(out, input);
        assert_eq!(
            to_json(value).unwrap(),
            json!(["done", "12345678901234567890"])
        );
    }

    #[tokio::test]
    async fn resp3_blob_errors_surface_as_errors() {
        let input: &[u8] = b"!11\r\nERR failure\r\n";
        let mut reader = BufReader::new(input);
        let value = read_value_budgeted(&mut reader, 0, &mut ResponseBudget::default())
            .await
            .unwrap();
        assert_eq!(to_json(value).unwrap_err(), "ERR failure");
    }

    #[tokio::test]
    async fn resp3_replies_are_charged_to_the_response_budget() {
        let mut input = b"~40\r\n".to_vec();
        for _ in 0..40 {
            input.extend_from_slice(b"$8\r\nabcdefgh\r\n");
        }
        let mut reader = BufReader::new(&input[..]);
        let mut budget = ResponseBudget::new(150);
        assert!(read_value_budgeted(&mut reader, 0, &mut budget)
            .await
            .unwrap_err()
            .contains("response budget"));
    }

    #[test]
    fn encodes_error_replies_for_refused_commands() {
        assert_eq!(encode_error("ERR nope"), b"-ERR nope\r\n");
    }
}
