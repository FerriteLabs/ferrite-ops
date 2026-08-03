//! Bounded key inspection for the HTTP API.
//!
//! Key detail never issues an unbounded collection read (`LRANGE 0 -1`,
//! `SMEMBERS`, `HGETALL`, `ZRANGE 0 -1`, unbounded `XRANGE`, or a whole-value
//! `GET`). Every type is read through a bounded range, a bounded cursor scan,
//! or a bounded count, and the response reports the collection's real total,
//! whether the returned page was truncated, and — for cursor-scanned types —
//! the cursor needed to continue.

use serde_json::{json, Value};

use crate::resp::{self, RespValue};

/// Maximum number of elements returned for a collection key in one page.
pub const PAGE_LIMIT: i64 = 100;
/// Maximum number of bytes returned for a string key in one page.
pub const STRING_PREVIEW_BYTES: i64 = 4096;
/// Cumulative response budget for one key-detail RESP command.
pub const KEY_DETAIL_RESPONSE_BYTES: usize = 1024 * 1024;
/// Cursor value that means "iteration finished" in Redis SCAN semantics.
pub const CURSOR_COMPLETE: &str = "0";

/// A validated SCAN cursor. Cursors come from untrusted query strings, so only
/// non-negative integers are accepted and forwarded to Ferrite.
pub fn validate_cursor(cursor: &str) -> Result<String, String> {
    let cursor = cursor.trim();
    if cursor.is_empty() {
        return Ok(CURSOR_COMPLETE.to_string());
    }
    if !cursor.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("cursor must be a non-negative integer".to_string());
    }
    cursor
        .parse::<u64>()
        .map(|cursor| cursor.to_string())
        .map_err(|_| "cursor must be a non-negative integer".to_string())
}

/// Read a bounded view of one key.
pub async fn detail(addr: &str, key: &str, cursor: &str) -> Result<Option<Value>, String> {
    let cursor = validate_cursor(cursor)?;
    let key_type = resp::as_string(execute(addr, &["TYPE", key]).await?, "TYPE")?;
    if key_type == "none" {
        return Ok(None);
    }

    let ttl = resp::as_integer(execute(addr, &["TTL", key]).await?, "TTL")?;
    let page = match key_type.as_str() {
        "string" => string_page(addr, key).await?,
        "list" => list_page(addr, key).await?,
        "zset" => zset_page(addr, key).await?,
        "set" => set_page(addr, key, &cursor).await?,
        "hash" => hash_page(addr, key, &cursor).await?,
        "stream" => stream_page(addr, key).await?,
        other => {
            return Err(format!(
                "unsupported RESP key type returned by Ferrite: {other}"
            ))
        }
    };

    Ok(Some(json!({
        "key": key,
        "key_type": key_type,
        "ttl": ttl,
        "length": page.total,
        "returned": page.returned,
        "limit": page.limit,
        "truncated": page.truncated,
        "cursor": page.next_cursor,
        "value": page.value
    })))
}

/// One bounded page of a key's value plus its truncation metadata.
struct Page {
    value: Value,
    /// Total size of the collection (elements) or string (bytes).
    total: i64,
    /// Number of elements (or bytes) actually returned in `value`.
    returned: i64,
    /// The bound applied to this page.
    limit: i64,
    truncated: bool,
    /// Cursor to continue a scan, or `null` for non-scanned types.
    next_cursor: Value,
}

impl Page {
    fn bounded(value: Value, total: i64, returned: i64, limit: i64) -> Self {
        Self {
            value,
            total,
            returned,
            limit,
            truncated: total > returned,
            next_cursor: Value::Null,
        }
    }
}

async fn execute(addr: &str, arguments: &[&str]) -> Result<RespValue, String> {
    let arguments: Vec<String> = arguments.iter().map(|value| value.to_string()).collect();
    resp::execute_within(addr, &arguments, KEY_DETAIL_RESPONSE_BYTES).await
}

async fn string_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["STRLEN", key]).await?, "STRLEN")?;
    // GETRANGE, never GET: a string value may be far larger than the preview.
    let end = (STRING_PREVIEW_BYTES - 1).to_string();
    let value = resp::to_json(execute(addr, &["GETRANGE", key, "0", &end]).await?)?;
    let returned = match &value {
        Value::String(value) => value.len() as i64,
        Value::Array(bytes) => bytes.len() as i64,
        _ => 0,
    };
    Ok(Page::bounded(value, total, returned, STRING_PREVIEW_BYTES))
}

async fn list_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["LLEN", key]).await?, "LLEN")?;
    let stop = (PAGE_LIMIT - 1).to_string();
    let value = resp::to_json(execute(addr, &["LRANGE", key, "0", &stop]).await?)?;
    let returned = array_len(&value);
    Ok(Page::bounded(value, total, returned, PAGE_LIMIT))
}

async fn zset_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["ZCARD", key]).await?, "ZCARD")?;
    let stop = (PAGE_LIMIT - 1).to_string();
    let value = resp::to_json(execute(addr, &["ZRANGE", key, "0", &stop, "WITHSCORES"]).await?)?;
    // WITHSCORES returns member/score pairs.
    let returned = array_len(&value) / 2;
    Ok(Page::bounded(value, total, returned, PAGE_LIMIT))
}

async fn stream_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["XLEN", key]).await?, "XLEN")?;
    let count = PAGE_LIMIT.to_string();
    let value = resp::to_json(execute(addr, &["XRANGE", key, "-", "+", "COUNT", &count]).await?)?;
    let returned = array_len(&value);
    Ok(Page::bounded(value, total, returned, PAGE_LIMIT))
}

async fn set_page(addr: &str, key: &str, cursor: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["SCARD", key]).await?, "SCARD")?;
    let count = PAGE_LIMIT.to_string();
    // SSCAN, never SMEMBERS: a set may hold far more members than one page.
    let reply = execute(addr, &["SSCAN", key, cursor, "COUNT", &count]).await?;
    let (next_cursor, elements) = scan_reply(reply, "SSCAN")?;
    let returned = array_len(&elements);
    Ok(scan_page(elements, total, returned, next_cursor))
}

async fn hash_page(addr: &str, key: &str, cursor: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["HLEN", key]).await?, "HLEN")?;
    let count = PAGE_LIMIT.to_string();
    // HSCAN, never HGETALL.
    let reply = execute(addr, &["HSCAN", key, cursor, "COUNT", &count]).await?;
    let (next_cursor, elements) = scan_reply(reply, "HSCAN")?;
    // HSCAN returns a flat field/value sequence.
    let returned = array_len(&elements) / 2;
    Ok(scan_page(elements, total, returned, next_cursor))
}

fn scan_page(value: Value, total: i64, returned: i64, next_cursor: String) -> Page {
    let complete = next_cursor == CURSOR_COMPLETE;
    Page {
        value,
        total,
        returned,
        limit: PAGE_LIMIT,
        // A scan is truncated whenever iteration has not finished, even if
        // this page happened to return every element seen so far.
        truncated: !complete,
        next_cursor: Value::String(next_cursor),
    }
}

/// Split a SCAN-family reply into its cursor and its element array.
fn scan_reply(value: RespValue, command: &str) -> Result<(String, Value), String> {
    match value {
        RespValue::Array(Some(mut parts)) if parts.len() == 2 => {
            let elements = resp::to_json(parts.pop().expect("two-element scan reply"))?;
            let cursor = resp::as_string(parts.pop().expect("two-element scan reply"), command)?;
            Ok((cursor, elements))
        }
        RespValue::Error(error) => Err(error),
        other => Err(format!("{command} returned unexpected response: {other:?}")),
    }
}

fn array_len(value: &Value) -> i64 {
    match value {
        Value::Array(values) => values.len() as i64,
        Value::Null => 0,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::MockFerrite;

    #[test]
    fn validates_untrusted_cursors() {
        assert_eq!(validate_cursor("0").unwrap(), "0");
        assert_eq!(validate_cursor(" 42 ").unwrap(), "42");
        assert_eq!(validate_cursor("").unwrap(), "0");
        assert!(validate_cursor("-1").is_err());
        assert!(validate_cursor("MATCH *").is_err());
        assert!(validate_cursor("0x10").is_err());
    }

    #[tokio::test]
    async fn missing_keys_report_no_detail() {
        let upstream = MockFerrite::start().await;
        assert!(detail(&upstream.addr(), "absent", "0")
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn strings_are_previewed_with_getrange_not_get() {
        let upstream = MockFerrite::start().await;
        let value = "s".repeat(STRING_PREVIEW_BYTES as usize + 500);
        upstream.seed_string("big-string", &value).await;

        let detail = detail(&upstream.addr(), "big-string", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail["length"], json!(value.len()));
        assert_eq!(detail["returned"], json!(STRING_PREVIEW_BYTES));
        assert_eq!(detail["truncated"], json!(true));
        assert_eq!(
            detail["value"].as_str().unwrap().len(),
            STRING_PREVIEW_BYTES as usize
        );

        let commands = upstream.received_commands().await;
        assert!(commands.contains(&"GETRANGE".to_string()));
        assert!(!commands.contains(&"GET".to_string()));
    }

    #[tokio::test]
    async fn lists_are_bounded_to_one_page_with_a_real_total() {
        let upstream = MockFerrite::start().await;
        let values: Vec<String> = (0..250).map(|index| format!("item-{index}")).collect();
        upstream.seed_list("big-list", values).await;

        let detail = detail(&upstream.addr(), "big-list", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail["length"], json!(250));
        assert_eq!(detail["returned"], json!(PAGE_LIMIT));
        assert_eq!(detail["limit"], json!(PAGE_LIMIT));
        assert_eq!(detail["truncated"], json!(true));
        assert_eq!(detail["value"].as_array().unwrap().len(), 100);
        assert_eq!(detail["cursor"], json!(null));
    }

    #[tokio::test]
    async fn sorted_sets_are_bounded_to_one_page_of_member_score_pairs() {
        let upstream = MockFerrite::start().await;
        let values: Vec<(String, String)> = (0..150)
            .map(|index| (format!("member-{index}"), index.to_string()))
            .collect();
        upstream.seed_zset("big-zset", values).await;

        let detail = detail(&upstream.addr(), "big-zset", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail["length"], json!(150));
        assert_eq!(detail["returned"], json!(PAGE_LIMIT));
        assert_eq!(detail["truncated"], json!(true));
        // 100 members plus their 100 scores.
        assert_eq!(detail["value"].as_array().unwrap().len(), 200);
    }

    #[tokio::test]
    async fn sets_are_cursor_scanned_and_expose_the_next_cursor() {
        let upstream = MockFerrite::start().await;
        let values: Vec<String> = (0..150).map(|index| format!("member-{index:03}")).collect();
        upstream.seed_set("big-set", values).await;

        let first = detail(&upstream.addr(), "big-set", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first["length"], json!(150));
        assert_eq!(first["returned"], json!(PAGE_LIMIT));
        assert_eq!(first["truncated"], json!(true));
        let cursor = first["cursor"].as_str().unwrap().to_string();
        assert_ne!(cursor, CURSOR_COMPLETE);

        let second = detail(&upstream.addr(), "big-set", &cursor)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(second["returned"], json!(50));
        assert_eq!(second["truncated"], json!(false));
        assert_eq!(second["cursor"], json!(CURSOR_COMPLETE));

        let commands = upstream.received_commands().await;
        assert!(commands.contains(&"SSCAN".to_string()));
        assert!(!commands.contains(&"SMEMBERS".to_string()));
    }

    #[tokio::test]
    async fn hashes_are_cursor_scanned_rather_than_read_whole() {
        let upstream = MockFerrite::start().await;
        let values: Vec<(String, String)> = (0..150)
            .map(|index| (format!("field-{index:03}"), format!("value-{index}")))
            .collect();
        upstream.seed_hash("big-hash", values).await;

        let first = detail(&upstream.addr(), "big-hash", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first["length"], json!(150));
        assert_eq!(first["returned"], json!(PAGE_LIMIT));
        assert_eq!(first["truncated"], json!(true));
        // A flat field/value sequence for the returned page.
        assert_eq!(first["value"].as_array().unwrap().len(), 200);

        let cursor = first["cursor"].as_str().unwrap().to_string();
        let second = detail(&upstream.addr(), "big-hash", &cursor)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(second["returned"], json!(50));
        assert_eq!(second["cursor"], json!(CURSOR_COMPLETE));

        let commands = upstream.received_commands().await;
        assert!(commands.contains(&"HSCAN".to_string()));
        assert!(!commands.contains(&"HGETALL".to_string()));
    }

    #[tokio::test]
    async fn streams_are_read_with_a_bounded_count() {
        let upstream = MockFerrite::start().await;
        let entries: Vec<(String, Vec<String>)> = (0..250)
            .map(|index| {
                (
                    format!("{index}-0"),
                    vec!["field".to_string(), format!("value-{index}")],
                )
            })
            .collect();
        upstream.seed_stream("big-stream", entries).await;

        let detail = detail(&upstream.addr(), "big-stream", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail["length"], json!(250));
        assert_eq!(detail["returned"], json!(PAGE_LIMIT));
        assert_eq!(detail["truncated"], json!(true));
        assert_eq!(detail["value"].as_array().unwrap().len(), 100);
    }

    #[tokio::test]
    async fn small_collections_are_reported_as_complete() {
        let upstream = MockFerrite::start().await;
        upstream
            .seed_list("small-list", vec!["a".into(), "b".into()])
            .await;

        let detail = detail(&upstream.addr(), "small-list", "0")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail["length"], json!(2));
        assert_eq!(detail["returned"], json!(2));
        assert_eq!(detail["truncated"], json!(false));
    }

    #[tokio::test]
    async fn invalid_cursors_are_rejected_before_reaching_ferrite() {
        let upstream = MockFerrite::start().await;
        upstream.seed_set("set", vec!["a".into()]).await;
        assert!(detail(&upstream.addr(), "set", "MATCH *").await.is_err());
        assert!(upstream.received_commands().await.is_empty());
    }
}
