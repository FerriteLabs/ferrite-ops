//! Ferrite child process lifecycle.
//!
//! The Ferrite child is never exposed directly: it is bound to an internal
//! loopback address, and only the launcher connects to it. This module owns
//! spawning, readiness probing, and bounded, signal-based shutdown.

use std::process::ExitStatus;
use std::time::Duration;

use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use tokio::process::{Child, Command};
use tokio::time::{sleep, timeout, Instant};

use crate::resp::{self, RespValue};

pub const FERRITE_BIN: &str = "/usr/local/bin/ferrite";
/// Internal loopback address of the Ferrite child. It is deliberately not the
/// public port: only the launcher's policy-enforcing proxy may reach it.
pub const INTERNAL_RESP_ADDR: &str = "127.0.0.1:6380";
pub const INTERNAL_RESP_BIND: &str = "127.0.0.1";
pub const INTERNAL_RESP_PORT: &str = "6380";
pub const DATA_DIR: &str = "/var/lib/ferrite/data";
pub const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
pub const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);

/// Spawn the Ferrite child bound to the internal loopback port only.
pub fn spawn() -> Result<Child, String> {
    Command::new(FERRITE_BIN)
        .args([
            "--bind",
            INTERNAL_RESP_BIND,
            "--port",
            INTERNAL_RESP_PORT,
            "--data-dir",
            DATA_DIR,
        ])
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("failed to start {FERRITE_BIN}: {error}"))
}

/// Block until the child answers PING on the internal address, or fail.
pub async fn wait_for_ready(child: &mut Child) -> Result<(), String> {
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("failed to inspect Ferrite child: {error}"))?
        {
            return Err(format!(
                "Ferrite RESP server exited during startup with {status}"
            ));
        }

        if matches!(
            resp::execute(INTERNAL_RESP_ADDR, &["PING".to_string()]).await,
            Ok(RespValue::Simple(reply)) if reply == "PONG"
        ) {
            return Ok(());
        }

        if Instant::now() >= deadline {
            return Err(format!(
                "Ferrite RESP server did not become ready at {INTERNAL_RESP_ADDR} within {} seconds",
                STARTUP_TIMEOUT.as_secs()
            ));
        }
        sleep(Duration::from_millis(100)).await;
    }
}

/// Describe a child exit that the launcher did not initiate.
///
/// The playground supervises exactly one long-running service, so *any*
/// unsolicited exit is a failure — including a clean `exit(0)`, which is what
/// a successful, unauthorized `SHUTDOWN` would produce.
pub fn unexpected_exit_error(status: ExitStatus) -> String {
    format!(
        "Ferrite RESP server exited without a launcher-initiated shutdown ({status}); \
         the playground supervises a single long-running service, so any unsolicited exit is a failure"
    )
}

pub async fn stop(child: &mut Child) {
    if let Err(error) = stop_with_timeout(child, SHUTDOWN_TIMEOUT).await {
        eprintln!("warning: {error}");
    }
}

pub async fn stop_with_timeout(child: &mut Child, grace: Duration) -> Result<ExitStatus, String> {
    if let Some(status) = child
        .try_wait()
        .map_err(|error| format!("failed to inspect Ferrite child before shutdown: {error}"))?
    {
        return Ok(status);
    }

    let pid = child
        .id()
        .ok_or_else(|| "Ferrite child has no process ID".to_string())?;
    kill(Pid::from_raw(pid as i32), Signal::SIGTERM)
        .map_err(|error| format!("failed to send SIGTERM to Ferrite child {pid}: {error}"))?;

    match timeout(grace, child.wait()).await {
        Ok(result) => result.map_err(|error| format!("failed to wait for Ferrite child: {error}")),
        Err(_) => {
            eprintln!(
                "warning: Ferrite child {pid} did not exit within {} seconds; escalating to SIGKILL",
                grace.as_secs_f64()
            );
            child
                .start_kill()
                .map_err(|error| format!("failed to SIGKILL Ferrite child {pid}: {error}"))?;
            child
                .wait()
                .await
                .map_err(|error| format!("failed to reap Ferrite child {pid}: {error}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn child_is_bound_to_the_internal_loopback_port_only() {
        assert_eq!(INTERNAL_RESP_BIND, "127.0.0.1");
        assert_eq!(INTERNAL_RESP_PORT, "6380");
        assert_eq!(
            INTERNAL_RESP_ADDR,
            format!("{INTERNAL_RESP_BIND}:{INTERNAL_RESP_PORT}")
        );
        assert_ne!(INTERNAL_RESP_PORT, "6379");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn any_unsolicited_child_exit_is_an_error_even_when_successful() {
        let status = Command::new("sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap()
            .wait()
            .await
            .unwrap();
        assert!(status.success());
        let message = unexpected_exit_error(status);
        assert!(message.contains("without a launcher-initiated shutdown"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn sends_sigterm_and_reaps_cooperative_child() {
        let mut child = Command::new("sh")
            .args(["-c", "trap 'exit 0' TERM; while :; do :; done"])
            .spawn()
            .unwrap();
        // Give the shell time to install its trap even on a loaded machine.
        sleep(Duration::from_millis(250)).await;

        let status = stop_with_timeout(&mut child, Duration::from_secs(1))
            .await
            .unwrap();
        assert!(status.success());
        assert!(child.try_wait().unwrap().is_some());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn escalates_to_sigkill_and_reaps_uncooperative_child() {
        let mut child = Command::new("sh")
            .args(["-c", "trap '' TERM; while :; do :; done"])
            .spawn()
            .unwrap();
        // Give the shell time to install its trap even on a loaded machine.
        sleep(Duration::from_millis(250)).await;

        let status = stop_with_timeout(&mut child, Duration::from_millis(100))
            .await
            .unwrap();
        assert!(!status.success());
        assert!(child.try_wait().unwrap().is_some());
    }
}
