//! Test-only RESP fixtures.
//!
//! `MockFerrite` is a small, in-process RESP server that behaves like the
//! Ferrite child for the subset of commands the launcher issues. It lets the
//! proxy, policy, and key-detail code be tested end to end — including proving
//! that refused commands never reach the server — without a real Ferrite build.

// Fixture helpers are shared by several test modules; not every helper is used
// by every module, so unused-warning noise is suppressed for the fixture only.
#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;

use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

use crate::proxy::{read_request, Request};
use crate::resp::{self, RespValue};

#[derive(Debug, Clone)]
pub enum Stored {
    Str(String),
    List(Vec<String>),
    Set(BTreeSet<String>),
    Hash(BTreeMap<String, String>),
    ZSet(Vec<(String, String)>),
    Stream(Vec<(String, Vec<String>)>),
}

impl Stored {
    fn type_name(&self) -> &'static str {
        match self {
            Stored::Str(_) => "string",
            Stored::List(_) => "list",
            Stored::Set(_) => "set",
            Stored::Hash(_) => "hash",
            Stored::ZSet(_) => "zset",
            Stored::Stream(_) => "stream",
        }
    }
}

#[derive(Default)]
struct MockState {
    commands: Vec<String>,
    shutdown: bool,
    data: HashMap<String, Stored>,
}

pub struct MockFerrite {
    addr: String,
    state: Arc<Mutex<MockState>>,
}

impl MockFerrite {
    pub async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let state = Arc::new(Mutex::new(MockState::default()));
        let served_state = Arc::clone(&state);

        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let state = Arc::clone(&served_state);
                tokio::spawn(async move { serve_connection(stream, state).await });
            }
        });

        Self { addr, state }
    }

    pub fn addr(&self) -> String {
        self.addr.clone()
    }

    /// A `&'static str` view of the address, for APIs that supervise a
    /// process-lifetime upstream.
    pub fn leaked_addr(&self) -> &'static str {
        Box::leak(self.addr.clone().into_boxed_str())
    }

    pub async fn received_commands(&self) -> Vec<String> {
        self.state.lock().await.commands.clone()
    }

    pub async fn was_shutdown(&self) -> bool {
        self.state.lock().await.shutdown
    }

    async fn seed(&self, key: &str, value: Stored) {
        self.state.lock().await.data.insert(key.to_string(), value);
    }

    pub async fn seed_string(&self, key: &str, value: &str) {
        self.seed(key, Stored::Str(value.to_string())).await;
    }

    pub async fn seed_list(&self, key: &str, values: Vec<String>) {
        self.seed(key, Stored::List(values)).await;
    }

    pub async fn seed_set(&self, key: &str, values: Vec<String>) {
        self.seed(key, Stored::Set(values.into_iter().collect()))
            .await;
    }

    pub async fn seed_hash(&self, key: &str, values: Vec<(String, String)>) {
        self.seed(key, Stored::Hash(values.into_iter().collect()))
            .await;
    }

    pub async fn seed_zset(&self, key: &str, values: Vec<(String, String)>) {
        self.seed(key, Stored::ZSet(values)).await;
    }

    pub async fn seed_stream(&self, key: &str, entries: Vec<(String, Vec<String>)>) {
        self.seed(key, Stored::Stream(entries)).await;
    }
}

async fn serve_connection(stream: TcpStream, state: Arc<Mutex<MockState>>) {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    loop {
        let request = match read_request(&mut reader).await {
            Ok(Request::Command(arguments)) => arguments,
            Ok(Request::Eof) | Err(_) => return,
        };
        if request.is_empty() {
            continue;
        }

        let arguments: Vec<String> = request
            .iter()
            .map(|argument| String::from_utf8_lossy(argument).into_owned())
            .collect();
        let name = arguments[0].to_ascii_uppercase();

        let reply = {
            let mut state = state.lock().await;
            state.commands.push(name.clone());
            if name == "SHUTDOWN" {
                state.shutdown = true;
                return;
            }
            dispatch(&mut state, &name, &arguments[1..])
        };

        let mut encoded = Vec::new();
        resp::encode_value(&reply, &mut encoded);
        if write_half.write_all(&encoded).await.is_err() {
            return;
        }
    }
}

fn bulk(value: &str) -> RespValue {
    RespValue::Bulk(Some(value.as_bytes().to_vec()))
}

fn dispatch(state: &mut MockState, name: &str, args: &[String]) -> RespValue {
    match name {
        "PING" => RespValue::Simple("PONG".into()),
        "SET" => {
            if args.len() < 2 {
                return RespValue::Error("ERR wrong number of arguments".into());
            }
            state
                .data
                .insert(args[0].clone(), Stored::Str(args[1].clone()));
            RespValue::Simple("OK".into())
        }
        "GET" => match state
            .data
            .get(args.first().map(String::as_str).unwrap_or(""))
        {
            Some(Stored::Str(value)) => bulk(value),
            Some(_) => RespValue::Error("WRONGTYPE".into()),
            None => RespValue::Bulk(None),
        },
        "TYPE" => match state.data.get(&args[0]) {
            Some(value) => RespValue::Simple(value.type_name().into()),
            None => RespValue::Simple("none".into()),
        },
        "TTL" => RespValue::Integer(-1),
        "STRLEN" => match state.data.get(&args[0]) {
            Some(Stored::Str(value)) => RespValue::Integer(value.len() as i64),
            _ => RespValue::Integer(0),
        },
        "GETRANGE" => match state.data.get(&args[0]) {
            Some(Stored::Str(value)) => {
                let start: usize = args[1].parse().unwrap_or(0);
                let end: i64 = args[2].parse().unwrap_or(-1);
                let end = if end < 0 {
                    value.len().saturating_sub(1)
                } else {
                    std::cmp::min(end as usize, value.len().saturating_sub(1))
                };
                if start > end || value.is_empty() {
                    bulk("")
                } else {
                    bulk(&value[start..=end])
                }
            }
            _ => bulk(""),
        },
        "LLEN" => match state.data.get(&args[0]) {
            Some(Stored::List(values)) => RespValue::Integer(values.len() as i64),
            _ => RespValue::Integer(0),
        },
        "LRANGE" => match state.data.get(&args[0]) {
            Some(Stored::List(values)) => {
                let start: usize = args[1].parse().unwrap_or(0);
                let stop: i64 = args[2].parse().unwrap_or(-1);
                let stop = if stop < 0 {
                    values.len() as i64 + stop
                } else {
                    stop
                };
                let stop = std::cmp::min(stop, values.len() as i64 - 1);
                if stop < start as i64 {
                    return RespValue::Array(Some(Vec::new()));
                }
                RespValue::Array(Some(
                    values[start..=stop as usize]
                        .iter()
                        .map(|v| bulk(v))
                        .collect(),
                ))
            }
            _ => RespValue::Array(Some(Vec::new())),
        },
        "SCARD" => match state.data.get(&args[0]) {
            Some(Stored::Set(values)) => RespValue::Integer(values.len() as i64),
            _ => RespValue::Integer(0),
        },
        "SSCAN" => match state.data.get(&args[0]) {
            Some(Stored::Set(values)) => {
                let members: Vec<String> = values.iter().cloned().collect();
                scan_reply(&members, args)
            }
            _ => scan_reply(&[], args),
        },
        "HLEN" => match state.data.get(&args[0]) {
            Some(Stored::Hash(values)) => RespValue::Integer(values.len() as i64),
            _ => RespValue::Integer(0),
        },
        "HSCAN" => match state.data.get(&args[0]) {
            Some(Stored::Hash(values)) => {
                let flat: Vec<String> = values
                    .iter()
                    .flat_map(|(field, value)| [field.clone(), value.clone()])
                    .collect();
                scan_pairs_reply(&flat, args)
            }
            _ => scan_pairs_reply(&[], args),
        },
        "ZCARD" => match state.data.get(&args[0]) {
            Some(Stored::ZSet(values)) => RespValue::Integer(values.len() as i64),
            _ => RespValue::Integer(0),
        },
        "ZRANGE" => match state.data.get(&args[0]) {
            Some(Stored::ZSet(values)) => {
                let start: usize = args[1].parse().unwrap_or(0);
                let stop: i64 = args[2].parse().unwrap_or(-1);
                let stop = if stop < 0 {
                    values.len() as i64 + stop
                } else {
                    std::cmp::min(stop, values.len() as i64 - 1)
                };
                if stop < start as i64 {
                    return RespValue::Array(Some(Vec::new()));
                }
                let with_scores = args.iter().any(|a| a.eq_ignore_ascii_case("WITHSCORES"));
                let mut out = Vec::new();
                for (member, score) in &values[start..=stop as usize] {
                    out.push(bulk(member));
                    if with_scores {
                        out.push(bulk(score));
                    }
                }
                RespValue::Array(Some(out))
            }
            _ => RespValue::Array(Some(Vec::new())),
        },
        "XLEN" => match state.data.get(&args[0]) {
            Some(Stored::Stream(entries)) => RespValue::Integer(entries.len() as i64),
            _ => RespValue::Integer(0),
        },
        "XRANGE" => match state.data.get(&args[0]) {
            Some(Stored::Stream(entries)) => {
                let count = args
                    .iter()
                    .position(|a| a.eq_ignore_ascii_case("COUNT"))
                    .and_then(|index| args.get(index + 1))
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(entries.len());
                RespValue::Array(Some(
                    entries
                        .iter()
                        .take(count)
                        .map(|(id, fields)| {
                            RespValue::Array(Some(vec![
                                bulk(id),
                                RespValue::Array(Some(
                                    fields.iter().map(|field| bulk(field)).collect(),
                                )),
                            ]))
                        })
                        .collect(),
                ))
            }
            _ => RespValue::Array(Some(Vec::new())),
        },
        // Test-only generator used to exercise response size bounds.
        "MOCKBULK" => {
            let size: usize = args[0].parse().unwrap_or(0);
            RespValue::Bulk(Some(vec![b'x'; size]))
        }
        "MOCKARRAY" => {
            let count: usize = args[0].parse().unwrap_or(0);
            let size: usize = args.get(1).and_then(|v| v.parse().ok()).unwrap_or(1);
            RespValue::Array(Some(
                (0..count)
                    .map(|_| RespValue::Bulk(Some(vec![b'y'; size])))
                    .collect(),
            ))
        }
        _ => RespValue::Error(format!("ERR unknown command '{name}'")),
    }
}

fn scan_cursor_and_count(args: &[String]) -> (usize, usize) {
    let cursor = args
        .get(1)
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let count = args
        .iter()
        .position(|a| a.eq_ignore_ascii_case("COUNT"))
        .and_then(|index| args.get(index + 1))
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(10);
    (cursor, count)
}

fn scan_reply(members: &[String], args: &[String]) -> RespValue {
    let (cursor, count) = scan_cursor_and_count(args);
    let end = std::cmp::min(cursor + count, members.len());
    let next = if end >= members.len() { 0 } else { end };
    RespValue::Array(Some(vec![
        bulk(&next.to_string()),
        RespValue::Array(Some(
            members[std::cmp::min(cursor, members.len())..end]
                .iter()
                .map(|member| bulk(member))
                .collect(),
        )),
    ]))
}

fn scan_pairs_reply(flat: &[String], args: &[String]) -> RespValue {
    let (cursor, count) = scan_cursor_and_count(args);
    let end = std::cmp::min(cursor + count * 2, flat.len());
    let next = if end >= flat.len() { 0 } else { end };
    RespValue::Array(Some(vec![
        bulk(&next.to_string()),
        RespValue::Array(Some(
            flat[std::cmp::min(cursor, flat.len())..end]
                .iter()
                .map(|entry| bulk(entry))
                .collect(),
        )),
    ]))
}

/// Minimal RESP client used by tests to drive the public proxy.
pub struct RespClient {
    reader: BufReader<tokio::net::tcp::OwnedReadHalf>,
    writer: tokio::net::tcp::OwnedWriteHalf,
}

impl RespClient {
    pub async fn connect(addr: &str) -> Self {
        let stream = TcpStream::connect(addr).await.unwrap();
        let (read_half, writer) = stream.into_split();
        Self {
            reader: BufReader::new(read_half),
            writer,
        }
    }

    pub async fn command(&mut self, arguments: &[&str]) -> RespValue {
        let encoded = resp::encode_command(arguments);
        self.writer.write_all(&encoded).await.unwrap();
        resp::read_value_budgeted(&mut self.reader, 0, &mut resp::ResponseBudget::default())
            .await
            .unwrap()
    }

    pub async fn try_command(&mut self, arguments: &[&str]) -> Result<RespValue, String> {
        let encoded = resp::encode_command(arguments);
        self.writer
            .write_all(&encoded)
            .await
            .map_err(|error| error.to_string())?;
        resp::read_value_budgeted(&mut self.reader, 0, &mut resp::ResponseBudget::default()).await
    }
}
