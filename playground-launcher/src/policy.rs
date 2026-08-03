//! Shared playground command policy.
//!
//! The playground is an unauthenticated, publicly reachable, shared Ferrite
//! instance. Every command that reaches Ferrite — whether it arrives on the
//! public RESP port or through the HTTP API — is classified here, so both
//! entry points enforce exactly the same rules. Ordinary Redis-compatible
//! data commands stay allowed; administrative/lifecycle commands and commands
//! that cannot be served by a bounded request/response proxy are rejected
//! before they are forwarded to the Ferrite child.

/// Exact privileged commands that can stop, reconfigure, replicate, destroy,
/// or otherwise administer the shared playground instance.
const ADMINISTRATIVE_COMMANDS: &[&str] = &[
    "BGREWRITEAOF",
    "BGSAVE",
    "FAILOVER",
    "FLUSHALL",
    "FLUSHDB",
    "LATENCY",
    "MONITOR",
    "PFDEBUG",
    "PFSELFTEST",
    "PSYNC",
    "REPLCONF",
    "REPLICAOF",
    "RESET",
    "RESTORE",
    "SAVE",
    "SHUTDOWN",
    "SLAVEOF",
    "SLOWLOG",
    "SWAPDB",
    "SYNC",
];

/// Privileged or externally connected Ferrite command families.
///
/// Ferrite v0.4.0 accepts a mixture of `FAMILY.SUBCOMMAND` and
/// `FAMILY SUBCOMMAND` forms. A family matches only its exact root or a dotted
/// descendant, so a command such as `MIGRATEX` is not accidentally rejected.
const ADMINISTRATIVE_FAMILIES: &[&str] = &[
    "ACL",
    "ADMIN",
    "AGENT",
    "BRANCH",
    "BUDGET",
    "CDC",
    "CHAOS",
    "CLIENT",
    "CLUSTER",
    "CLOUD",
    "CONFIG",
    "CONSENSUS",
    "DEBUG",
    "EBPF",
    "EDGE",
    "EVAL",
    "EVALSHA",
    "EVALSHA_RO",
    "EVAL_RO",
    "FAAS",
    "FCALL",
    "FCALL_RO",
    "FEDERATE",
    "FEDERATION",
    "FERRITE.ADVISOR",
    "FERRITE.DEBUG",
    "FN",
    "FUNCTION",
    "GATEWAY",
    "INFERENCE",
    "MARKETPLACE",
    "MEMORY",
    "MESH",
    "MIGRATE",
    "MULTICLOUD",
    "MODULE",
    "OBSERVE",
    "OPTIMIZER",
    "PANGEA",
    "PIPELINE",
    "PNG",
    "POLICY",
    "POLICYENGINE",
    "PROTOCOL",
    "PROXY",
    "RAG",
    "REGION",
    "REPLICATE",
    "S3",
    "SCALING",
    "SCRIPT",
    "SEMANTIC.CONFIG",
    "STREAM",
    "TENANT",
    "TIERING",
    "TRIGGER",
    "VIEW",
    "WASM",
];

/// Commands that never produce exactly one bounded reply on a request/response
/// connection: they either block until another client acts or switch the
/// connection into a server-push mode. Commands that deliberately enumerate or
/// sort an entire data set are also refused; cursor/range alternatives remain
/// available. The playground proxies one command to one reply, so these are
/// refused with a distinct, non-security message.
const UNSUPPORTED_COMMANDS: &[&str] = &[
    "BLMOVE",
    "BLMPOP",
    "BLPOP",
    "BRPOP",
    "BRPOPLPUSH",
    "BZMPOP",
    "BZPOPMAX",
    "BZPOPMIN",
    "HGETALL",
    "HKEYS",
    "HVALS",
    "KEYS",
    "PSUBSCRIBE",
    "PUNSUBSCRIBE",
    "SDIFF",
    "SINTER",
    "SMEMBERS",
    "SORT",
    "SORT_RO",
    "SSUBSCRIBE",
    "SUBSCRIBE",
    "SUNION",
    "SUNSUBSCRIBE",
    "UNSUBSCRIBE",
    "WAIT",
    "WAITAOF",
];

/// Outcome of classifying a single command.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Rejected because the command administers the shared playground.
    Administrative(String),
    /// Rejected because the playground proxy cannot serve its reply shape.
    Unsupported(String),
}

impl Decision {
    pub fn is_allowed(&self) -> bool {
        matches!(self, Decision::Allow)
    }

    /// RESP/HTTP error text for a rejected command (empty when allowed).
    pub fn message(&self) -> String {
        match self {
            Decision::Allow => String::new(),
            Decision::Administrative(name) => format!(
                "ERR {name} is an administrative command and is disabled in the Ferrite playground"
            ),
            Decision::Unsupported(name) => format!(
                "ERR {name} is not supported by the Ferrite playground because it does not return a single bounded reply"
            ),
        }
    }
}

/// Classify a command by its name. `name` is the first argument of the
/// command as sent by the client; matching is case-insensitive, exactly like
/// Redis command dispatch.
pub fn classify(name: &str) -> Decision {
    classify_normalized(normalize(name))
}

fn classify_normalized(normalized: String) -> Decision {
    if normalized.is_empty() {
        return Decision::Allow;
    }
    if ADMINISTRATIVE_COMMANDS.contains(&normalized.as_str())
        || ADMINISTRATIVE_FAMILIES
            .iter()
            .any(|family| matches_family(&normalized, family))
    {
        return Decision::Administrative(normalized);
    }
    if UNSUPPORTED_COMMANDS.contains(&normalized.as_str()) {
        return Decision::Unsupported(normalized);
    }
    Decision::Allow
}

/// Classify a fully parsed command (argv form). Empty commands are rejected
/// by the callers' own parsing, so an empty argv is treated as allowed here.
pub fn classify_arguments<S: AsRef<str>>(arguments: &[S]) -> Decision {
    let normalized: Vec<String> = arguments
        .iter()
        .map(|argument| normalize(argument.as_ref()))
        .collect();
    classify_normalized_arguments(&normalized)
}

/// Classify a fully parsed binary argv received on the public RESP port.
pub fn classify_bytes_arguments(arguments: &[Vec<u8>]) -> Decision {
    let normalized = arguments
        .iter()
        .map(|argument| {
            std::str::from_utf8(argument)
                .map(normalize)
                .unwrap_or_default()
        })
        .collect::<Vec<_>>();
    classify_normalized_arguments(&normalized)
}

fn classify_normalized_arguments(arguments: &[String]) -> Decision {
    let Some(name) = arguments.first() else {
        return Decision::Allow;
    };

    let decision = classify(name);
    if !decision.is_allowed() {
        return decision;
    }

    if let Some(subcommand) = arguments.get(1).filter(|value| !value.is_empty()) {
        let decision = classify_normalized(format!("{name}.{subcommand}"));
        if !decision.is_allowed() {
            return decision;
        }
    }

    // XREAD and XREADGROUP are ordinary bounded stream reads unless the
    // untrusted caller adds BLOCK, which changes them into blocking commands.
    if matches!(name.as_str(), "XREAD" | "XREADGROUP")
        && arguments.iter().skip(1).any(|argument| argument == "BLOCK")
    {
        return Decision::Unsupported(name.clone());
    }

    Decision::Allow
}

fn normalize(value: &str) -> String {
    value.trim().to_ascii_uppercase()
}

fn matches_family(command: &str, family: &str) -> bool {
    command == family
        || command
            .strip_prefix(family)
            .is_some_and(|suffix| suffix.starts_with('.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_required_administrative_commands() {
        for command in [
            "SHUTDOWN",
            "DEBUG",
            "MODULE",
            "ACL",
            "CONFIG",
            "SAVE",
            "BGSAVE",
            "BGREWRITEAOF",
            "REPLICAOF",
            "SLAVEOF",
        ] {
            assert!(
                matches!(classify(command), Decision::Administrative(_)),
                "{command} must be rejected"
            );
        }
    }

    #[test]
    fn rejects_additional_playground_lifecycle_commands() {
        for command in [
            "CLIENT",
            "CLUSTER",
            "FAILOVER",
            "FLUSHALL",
            "FLUSHDB",
            "FUNCTION",
            "SCRIPT",
            "EVAL",
            "MIGRATE",
            "MONITOR",
            "RESET",
            "RESTORE",
            "SWAPDB",
            "SYNC",
            "PSYNC",
            "SLOWLOG",
            "CLOUD",
            "REPLICATE",
            "PIPELINE",
            "TRIGGER",
            "WASM",
            "CHAOS",
        ] {
            assert!(
                matches!(classify(command), Decision::Administrative(_)),
                "{command} must be rejected"
            );
        }
    }

    #[test]
    fn rejects_commands_without_a_single_bounded_reply() {
        for command in [
            "SUBSCRIBE",
            "PSUBSCRIBE",
            "BLPOP",
            "BZPOPMIN",
            "WAIT",
            "KEYS",
            "HGETALL",
            "SMEMBERS",
            "SORT",
        ] {
            assert!(
                matches!(classify(command), Decision::Unsupported(_)),
                "{command} must be refused as unsupported"
            );
        }
    }

    #[test]
    fn allows_ordinary_redis_compatible_commands() {
        for command in [
            "GET", "SET", "DEL", "PING", "INFO", "TYPE", "TTL", "LRANGE", "HSCAN", "SSCAN",
            "XRANGE", "XREAD", "INCR", "EXPIRE", "SELECT", "MULTI", "EXEC", "COMMAND", "DBSIZE",
            "SCAN",
        ] {
            assert_eq!(
                classify(command),
                Decision::Allow,
                "{command} must be allowed"
            );
        }
    }

    #[test]
    fn matching_is_case_insensitive_and_whitespace_tolerant() {
        assert!(matches!(classify("shutdown"), Decision::Administrative(_)));
        assert!(matches!(
            classify(" ShUtDoWn "),
            Decision::Administrative(_)
        ));
        assert!(matches!(
            classify_bytes_arguments(&[b"config".to_vec()]),
            Decision::Administrative(_)
        ));
        assert!(matches!(
            classify_arguments(&["SHUTDOWN".to_string(), "NOSAVE".to_string()]),
            Decision::Administrative(_)
        ));
    }

    #[test]
    fn rejects_dotted_and_subcommand_forms_without_loose_prefix_matches() {
        for arguments in [
            vec!["MIGRATE.START", "redis://example.invalid"],
            vec!["migrate", "start", "redis://example.invalid"],
            vec!["CLOUD.PROVIDER.ADD", "provider", "custom"],
            vec!["cloud", "provider.add", "provider", "custom"],
            vec!["S3.OBJECT.PUT", "bucket", "key", "value"],
            vec!["s3", "object.put", "bucket", "key", "value"],
            vec!["REPLICATE.ADD", "peer"],
            vec!["replicate", "add", "peer"],
            vec!["VIEW.SUBSCRIBE", "view"],
            vec!["view", "subscribe", "view"],
        ] {
            assert!(
                matches!(classify_arguments(&arguments), Decision::Administrative(_)),
                "{arguments:?} must be rejected"
            );
        }

        assert_eq!(classify("MIGRATEX"), Decision::Allow);
        assert_eq!(classify("S3X.OBJECT.PUT"), Decision::Allow);
    }

    #[test]
    fn blocking_stream_reads_are_rejected_but_bounded_reads_are_allowed() {
        assert!(matches!(
            classify_arguments(&["XREAD", "BLOCK", "0", "STREAMS", "events", "0"]),
            Decision::Unsupported(_)
        ));
        assert!(matches!(
            classify_arguments(&["xreadgroup", "group", "g", "c", "block", "1000"]),
            Decision::Unsupported(_)
        ));
        assert_eq!(
            classify_arguments(&["XREAD", "COUNT", "10", "STREAMS", "events", "0"]),
            Decision::Allow
        );
    }

    #[test]
    fn binary_argument_classification_matches_http_classification() {
        let arguments = vec![b"migrate".to_vec(), b"start".to_vec()];
        assert!(matches!(
            classify_bytes_arguments(&arguments),
            Decision::Administrative(_)
        ));
    }

    #[test]
    fn rejection_messages_name_the_command_and_reason() {
        assert_eq!(
            classify("SHUTDOWN").message(),
            "ERR SHUTDOWN is an administrative command and is disabled in the Ferrite playground"
        );
        assert!(classify("SUBSCRIBE").message().contains("not supported"));
        assert_eq!(classify("GET").message(), "");
    }

    #[test]
    fn non_utf8_command_names_are_left_to_the_server() {
        assert_eq!(
            classify_bytes_arguments(&[vec![0xff, 0xfe]]),
            Decision::Allow
        );
    }
}
