//! Textual command parsing for the HTTP API.
//!
//! Users type commands the way they would in `redis-cli`, so the HTTP API
//! accepts a single line and tokenizes it into argv with shell-like quoting.

use crate::resp::MAX_ARGUMENTS;

pub const MAX_COMMAND_LENGTH: usize = 16 * 1024;

pub fn parse(command: &str) -> Result<Vec<String>, String> {
    if command.len() > MAX_COMMAND_LENGTH {
        return Err(format!(
            "command is too long (maximum {MAX_COMMAND_LENGTH} bytes)"
        ));
    }

    let mut arguments = Vec::new();
    let mut current = String::new();
    let mut chars = command.chars().peekable();
    let mut quote = None;
    let mut argument_started = false;

    while let Some(character) = chars.next() {
        match quote {
            Some('\'') => {
                if character == '\'' {
                    quote = None;
                } else {
                    current.push(character);
                }
            }
            Some('"') => match character {
                '"' => quote = None,
                '\\' => {
                    let escaped = chars
                        .next()
                        .ok_or_else(|| "command ends with an incomplete escape".to_string())?;
                    current.push(unescape(escaped));
                }
                _ => current.push(character),
            },
            Some(_) => unreachable!(),
            None => match character {
                '\'' | '"' => {
                    quote = Some(character);
                    argument_started = true;
                }
                '\\' => {
                    let escaped = chars
                        .next()
                        .ok_or_else(|| "command ends with an incomplete escape".to_string())?;
                    current.push(unescape(escaped));
                    argument_started = true;
                }
                c if c.is_whitespace() => {
                    if argument_started {
                        arguments.push(std::mem::take(&mut current));
                        argument_started = false;
                    }
                }
                _ => {
                    current.push(character);
                    argument_started = true;
                }
            },
        }
    }

    if quote.is_some() {
        return Err("command contains an unterminated quote".to_string());
    }
    if argument_started {
        arguments.push(current);
    }
    if arguments.is_empty() {
        return Err("command must not be empty".to_string());
    }
    if arguments.len() > MAX_ARGUMENTS {
        return Err(format!(
            "command has too many arguments (maximum {MAX_ARGUMENTS})"
        ));
    }
    Ok(arguments)
}

fn unescape(character: char) -> char {
    match character {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_quoted_and_escaped_commands() {
        assert_eq!(
            parse(r#"SET "hello world" 'value with spaces'"#).unwrap(),
            vec!["SET", "hello world", "value with spaces"]
        );
        assert_eq!(
            parse(r#"SET escaped\ key line\nbreak"#).unwrap(),
            vec!["SET", "escaped key", "line\nbreak"]
        );
        assert_eq!(parse(r#"SET empty """#).unwrap(), vec!["SET", "empty", ""]);
    }

    #[test]
    fn rejects_invalid_commands() {
        assert!(parse("   ").unwrap_err().contains("empty"));
        assert!(parse(r#"GET "missing"#)
            .unwrap_err()
            .contains("unterminated"));
        assert!(parse("GET trailing\\")
            .unwrap_err()
            .contains("incomplete escape"));
    }

    #[test]
    fn rejects_oversized_and_overlong_argument_lists() {
        let long = "A".repeat(MAX_COMMAND_LENGTH + 1);
        assert!(parse(&long).unwrap_err().contains("too long"));

        let many = vec!["X"; MAX_ARGUMENTS + 1].join(" ");
        assert!(parse(&many).unwrap_err().contains("too many arguments"));
    }
}
