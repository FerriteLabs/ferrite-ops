//! Shared public-playground command policy.
//!
//! The playground is unauthenticated and shared. Commands are therefore
//! denied unless they appear in this explicit allowlist and satisfy their
//! argument-aware bounds. HTTP and RESP both call this module before any
//! request reaches Ferrite.

const MAX_MULTI_ITEMS: usize = 32;
const MAX_COLLECTION_PAGE: usize = 100;
const MAX_STRING_RANGE: u64 = 64 * 1024;
const MAX_DATABASE: u64 = 15;

type Validator = fn(&[String]) -> Result<(), String>;

struct CommandPolicy {
    names: &'static [&'static str],
    #[cfg_attr(not(test), allow(dead_code))]
    example: &'static [&'static str],
    validate: Validator,
}

const POLICIES: &[CommandPolicy] = &[
    policy(&["PING"], &["PING"], ping),
    policy(&["ECHO"], &["ECHO", "hello"], exact::<1>),
    policy(&["HELLO"], &["HELLO", "3"], hello),
    policy(&["COMMAND.COUNT"], &["COMMAND", "COUNT"], exact::<0>),
    policy(
        &["COMMAND.INFO"],
        &["COMMAND", "INFO", "GET"],
        between::<1, MAX_MULTI_ITEMS>,
    ),
    policy(&["INFO"], &["INFO"], at_most::<1>),
    policy(&["DBSIZE"], &["DBSIZE"], exact::<0>),
    policy(&["TIME"], &["TIME"], exact::<0>),
    policy(&["SELECT"], &["SELECT", "0"], select),
    policy(&["TYPE"], &["TYPE", "key"], exact::<1>),
    policy(&["TTL", "PTTL"], &["TTL", "key"], exact::<1>),
    policy(
        &["EXISTS", "DEL", "UNLINK", "TOUCH"],
        &["EXISTS", "key"],
        between::<1, MAX_MULTI_ITEMS>,
    ),
    policy(
        &["EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT"],
        &["EXPIRE", "key", "60"],
        between::<2, 3>,
    ),
    policy(&["PERSIST"], &["PERSIST", "key"], exact::<1>),
    policy(
        &["RENAME", "RENAMENX"],
        &["RENAME", "source", "destination"],
        exact::<2>,
    ),
    policy(
        &["COPY"],
        &["COPY", "source", "destination"],
        between::<2, 5>,
    ),
    policy(&["RANDOMKEY"], &["RANDOMKEY"], exact::<0>),
    policy(&["SCAN"], &["SCAN", "0", "COUNT", "100"], scan),
    policy(&["GET", "GETDEL"], &["GET", "key"], exact::<1>),
    policy(&["GETEX"], &["GETEX", "key", "EX", "60"], between::<1, 3>),
    policy(&["SET", "SETNX"], &["SET", "key", "value"], between::<2, 8>),
    policy(
        &["GETRANGE"],
        &["GETRANGE", "key", "0", "1023"],
        string_range,
    ),
    policy(&["STRLEN"], &["STRLEN", "key"], exact::<1>),
    policy(&["INCR", "DECR"], &["INCR", "counter"], exact::<1>),
    policy(
        &["INCRBY", "DECRBY", "INCRBYFLOAT"],
        &["INCRBY", "counter", "1"],
        exact::<2>,
    ),
    policy(
        &["MGET"],
        &["MGET", "key-1", "key-2"],
        between::<1, MAX_MULTI_ITEMS>,
    ),
    policy(
        &["MSET", "MSETNX"],
        &["MSET", "key-1", "value-1"],
        key_value_pairs,
    ),
    policy(
        &["GETBIT", "SETBIT"],
        &["GETBIT", "key", "0"],
        between::<2, 3>,
    ),
    policy(&["BITCOUNT"], &["BITCOUNT", "key"], between::<1, 4>),
    policy(&["BITPOS"], &["BITPOS", "key", "1"], between::<2, 5>),
    policy(&["HSET"], &["HSET", "hash", "field", "value"], hash_pairs),
    policy(
        &["HSETNX", "HINCRBY", "HINCRBYFLOAT"],
        &["HSETNX", "hash", "field", "value"],
        exact::<3>,
    ),
    policy(
        &["HGET", "HEXISTS", "HSTRLEN"],
        &["HGET", "hash", "field"],
        exact::<2>,
    ),
    policy(&["HDEL"], &["HDEL", "hash", "field"], keyed_items),
    policy(&["HMGET"], &["HMGET", "hash", "field"], keyed_items),
    policy(&["HLEN"], &["HLEN", "hash"], exact::<1>),
    policy(
        &["HRANDFIELD"],
        &["HRANDFIELD", "hash", "10"],
        random_member,
    ),
    policy(
        &["HSCAN"],
        &["HSCAN", "hash", "0", "COUNT", "100"],
        keyed_scan,
    ),
    policy(
        &["LPUSH", "LPUSHX", "RPUSH", "RPUSHX"],
        &["RPUSH", "list", "value"],
        keyed_items,
    ),
    policy(&["LPOP", "RPOP"], &["LPOP", "list", "10"], optional_count),
    policy(&["LLEN"], &["LLEN", "list"], exact::<1>),
    policy(&["LINDEX"], &["LINDEX", "list", "0"], exact::<2>),
    policy(
        &["LRANGE"],
        &["LRANGE", "list", "0", "99"],
        collection_range,
    ),
    policy(
        &["LSET", "LREM"],
        &["LSET", "list", "0", "value"],
        exact::<3>,
    ),
    policy(&["LTRIM"], &["LTRIM", "list", "0", "99"], exact::<3>),
    policy(
        &["LINSERT"],
        &["LINSERT", "list", "BEFORE", "pivot", "value"],
        exact::<4>,
    ),
    policy(
        &["LMOVE"],
        &["LMOVE", "source", "destination", "LEFT", "RIGHT"],
        exact::<4>,
    ),
    policy(
        &["RPOPLPUSH"],
        &["RPOPLPUSH", "source", "destination"],
        exact::<2>,
    ),
    policy(&["SADD", "SREM"], &["SADD", "set", "member"], keyed_items),
    policy(&["SCARD"], &["SCARD", "set"], exact::<1>),
    policy(
        &["SISMEMBER", "SMOVE"],
        &["SISMEMBER", "set", "member"],
        between::<2, 3>,
    ),
    policy(
        &["SMISMEMBER"],
        &["SMISMEMBER", "set", "member"],
        keyed_items,
    ),
    policy(&["SPOP"], &["SPOP", "set", "10"], optional_count),
    policy(
        &["SRANDMEMBER"],
        &["SRANDMEMBER", "set", "10"],
        random_member,
    ),
    policy(
        &["SSCAN"],
        &["SSCAN", "set", "0", "COUNT", "100"],
        keyed_scan,
    ),
    policy(&["ZADD"], &["ZADD", "zset", "1", "member"], zadd),
    policy(&["ZCARD"], &["ZCARD", "zset"], exact::<1>),
    policy(
        &["ZCOUNT", "ZLEXCOUNT"],
        &["ZCOUNT", "zset", "-inf", "+inf"],
        exact::<3>,
    ),
    policy(
        &["ZINCRBY"],
        &["ZINCRBY", "zset", "1", "member"],
        exact::<3>,
    ),
    policy(
        &["ZSCORE", "ZRANK", "ZREVRANK"],
        &["ZSCORE", "zset", "member"],
        between::<2, 3>,
    ),
    policy(
        &["ZMSCORE", "ZREM"],
        &["ZMSCORE", "zset", "member"],
        keyed_items,
    ),
    policy(
        &["ZREMRANGEBYLEX", "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE"],
        &["ZREMRANGEBYRANK", "zset", "0", "99"],
        exact::<3>,
    ),
    policy(
        &["ZRANGE", "ZREVRANGE"],
        &["ZRANGE", "zset", "0", "99"],
        sorted_collection_range,
    ),
    policy(
        &[
            "ZRANGEBYLEX",
            "ZRANGEBYSCORE",
            "ZREVRANGEBYLEX",
            "ZREVRANGEBYSCORE",
        ],
        &["ZRANGEBYSCORE", "zset", "-inf", "+inf", "LIMIT", "0", "100"],
        limited_sorted_range,
    ),
    policy(
        &["ZPOPMAX", "ZPOPMIN"],
        &["ZPOPMIN", "zset", "10"],
        optional_count,
    ),
    policy(
        &["ZRANDMEMBER"],
        &["ZRANDMEMBER", "zset", "10"],
        random_member,
    ),
    policy(
        &["ZSCAN"],
        &["ZSCAN", "zset", "0", "COUNT", "100"],
        keyed_scan,
    ),
    policy(&["XADD"], &["XADD", "stream", "*", "field", "value"], xadd),
    policy(&["XDEL"], &["XDEL", "stream", "1-0"], keyed_items),
    policy(&["XLEN"], &["XLEN", "stream"], exact::<1>),
    policy(
        &["XRANGE", "XREVRANGE"],
        &["XRANGE", "stream", "-", "+", "COUNT", "100"],
        stream_range,
    ),
    policy(
        &["XREAD"],
        &["XREAD", "COUNT", "100", "STREAMS", "stream", "0-0"],
        stream_read,
    ),
    policy(
        &["XTRIM"],
        &["XTRIM", "stream", "MAXLEN", "100"],
        between::<3, 7>,
    ),
    policy(&["PFADD"], &["PFADD", "hll", "element"], keyed_items),
    policy(
        &["PFCOUNT"],
        &["PFCOUNT", "hll"],
        between::<1, MAX_MULTI_ITEMS>,
    ),
    policy(
        &["PFMERGE"],
        &["PFMERGE", "destination", "source"],
        keyed_items,
    ),
];

const fn policy(
    names: &'static [&'static str],
    example: &'static [&'static str],
    validate: Validator,
) -> CommandPolicy {
    CommandPolicy {
        names,
        example,
        validate,
    }
}

/// Outcome of classifying one parsed command.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Reject { command: String, reason: String },
}

impl Decision {
    pub fn is_allowed(&self) -> bool {
        matches!(self, Decision::Allow)
    }

    pub fn message(&self) -> String {
        match self {
            Decision::Allow => String::new(),
            Decision::Reject { command, reason } => format!(
                "ERR {command} is not permitted by the Ferrite public playground policy: {reason}"
            ),
        }
    }
}

/// Classify a fully parsed textual argv.
pub fn classify_arguments<S: AsRef<str>>(arguments: &[S]) -> Decision {
    let normalized = arguments
        .iter()
        .map(|argument| normalize(argument.as_ref()))
        .collect::<Vec<_>>();
    classify_normalized(&normalized)
}

/// Classify a fully parsed binary argv received on the public RESP port.
pub fn classify_bytes_arguments(arguments: &[Vec<u8>]) -> Decision {
    let Some(command) = arguments.first() else {
        return classify_normalized(&[]);
    };
    let command = match std::str::from_utf8(command) {
        Ok(command) => normalize(command),
        Err(_) => {
            return Decision::Reject {
                command: "<NON-UTF8>".to_string(),
                reason: "command names must be valid UTF-8".to_string(),
            }
        }
    };

    // Redis keys and values are binary-safe. Only the command name must be
    // valid UTF-8; opaque arguments use a lossy policy view while their
    // original bytes are forwarded unchanged after validation.
    let mut normalized = Vec::with_capacity(arguments.len());
    normalized.push(command);
    normalized.extend(
        arguments[1..]
            .iter()
            .map(|argument| normalize(&String::from_utf8_lossy(argument))),
    );
    classify_normalized(&normalized)
}

fn classify_normalized(arguments: &[String]) -> Decision {
    let Some((name, policy_arguments)) = normalized_name_and_arguments(arguments) else {
        return Decision::Reject {
            command: "<EMPTY>".to_string(),
            reason: "empty commands are not allowed".to_string(),
        };
    };

    let Some(policy) = POLICIES
        .iter()
        .find(|policy| policy.names.contains(&name.as_str()))
    else {
        return Decision::Reject {
            command: name,
            reason: "the command is not on the explicit safe-command allowlist".to_string(),
        };
    };

    match (policy.validate)(policy_arguments) {
        Ok(()) => Decision::Allow,
        Err(reason) => Decision::Reject {
            command: name,
            reason,
        },
    }
}

/// Normalize dotted and root/subcommand spellings for allowlisted command
/// namespaces. Unknown namespaces are still rejected by default.
fn normalized_name_and_arguments(arguments: &[String]) -> Option<(String, &[String])> {
    let first = arguments.first()?.as_str();
    if first.contains('.') {
        return Some((first.to_string(), &arguments[1..]));
    }

    if first == "COMMAND" {
        return arguments
            .get(1)
            .map(|subcommand| (format!("{first}.{subcommand}"), &arguments[2..]));
    }

    Some((first.to_string(), &arguments[1..]))
}

fn normalize(value: &str) -> String {
    value.trim().to_ascii_uppercase()
}

fn exact<const N: usize>(arguments: &[String]) -> Result<(), String> {
    if arguments.len() == N {
        Ok(())
    } else {
        Err(format!("expected exactly {N} argument(s)"))
    }
}

fn at_most<const MAX: usize>(arguments: &[String]) -> Result<(), String> {
    if arguments.len() <= MAX {
        Ok(())
    } else {
        Err(format!("accepts at most {MAX} argument(s)"))
    }
}

fn between<const MIN: usize, const MAX: usize>(arguments: &[String]) -> Result<(), String> {
    if (MIN..=MAX).contains(&arguments.len()) {
        Ok(())
    } else {
        Err(format!("requires between {MIN} and {MAX} argument(s)"))
    }
}

fn ping(arguments: &[String]) -> Result<(), String> {
    at_most::<1>(arguments)
}

fn hello(arguments: &[String]) -> Result<(), String> {
    exact::<1>(arguments)?;
    match arguments[0].as_str() {
        "2" | "3" => Ok(()),
        _ => Err("only RESP protocol versions 2 and 3 are allowed".to_string()),
    }
}

fn select(arguments: &[String]) -> Result<(), String> {
    exact::<1>(arguments)?;
    let database = parse_u64(&arguments[0], "database number")?;
    if database <= MAX_DATABASE {
        Ok(())
    } else {
        Err(format!("database number must be at most {MAX_DATABASE}"))
    }
}

fn key_value_pairs(arguments: &[String]) -> Result<(), String> {
    if arguments.is_empty()
        || !arguments.len().is_multiple_of(2)
        || arguments.len() / 2 > MAX_MULTI_ITEMS
    {
        return Err(format!(
            "requires key/value pairs for at most {MAX_MULTI_ITEMS} keys"
        ));
    }
    Ok(())
}

fn hash_pairs(arguments: &[String]) -> Result<(), String> {
    if arguments.len() < 3
        || !(arguments.len() - 1).is_multiple_of(2)
        || (arguments.len() - 1) / 2 > MAX_MULTI_ITEMS
    {
        return Err(format!(
            "requires a key and field/value pairs for at most {MAX_MULTI_ITEMS} fields"
        ));
    }
    Ok(())
}

fn keyed_items(arguments: &[String]) -> Result<(), String> {
    if (2..=MAX_MULTI_ITEMS + 1).contains(&arguments.len()) {
        Ok(())
    } else {
        Err(format!(
            "requires a key and between 1 and {MAX_MULTI_ITEMS} item(s)"
        ))
    }
}

fn optional_count(arguments: &[String]) -> Result<(), String> {
    between::<1, 2>(arguments)?;
    if let Some(count) = arguments.get(1) {
        bounded_positive_count(count)?;
    }
    Ok(())
}

fn random_member(arguments: &[String]) -> Result<(), String> {
    between::<1, 3>(arguments)?;
    if let Some(count) = arguments.get(1) {
        let count = parse_i64(count, "count")?;
        if count == 0 || count.unsigned_abs() > MAX_COLLECTION_PAGE as u64 {
            return Err(format!(
                "absolute COUNT must be between 1 and {MAX_COLLECTION_PAGE}"
            ));
        }
    }
    if arguments.len() == 3 && arguments[2] != "WITHSCORES" && arguments[2] != "WITHVALUES" {
        return Err("the only permitted third argument is WITHSCORES or WITHVALUES".to_string());
    }
    Ok(())
}

fn string_range(arguments: &[String]) -> Result<(), String> {
    exact::<3>(arguments)?;
    bounded_range(&arguments[1], &arguments[2], MAX_STRING_RANGE, "byte range")
}

fn collection_range(arguments: &[String]) -> Result<(), String> {
    exact::<3>(arguments)?;
    bounded_range(
        &arguments[1],
        &arguments[2],
        MAX_COLLECTION_PAGE as u64,
        "range window",
    )
}

fn sorted_collection_range(arguments: &[String]) -> Result<(), String> {
    between::<3, 4>(arguments)?;
    if arguments.len() == 4 && arguments[3] != "WITHSCORES" {
        return Err("only the optional WITHSCORES modifier is permitted".to_string());
    }
    bounded_range(
        &arguments[1],
        &arguments[2],
        MAX_COLLECTION_PAGE as u64,
        "range window",
    )
}

fn bounded_range(start: &str, stop: &str, limit: u64, label: &str) -> Result<(), String> {
    let start = parse_i64(start, "range start")?;
    let stop = parse_i64(stop, "range stop")?;

    if start.signum() != stop.signum() && start != 0 && stop != 0 {
        return Err(format!(
            "{label} must use two non-negative or two non-positive indexes"
        ));
    }
    if start >= 0 && stop < 0 {
        return Err(format!("{label} is unbounded"));
    }
    if stop < start {
        return Ok(());
    }

    let width = stop
        .checked_sub(start)
        .and_then(|difference| difference.checked_add(1))
        .map(|value| value as u64)
        .ok_or_else(|| format!("{label} is invalid"))?;
    if width > limit {
        return Err(format!("{label} must contain at most {limit} elements"));
    }
    Ok(())
}

fn scan(arguments: &[String]) -> Result<(), String> {
    if !(3..=7).contains(&arguments.len()) {
        return Err(format!(
            "COUNT is required and must be at most {MAX_COLLECTION_PAGE}"
        ));
    }
    validate_scan_options(&arguments[1..])
}

fn keyed_scan(arguments: &[String]) -> Result<(), String> {
    if !(4..=8).contains(&arguments.len()) {
        return Err(format!(
            "COUNT is required and must be at most {MAX_COLLECTION_PAGE}"
        ));
    }
    validate_scan_options(&arguments[2..])
}

fn validate_scan_options(options: &[String]) -> Result<(), String> {
    let count = unique_option_value(options, "COUNT")?
        .ok_or_else(|| format!("COUNT is required and must be at most {MAX_COLLECTION_PAGE}"))?;
    bounded_positive_count(count)
}

fn limited_sorted_range(arguments: &[String]) -> Result<(), String> {
    between::<6, 7>(arguments)?;
    let limit_index = arguments
        .iter()
        .position(|argument| argument == "LIMIT")
        .ok_or_else(|| {
            format!("LIMIT is required with a count of at most {MAX_COLLECTION_PAGE}")
        })?;
    let offset = arguments
        .get(limit_index + 1)
        .ok_or_else(|| "LIMIT requires an offset and count".to_string())?;
    parse_u64(offset, "LIMIT offset")?;
    let count = arguments
        .get(limit_index + 2)
        .ok_or_else(|| "LIMIT requires an offset and count".to_string())?;
    bounded_positive_count(count)
}

fn zadd(arguments: &[String]) -> Result<(), String> {
    between::<3, 72>(arguments)?;
    if arguments.len() > 1 + MAX_MULTI_ITEMS * 2 + 7 {
        return Err(format!("at most {MAX_MULTI_ITEMS} members may be added"));
    }
    Ok(())
}

fn xadd(arguments: &[String]) -> Result<(), String> {
    between::<4, 72>(arguments)?;
    if arguments.len() > 1 + MAX_MULTI_ITEMS * 2 + 7 {
        return Err(format!(
            "at most {MAX_MULTI_ITEMS} field/value pairs may be added"
        ));
    }
    Ok(())
}

fn stream_range(arguments: &[String]) -> Result<(), String> {
    if arguments.len() != 5 {
        return Err(format!(
            "COUNT is required and must be at most {MAX_COLLECTION_PAGE}"
        ));
    }
    if arguments[3] != "COUNT" {
        return Err(format!(
            "COUNT is required and must be at most {MAX_COLLECTION_PAGE}"
        ));
    }
    bounded_positive_count(&arguments[4])
}

fn stream_read(arguments: &[String]) -> Result<(), String> {
    if arguments.iter().any(|argument| argument == "BLOCK") {
        return Err("blocking reads are not permitted".to_string());
    }
    let count = unique_option_value(arguments, "COUNT")?
        .ok_or_else(|| format!("COUNT is required and must be at most {MAX_COLLECTION_PAGE}"))?;
    bounded_positive_count(count)?;

    let streams = arguments
        .iter()
        .position(|argument| argument == "STREAMS")
        .ok_or_else(|| "STREAMS is required".to_string())?;
    let tail = arguments.len().saturating_sub(streams + 1);
    if tail < 2 || !tail.is_multiple_of(2) || tail / 2 > MAX_MULTI_ITEMS {
        return Err(format!(
            "requires matching key/id pairs for at most {MAX_MULTI_ITEMS} streams"
        ));
    }
    Ok(())
}

fn unique_option_value<'a>(
    arguments: &'a [String],
    option: &str,
) -> Result<Option<&'a str>, String> {
    let matches = arguments
        .iter()
        .enumerate()
        .filter_map(|(index, argument)| (argument == option).then_some(index))
        .collect::<Vec<_>>();
    if matches.len() > 1 {
        return Err(format!("{option} may be specified only once"));
    }
    Ok(matches
        .first()
        .and_then(|index| arguments.get(index + 1))
        .map(String::as_str))
}

fn bounded_positive_count(value: &str) -> Result<(), String> {
    let count = parse_u64(value, "COUNT")?;
    if (1..=MAX_COLLECTION_PAGE as u64).contains(&count) {
        Ok(())
    } else {
        Err(format!("COUNT must be between 1 and {MAX_COLLECTION_PAGE}"))
    }
}

fn parse_i64(value: &str, label: &str) -> Result<i64, String> {
    value
        .parse::<i64>()
        .map_err(|_| format!("{label} must be an integer"))
}

fn parse_u64(value: &str, label: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|_| format!("{label} must be a non-negative integer"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_allowed(arguments: &[&str]) {
        assert_eq!(
            classify_arguments(arguments),
            Decision::Allow,
            "{arguments:?} should be allowed"
        );
    }

    fn assert_rejected(arguments: &[&str], reason: &str) {
        let decision = classify_arguments(arguments);
        assert!(
            !decision.is_allowed(),
            "{arguments:?} should have been rejected"
        );
        assert!(
            decision.message().contains(reason),
            "{arguments:?} rejection {:?} should contain {reason:?}",
            decision.message()
        );
    }

    #[test]
    fn every_allowlisted_policy_has_a_working_example() {
        for policy in POLICIES {
            assert_allowed(policy.example);
        }
    }

    #[test]
    fn allows_safe_bounded_data_and_introspection_commands() {
        for arguments in [
            &["PING"][..],
            &["ECHO", "hello"],
            &["HELLO", "3"],
            &["COMMAND", "COUNT"],
            &["COMMAND.INFO", "GET", "SET"],
            &["INFO", "SERVER"],
            &["SET", "key", "value"],
            &["GET", "key"],
            &["MGET", "one", "two"],
            &["HSET", "hash", "field", "value"],
            &["HMGET", "hash", "one", "two"],
            &["LRANGE", "list", "0", "99"],
            &["LRANGE", "list", "-100", "-1"],
            &["SSCAN", "set", "0", "COUNT", "100"],
            &["ZRANGE", "zset", "0", "99", "WITHSCORES"],
            &["ZSCAN", "zset", "0", "MATCH", "*", "COUNT", "50"],
            &["XRANGE", "stream", "-", "+", "COUNT", "100"],
            &["XREVRANGE", "stream", "+", "-", "COUNT", "1"],
            &["XREAD", "COUNT", "10", "STREAMS", "events", "0-0"],
        ] {
            assert_allowed(arguments);
        }
    }

    #[test]
    fn rejects_every_command_not_explicitly_allowlisted() {
        for arguments in [
            &["PLUGIN", "LIST"][..],
            &["AUDIT", "START"],
            &["SHUTDOWN"],
            &["CONFIG", "SET", "appendonly", "yes"],
            &["EVAL", "return 1", "0"],
            &["HGETALL", "hash"],
            &["HKEYS", "hash"],
            &["HVALS", "hash"],
            &["SMEMBERS", "set"],
            &["KEYS", "*"],
            &["SUBSCRIBE", "channel"],
            &["MULTI"],
            &["MOCKARRAY", "10", "10"],
        ] {
            assert_rejected(arguments, "explicit safe-command allowlist");
        }
    }

    #[test]
    fn applies_root_subcommand_and_dotted_normalization_consistently() {
        for arguments in [
            &["COMMAND", "COUNT"][..],
            &["command.count"],
            &["COMMAND", "INFO", "GET"],
            &["command.info", "get"],
        ] {
            assert_allowed(arguments);
        }

        for arguments in [
            &["MIGRATE", "START", "redis://example.invalid"][..],
            &["migrate.start", "redis://example.invalid"],
            &["PLUGIN", "LOAD", "example"],
            &["plugin.load", "example"],
            &["AUDIT", "START"],
            &["audit.start"],
        ] {
            assert_rejected(arguments, "explicit safe-command allowlist");
        }
    }

    #[test]
    fn rejects_unbounded_or_oversized_ranges() {
        for arguments in [
            &["LRANGE", "list", "0", "-1"][..],
            &["LRANGE", "list", "0", "100"],
            &["LRANGE", "list", "-101", "-1"],
            &["ZRANGE", "zset", "0", "-1"],
            &["ZREVRANGE", "zset", "0", "100"],
            &["GETRANGE", "value", "0", "65536"],
        ] {
            assert_rejected(arguments, "range");
        }
    }

    #[test]
    fn requires_bounded_stream_and_scan_counts() {
        for arguments in [
            &["XRANGE", "stream", "-", "+"][..],
            &["XRANGE", "stream", "-", "+", "COUNT", "101"],
            &["XREVRANGE", "stream", "+", "-", "COUNT", "0"],
            &["SCAN", "0"],
            &["SCAN", "0", "COUNT", "101"],
            &["HSCAN", "hash", "0", "MATCH", "*"],
            &["SSCAN", "set", "0", "COUNT", "0"],
            &["ZSCAN", "zset", "0", "COUNT", "1000"],
            &["XREAD", "STREAMS", "stream", "0-0"],
            &[
                "XREAD", "COUNT", "10", "BLOCK", "1000", "STREAMS", "stream", "0-0",
            ],
        ] {
            assert_rejected(
                arguments,
                if arguments.contains(&"BLOCK") {
                    "blocking"
                } else {
                    "COUNT"
                },
            );
        }
    }

    #[test]
    fn bounds_multi_item_commands() {
        let mut mget = vec!["MGET"];
        mget.extend(std::iter::repeat_n("key", MAX_MULTI_ITEMS + 1));
        assert_rejected(&mget, &MAX_MULTI_ITEMS.to_string());

        let mut hmget = vec!["HMGET", "hash"];
        hmget.extend(std::iter::repeat_n("field", MAX_MULTI_ITEMS + 1));
        assert_rejected(&hmget, &MAX_MULTI_ITEMS.to_string());

        let mut mset = vec!["MSET"];
        for _ in 0..=MAX_MULTI_ITEMS {
            mset.extend(["key", "value"]);
        }
        assert_rejected(&mset, &MAX_MULTI_ITEMS.to_string());
    }

    #[test]
    fn binary_policy_matches_text_policy_and_preserves_binary_safe_data() {
        let arguments = vec![
            b"XRANGE".to_vec(),
            b"stream".to_vec(),
            b"-".to_vec(),
            b"+".to_vec(),
        ];
        assert_eq!(
            classify_bytes_arguments(&arguments),
            classify_arguments(&["XRANGE", "stream", "-", "+"])
        );
        assert_rejected_bytes(&[vec![0xff, 0xfe]], "command names must be valid UTF-8");
        assert_eq!(
            classify_bytes_arguments(&[b"SET".to_vec(), vec![0xff, 0xfe], vec![0x80, 0x81],]),
            Decision::Allow
        );
    }

    #[test]
    fn duplicate_count_options_cannot_bypass_bounds() {
        for arguments in [
            &["SCAN", "0", "COUNT", "10", "COUNT", "1000000"][..],
            &[
                "XREAD", "COUNT", "10", "COUNT", "1000000", "STREAMS", "stream", "0-0",
            ],
        ] {
            assert_rejected(arguments, "only once");
        }
    }

    fn assert_rejected_bytes(arguments: &[Vec<u8>], reason: &str) {
        let decision = classify_bytes_arguments(arguments);
        assert!(!decision.is_allowed());
        assert!(decision.message().contains(reason));
    }

    #[test]
    fn rejection_messages_name_the_policy_and_reason() {
        let message = classify_arguments(&["SHUTDOWN"]).message();
        assert!(message.contains("SHUTDOWN"));
        assert!(message.contains("public playground policy"));
        assert!(classify_arguments(&["LRANGE", "list", "0", "-1"])
            .message()
            .contains("unbounded"));
    }
}
