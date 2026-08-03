//! Ferrite Playground launcher.
//!
//! Responsibilities are split across focused modules:
//!
//! * [`supervisor`] owns the Ferrite child, which listens on an internal
//!   loopback port only;
//! * [`proxy`] owns the public Redis-compatible port and forwards policy-
//!   approved commands to that child;
//! * [`http`] serves the interactive playground and its JSON API;
//! * [`policy`] is the single command policy shared by both entry points.

mod command;
mod http;
mod keys;
mod policy;
mod proxy;
mod resp;
mod supervisor;
#[cfg(test)]
mod testing;

use std::process::ExitCode;
use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::sync::{oneshot, Semaphore};
use tokio::task::JoinHandle;
use tokio::time::{timeout, Duration};

const HTTP_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const PROXY_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_BACKEND_OPERATIONS: usize = 32;

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
    let mut ferrite = supervisor::spawn()?;
    if let Err(error) = supervisor::wait_for_ready(&mut ferrite).await {
        supervisor::stop(&mut ferrite).await;
        return Err(error);
    }

    let http_listener = match TcpListener::bind(http::HTTP_ADDR).await {
        Ok(listener) => listener,
        Err(error) => {
            supervisor::stop(&mut ferrite).await;
            return Err(format!(
                "failed to bind HTTP playground to {}: {error}",
                http::HTTP_ADDR
            ));
        }
    };

    let proxy_listener = match TcpListener::bind(proxy::PUBLIC_RESP_ADDR).await {
        Ok(listener) => listener,
        Err(error) => {
            supervisor::stop(&mut ferrite).await;
            return Err(format!(
                "failed to bind the public RESP proxy to {}: {error}",
                proxy::PUBLIC_RESP_ADDR
            ));
        }
    };

    let backend_permits = Arc::new(Semaphore::new(MAX_BACKEND_OPERATIONS));
    let state = http::AppState {
        resp_addr: supervisor::INTERNAL_RESP_ADDR.to_string(),
        version: std::env::var("FERRITE_VERSION").unwrap_or_else(|_| "unknown".to_string()),
        backend_permits: Arc::clone(&backend_permits),
    };

    let (http_shutdown_tx, http_shutdown_rx) = oneshot::channel::<()>();
    let mut http_server: JoinHandle<Result<(), String>> = tokio::spawn(async move {
        axum::serve(http_listener, http::router(state))
            .with_graceful_shutdown(async {
                let _ = http_shutdown_rx.await;
            })
            .await
            .map_err(|error| format!("HTTP playground server failed: {error}"))
    });

    let (proxy_shutdown_tx, proxy_shutdown_rx) = oneshot::channel::<()>();
    let mut resp_proxy: JoinHandle<Result<(), String>> = tokio::spawn(async move {
        proxy::serve(
            proxy_listener,
            supervisor::INTERNAL_RESP_ADDR,
            backend_permits,
            proxy_shutdown_rx,
        )
        .await
    });

    eprintln!(
        "Ferrite Playground ready: HTTP {}, public RESP {} (Ferrite child on {})",
        http::HTTP_ADDR,
        proxy::PUBLIC_RESP_ADDR,
        supervisor::INTERNAL_RESP_ADDR
    );

    let outcome = tokio::select! {
        status = ferrite.wait() => {
            // Nothing but the launcher may stop Ferrite, so any exit observed
            // here — successful or not — is an unsolicited termination.
            match status {
                Ok(status) => Err(supervisor::unexpected_exit_error(status)),
                Err(error) => Err(format!("failed to wait for Ferrite RESP server: {error}")),
            }
        }
        signal = shutdown_signal() => {
            match signal {
                Ok(()) => {
                    supervisor::stop(&mut ferrite).await;
                    Ok(())
                }
                Err(error) => Err(error),
            }
        }
        result = &mut resp_proxy => {
            supervisor::stop(&mut ferrite).await;
            match result {
                Ok(Ok(())) => Err("public RESP proxy exited unexpectedly".to_string()),
                Ok(Err(error)) => Err(error),
                Err(error) => Err(format!("public RESP proxy task failed: {error}")),
            }
        }
        result = &mut http_server => {
            supervisor::stop(&mut ferrite).await;
            match result {
                Ok(Ok(())) => Err("HTTP playground server exited unexpectedly".to_string()),
                Ok(Err(error)) => Err(error),
                Err(error) => Err(format!("HTTP playground task failed: {error}")),
            }
        }
    };

    let _ = http_shutdown_tx.send(());
    let _ = proxy_shutdown_tx.send(());
    let http_result =
        join_service(&mut http_server, HTTP_SHUTDOWN_TIMEOUT, "HTTP playground").await;
    let proxy_result =
        join_service(&mut resp_proxy, PROXY_SHUTDOWN_TIMEOUT, "public RESP proxy").await;

    outcome.and(http_result).and(proxy_result)
}

async fn join_service(
    service: &mut JoinHandle<Result<(), String>>,
    grace: Duration,
    name: &str,
) -> Result<(), String> {
    match timeout(grace, &mut *service).await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) if error.is_cancelled() => Ok(()),
        Ok(Err(error)) => Err(format!("{name} task failed: {error}")),
        Err(_) => {
            service.abort();
            Err(format!("timed out waiting for {name} shutdown"))
        }
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
