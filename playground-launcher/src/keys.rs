//! Key inspection for the HTTP API.

use serde_json::{json, Value};

use crate::resp;

/// Read a key's type, TTL, size, and value.
pub async fn detail(addr: &str, key: &str) -> Result<Option<Value>, String> {
    let key_arg = key.to_string();
    let key_type = resp::as_string(
        resp::execute(addr, &["TYPE".to_string(), key_arg.clone()]).await?,
        "TYPE",
    )?;
    if key_type == "none" {
        return Ok(None);
    }

    let ttl = resp::as_integer(
        resp::execute(addr, &["TTL".to_string(), key_arg.clone()]).await?,
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

    let value = resp::to_json(resp::execute(addr, &value_command).await?)?;
    let length = match length_command {
        Some(command) => Some(resp::as_integer(
            resp::execute(addr, &command).await?,
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
