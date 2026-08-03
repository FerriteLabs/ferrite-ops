//! Shared playground command policy.
//!
//! The playground is an unauthenticated, publicly reachable, shared Ferrite
//! instance. Every command that reaches Ferrite — whether it arrives on the
//! public RESP port or through the HTTP API — is classified here, so both
//! entry points enforce exactly the same rules. Ordinary Redis-compatible
//! data commands stay allowed; administrative/lifecycle commands and commands
//! that cannot be served by a bounded request/response proxy are rejected
//! before they are forwarded to the Ferrite child.

/// Administrative and lifecycle commands. These can stop, reconfigure,
/// replicate, or destroy the shared playground instance, or execute arbitrary
/// server-side code, and are never forwarded.
const ADMINISTRATIVE_COMMANDS: &[&str] = &[
    "ACL",
    "BGREWRITEAOF",
    "BGSAVE",
    "CLIENT",
    "CLUSTER",
    "CONFIG",
    "DEBUG",
    "EVAL",
    "EVALSHA",
    "EVALSHA_RO",
    "EVAL_RO",
    "FAILOVER",
    "FCALL",
    "FCALL_RO",
    "FLUSHALL",
    "FLUSHDB",
    "FUNCTION",
    "LATENCY",
    "MIGRATE",
    "MODULE",
    "MONITOR",
    "PFDEBUG",
    "PFSELFTEST",
    "PSYNC",
    "REPLICAOF",
    "RESET",
    "RESTORE",
    "SAVE",
    "SCRIPT",
    "SHUTDOWN",
    "SLAVEOF",
    "SLOWLOG",
    "SWAPDB",
    "SYNC",
];

/// Commands that never produce exactly one bounded reply on a request/response
/// connection: they either block until another client acts or switch the
/// connection into a server-push mode. The playground proxies one command to
/// one reply, so these are refused with a distinct, non-security message.
const UNSUPPORTED_COMMANDS: &[&str] = &[
    "BLMOVE",
    "BLMPOP",
    "BLPOP",
    "BRPOP",
    "BRPOPLPUSH",
    "BZMPOP",
    "BZPOPMAX",
    "BZPOPMIN",
    "PSUBSCRIBE",
    "PUNSUBSCRIBE",
    "SSUBSCRIBE",
    "SUBSCRIBE",
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
    let normalized = name.trim().to_ascii_uppercase();
    if normalized.is_empty() {
        return Decision::Allow;
    }
    if ADMINISTRATIVE_COMMANDS.contains(&normalized.as_str()) {
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
    match arguments.first() {
        Some(name) => classify(name.as_ref()),
        None => Decision::Allow,
    }
}

/// Classify a raw (possibly non-UTF-8) command name received on the RESP port.
pub fn classify_bytes(name: &[u8]) -> Decision {
    match std::str::from_utf8(name) {
        Ok(name) => classify(name),
        // A non-UTF-8 command name can never match a Ferrite command name, so
        // let the server produce its own "unknown command" error.
        Err(_) => Decision::Allow,
    }
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
            "CLIENT", "CLUSTER", "FAILOVER", "FLUSHALL", "FLUSHDB", "FUNCTION", "SCRIPT", "EVAL",
            "MIGRATE", "MONITOR", "RESET", "RESTORE", "SWAPDB", "SYNC", "PSYNC", "SLOWLOG",
            "LATENCY",
        ] {
            assert!(
                matches!(classify(command), Decision::Administrative(_)),
                "{command} must be rejected"
            );
        }
    }

    #[test]
    fn rejects_commands_without_a_single_bounded_reply() {
        for command in ["SUBSCRIBE", "PSUBSCRIBE", "BLPOP", "BZPOPMIN", "WAIT"] {
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
            "XRANGE", "INCR", "EXPIRE", "SELECT", "MULTI", "EXEC", "COMMAND", "DBSIZE", "SCAN",
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
            classify_bytes(b"config"),
            Decision::Administrative(_)
        ));
        assert!(matches!(
            classify_arguments(&["SHUTDOWN".to_string(), "NOSAVE".to_string()]),
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
        assert_eq!(classify_bytes(&[0xff, 0xfe]), Decision::Allow);
    }
}
