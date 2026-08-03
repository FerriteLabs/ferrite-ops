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
pub const MAX_RESP_ARRAY_LENGTH: usize = 1_000_000;
/// Upper bound on reply nesting.
pub const MAX_RESP_DEPTH: usize = 64;
/// Maximum number of arguments accepted in one command.
pub const MAX_ARGUMENTS: usize = 256;
/// Time bound for a full connect/write/read cycle against the Ferrite child.
pub const RESP_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, PartialEq, Clone)]
pub enum RespValue {
    Simple(String),
    Error(String),
    Integer(i64),
    Bulk(Option<Vec<u8>>),
    Array(Option<Vec<RespValue>>),
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

/// Serialize a decoded value back onto the wire, byte-for-byte equivalent to
/// what the Ferrite child produced.
pub fn encode_value(value: &RespValue, out: &mut Vec<u8>) {
    match value {
        RespValue::Simple(value) => {
            out.push(b'+');
            out.extend_from_slice(value.as_bytes());
            out.extend_from_slice(b"\r\n");
        }
        RespValue::Error(error) => {
            out.push(b'-');
            out.extend_from_slice(error.as_bytes());
            out.extend_from_slice(b"\r\n");
        }
        RespValue::Integer(value) => {
            out.extend_from_slice(format!(":{value}\r\n").as_bytes());
        }
        RespValue::Bulk(None) => out.extend_from_slice(b"$-1\r\n"),
        RespValue::Bulk(Some(data)) => {
            out.extend_from_slice(format!("${}\r\n", data.len()).as_bytes());
            out.extend_from_slice(data);
            out.extend_from_slice(b"\r\n");
        }
        RespValue::Array(None) => out.extend_from_slice(b"*-1\r\n"),
        RespValue::Array(Some(values)) => {
            out.extend_from_slice(format!("*{}\r\n", values.len()).as_bytes());
            for value in values {
                encode_value(value, out);
            }
        }
    }
}

/// Encode an error reply for a command the playground refuses to forward.
pub fn encode_error(message: &str) -> Vec<u8> {
    let mut out = Vec::new();
    encode_value(&RespValue::Error(message.to_string()), &mut out);
    out
}

pub fn read_value<'a, R>(
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
            b':' => Ok(RespValue::Integer(parse_number(payload, "integer")?)),
            b'$' => {
                let length = parse_number(payload, "bulk length")?;
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
                let length = parse_number(payload, "array length")?;
                if length == -1 {
                    return Ok(RespValue::Array(None));
                }
                if length < -1 || length as usize > MAX_RESP_ARRAY_LENGTH {
                    return Err(format!("invalid RESP array length: {length}"));
                }

                let mut values = Vec::with_capacity(std::cmp::min(length as usize, 1024));
                for _ in 0..length {
                    values.push(read_value(reader, depth + 1).await?);
                }
                Ok(RespValue::Array(Some(values)))
            }
            _ => Err(format!("unsupported RESP response prefix: {prefix:#x}")),
        }
    })
}

fn parse_number(payload: &[u8], field: &str) -> Result<i64, String> {
    std::str::from_utf8(payload)
        .map_err(|_| format!("RESP {field} was not valid UTF-8"))?
        .parse::<i64>()
        .map_err(|error| format!("invalid RESP {field}: {error}"))
}

/// Execute a single command against `addr` on a fresh connection.
pub async fn execute(addr: &str, arguments: &[String]) -> Result<RespValue, String> {
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
        read_value(&mut reader, 0).await
    })
    .await
    .map_err(|_| {
        format!(
            "RESP operation timed out after {} seconds",
            RESP_TIMEOUT.as_secs()
        )
    })?
}

pub fn to_json(value: RespValue) -> Result<Value, String> {
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
            .map(to_json)
            .collect::<Result<Vec<_>, _>>()
            .map(Value::Array),
    }
}

pub fn as_string(value: RespValue, command: &str) -> Result<String, String> {
    match value {
        RespValue::Simple(value) => Ok(value),
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
        let value = read_value(&mut reader, 0).await.unwrap();
        assert_eq!(
            to_json(value).unwrap(),
            json!(["OK", 42, "hello", null, ["a", "b"]])
        );
    }

    #[tokio::test]
    async fn re_encodes_decoded_values_byte_for_byte() {
        let input: &[u8] = b"*4\r\n+OK\r\n:-7\r\n$3\r\nabc\r\n*-1\r\n";
        let mut reader = BufReader::new(input);
        let value = read_value(&mut reader, 0).await.unwrap();
        let mut out = Vec::new();
        encode_value(&value, &mut out);
        assert_eq!(out, input);
    }

    #[test]
    fn converts_binary_bulk_values_without_data_loss() {
        assert_eq!(
            to_json(RespValue::Bulk(Some(vec![0xff, 0x00]))).unwrap(),
            json!([255, 0])
        );
        assert_eq!(
            to_json(RespValue::Error("ERR failure".into())).unwrap_err(),
            "ERR failure"
        );
    }

    #[test]
    fn encodes_error_replies_for_refused_commands() {
        assert_eq!(encode_error("ERR nope"), b"-ERR nope\r\n");
    }
}
