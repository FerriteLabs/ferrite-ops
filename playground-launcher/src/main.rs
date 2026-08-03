use std::process::{ExitCode, ExitStatus};
use std::time::Duration;

use ferrite_studio::studio::{Studio, StudioConfig};
use tokio::process::{Child, Command};
use tokio::time::timeout;

const FERRITE_BIN: &str = "/usr/local/bin/ferrite";
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("playground launcher error: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let mut ferrite = spawn_ferrite()?;
    let mut studio = Studio::new(StudioConfig {
        enabled: true,
        host: "0.0.0.0".to_string(),
        port: 8080,
        auth_enabled: false,
        cors_enabled: true,
        allowed_origins: vec!["*".to_string()],
        ..StudioConfig::default()
    });

    if let Err(error) = studio.start().await {
        stop_child(&mut ferrite).await;
        return Err(format!("failed to start Studio on 0.0.0.0:8080: {error}"));
    }

    eprintln!("Ferrite Playground ready: HTTP 0.0.0.0:8080, RESP 0.0.0.0:6379");

    tokio::select! {
        status = ferrite.wait() => {
            studio.stop().await
                .map_err(|error| format!("failed to stop Studio after Ferrite exited: {error}"))?;
            let status = status
                .map_err(|error| format!("failed to wait for Ferrite RESP server: {error}"))?;
            validate_child_status(status)
        }
        signal = shutdown_signal() => {
            signal?;
            studio.stop().await
                .map_err(|error| format!("failed to stop Studio during shutdown: {error}"))?;
            stop_child(&mut ferrite).await;
            Ok(())
        }
    }
}

fn spawn_ferrite() -> Result<Child, String> {
    Command::new(FERRITE_BIN)
        .args([
            "--bind",
            "0.0.0.0",
            "--port",
            "6379",
            "--data-dir",
            "/var/lib/ferrite/data",
        ])
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("failed to start {FERRITE_BIN}: {error}"))
}

fn validate_child_status(status: ExitStatus) -> Result<(), String> {
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "Ferrite RESP server exited unexpectedly with {status}"
        ))
    }
}

async fn stop_child(child: &mut Child) {
    if child.id().is_none() {
        return;
    }

    if let Err(error) = child.start_kill() {
        eprintln!("warning: failed to terminate Ferrite child: {error}");
    }

    if timeout(SHUTDOWN_TIMEOUT, child.wait()).await.is_err() {
        eprintln!("warning: timed out waiting for Ferrite child cleanup");
    }
}

#[cfg(unix)]
async fn shutdown_signal() -> Result<(), String> {
    use tokio::signal::unix::{signal, SignalKind};

    let mut terminate = signal(SignalKind::terminate())
        .map_err(|error| format!("failed to register SIGTERM handler: {error}"))?;

    tokio::select! {
        result = tokio::signal::ctrl_c() => {
            result.map_err(|error| format!("failed to wait for Ctrl-C: {error}"))
        }
        _ = terminate.recv() => Ok(()),
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() -> Result<(), String> {
    tokio::signal::ctrl_c()
        .await
        .map_err(|error| format!("failed to wait for Ctrl-C: {error}"))
}
