//! Bounded key inspection for the HTTP API.
//!
//! Key detail never issues an unbounded collection read (`LRANGE 0 -1`,
//! `SMEMBERS`, `HGETALL`, `ZRANGE 0 -1`, unbounded `XRANGE`, or a whole-value
//! `GET`). List, sorted-set, and stream values use bounded ranges. Set and
//! hash values are deliberately omitted because Ferrite v0.4.0 does not
//! effectively bound its cursor scans; their type, TTL, and length remain
//! available.

use serde_json::{json, Value};

use crate::resp::{self, RespValue};

/// Maximum number of elements returned for a collection key in one page.
pub const PAGE_LIMIT: i64 = 100;
/// Maximum number of bytes returned for a string key in one page.
pub const STRING_PREVIEW_BYTES: i64 = 4096;
/// Cumulative response budget for one key-detail RESP command.
pub const KEY_DETAIL_RESPONSE_BYTES: usize = 1024 * 1024;
/// The maximum JSON value retained while assembling an HTTP key-detail body.
///
/// The remaining HTTP response space is reserved for key metadata and the
/// API envelope. RESP values are converted with this cap before JSON
/// serialization, so a page of binary collection values cannot grow into a
/// large intermediate JSON allocation.
pub const KEY_DETAIL_JSON_VALUE_BYTES: usize = 48 * 1024;
/// Read a bounded view of one key.
pub async fn detail(addr: &str, key: &str) -> Result<Option<Value>, String> {
    let key_type = resp::as_string(execute(addr, &["TYPE", key]).await?, "TYPE")?;
    if key_type == "none" {
        return Ok(None);
    }

    let ttl = resp::as_integer(execute(addr, &["TTL", key]).await?, "TTL")?;
    let page = match key_type.as_str() {
        "string" => string_page(addr, key).await?,
        "list" => list_page(addr, key).await?,
        "zset" => zset_page(addr, key).await?,
        "set" => omitted_page(
            resp::as_integer(execute(addr, &["SCARD", key]).await?, "SCARD")?,
            "set values are omitted because SSCAN is not effectively bounded in Ferrite v0.4.0",
        ),
        "hash" => omitted_page(
            resp::as_integer(execute(addr, &["HLEN", key]).await?, "HLEN")?,
            "hash values are omitted because HSCAN is not effectively bounded in Ferrite v0.4.0",
        ),
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
        "value": page.value,
        "value_omitted": page.value_omitted,
        "detail": page.detail
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
    /// Reserved for response compatibility; always `null`.
    next_cursor: Value,
    value_omitted: bool,
    detail: Value,
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
            value_omitted: false,
            detail: Value::String("bounded value preview".to_string()),
        }
    }
}

fn omitted_page(total: i64, reason: &str) -> Page {
    Page {
        value: Value::Null,
        total,
        returned: 0,
        limit: 0,
        truncated: total > 0,
        next_cursor: Value::Null,
        value_omitted: true,
        detail: Value::String(reason.to_string()),
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
    let response = execute(addr, &["GETRANGE", key, "0", &end]).await?;
    let returned = match &response {
        RespValue::Bulk(Some(value)) => value.len() as i64,
        RespValue::Bulk(None) => 0,
        _ => return Err("GETRANGE returned an unexpected response".to_string()),
    };
    let value = resp::to_json_with_budget(response, KEY_DETAIL_JSON_VALUE_BYTES)?;
    Ok(Page::bounded(value, total, returned, STRING_PREVIEW_BYTES))
}

async fn list_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["LLEN", key]).await?, "LLEN")?;
    let stop = (PAGE_LIMIT - 1).to_string();
    let value = resp::to_json_with_budget(
        execute(addr, &["LRANGE", key, "0", &stop]).await?,
        KEY_DETAIL_JSON_VALUE_BYTES,
    )?;
    let returned = array_len(&value);
    Ok(Page::bounded(value, total, returned, PAGE_LIMIT))
}

async fn zset_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["ZCARD", key]).await?, "ZCARD")?;
    let stop = (PAGE_LIMIT - 1).to_string();
    let value = resp::to_json_with_budget(
        execute(addr, &["ZRANGE", key, "0", &stop, "WITHSCORES"]).await?,
        KEY_DETAIL_JSON_VALUE_BYTES,
    )?;
    // WITHSCORES returns member/score pairs.
    let returned = array_len(&value) / 2;
    Ok(Page::bounded(value, total, returned, PAGE_LIMIT))
}

async fn stream_page(addr: &str, key: &str) -> Result<Page, String> {
    let total = resp::as_integer(execute(addr, &["XLEN", key]).await?, "XLEN")?;
    let count = PAGE_LIMIT.to_string();
    let value = resp::to_json_with_budget(
        execute(addr, &["XRANGE", key, "-", "+", "COUNT", &count]).await?,
        KEY_DETAIL_JSON_VALUE_BYTES,
    )?;
    let returned = array_len(&value);
    Ok(Page::bounded(value, total, returned, PAGE_LIMIT))
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

    #[tokio::test]
    async fn missing_keys_report_no_detail() {
        let upstream = MockFerrite::start().await;
        assert!(detail(&upstream.addr(), "absent").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn strings_are_previewed_with_getrange_not_get() {
        let upstream = MockFerrite::start().await;
        let value = "s".repeat(STRING_PREVIEW_BYTES as usize + 500);
        upstream.seed_string("big-string", &value).await;

        let detail = detail(&upstream.addr(), "big-string")
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

        let detail = detail(&upstream.addr(), "big-list").await.unwrap().unwrap();
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

        let detail = detail(&upstream.addr(), "big-zset").await.unwrap().unwrap();
        assert_eq!(detail["length"], json!(150));
        assert_eq!(detail["returned"], json!(PAGE_LIMIT));
        assert_eq!(detail["truncated"], json!(true));
        // 100 members plus their 100 scores.
        assert_eq!(detail["value"].as_array().unwrap().len(), 200);
    }

    #[tokio::test]
    async fn sets_report_metadata_without_scanning_values() {
        let upstream = MockFerrite::start().await;
        let values: Vec<String> = (0..150).map(|index| format!("member-{index:03}")).collect();
        upstream.seed_set("big-set", values).await;

        let detail = detail(&upstream.addr(), "big-set").await.unwrap().unwrap();
        assert_eq!(detail["length"], json!(150));
        assert_eq!(detail["returned"], json!(0));
        assert_eq!(detail["value"], json!(null));
        assert_eq!(detail["value_omitted"], json!(true));
        assert!(detail["detail"].as_str().unwrap().contains("SSCAN"));

        let commands = upstream.received_commands().await;
        assert_eq!(commands, vec!["TYPE", "TTL", "SCARD"]);
    }

    #[tokio::test]
    async fn hashes_report_metadata_without_scanning_values() {
        let upstream = MockFerrite::start().await;
        let values: Vec<(String, String)> = (0..150)
            .map(|index| (format!("field-{index:03}"), format!("value-{index}")))
            .collect();
        upstream.seed_hash("big-hash", values).await;

        let detail = detail(&upstream.addr(), "big-hash").await.unwrap().unwrap();
        assert_eq!(detail["length"], json!(150));
        assert_eq!(detail["returned"], json!(0));
        assert_eq!(detail["value"], json!(null));
        assert_eq!(detail["value_omitted"], json!(true));
        assert!(detail["detail"].as_str().unwrap().contains("HSCAN"));

        let commands = upstream.received_commands().await;
        assert_eq!(commands, vec!["TYPE", "TTL", "HLEN"]);
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

        let detail = detail(&upstream.addr(), "big-stream")
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

        let detail = detail(&upstream.addr(), "small-list")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail["length"], json!(2));
        assert_eq!(detail["returned"], json!(2));
        assert_eq!(detail["truncated"], json!(false));
    }
}
