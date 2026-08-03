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

const SERVICE_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
const SERVICE_ABORT_REAP_TIMEOUT: Duration = Duration::from_millis(500);
#[cfg(test)]
const MAX_INTERNAL_SHUTDOWN_BUDGET: Duration = Duration::from_secs(7);
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
    let mut http_server: Option<JoinHandle<Result<(), String>>> = Some(tokio::spawn(async move {
        axum::serve(
            http::LimitedListener::new(http_listener),
            http::router(state),
        )
        .with_graceful_shutdown(async {
            let _ = http_shutdown_rx.await;
        })
        .await
        .map_err(|error| format!("HTTP playground server failed: {error}"))
    }));

    let (proxy_shutdown_tx, proxy_shutdown_rx) = oneshot::channel::<()>();
    let mut resp_proxy: Option<JoinHandle<Result<(), String>>> = Some(tokio::spawn(async move {
        proxy::serve(
            proxy_listener,
            supervisor::INTERNAL_RESP_ADDR,
            backend_permits,
            proxy_shutdown_rx,
        )
        .await
    }));

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
        result = resp_proxy.as_mut().expect("RESP proxy task is present") => {
            resp_proxy.take();
            supervisor::stop(&mut ferrite).await;
            unexpected_service_result(
                result,
                "public RESP proxy exited unexpectedly",
                "public RESP proxy",
            )
        }
        result = http_server.as_mut().expect("HTTP server task is present") => {
            http_server.take();
            supervisor::stop(&mut ferrite).await;
            unexpected_service_result(
                result,
                "HTTP playground server exited unexpectedly",
                "HTTP playground",
            )
        }
    };

    let _ = http_shutdown_tx.send(());
    let _ = proxy_shutdown_tx.send(());
    let (http_result, proxy_result) = join_services(&mut http_server, &mut resp_proxy).await;

    outcome.and(http_result).and(proxy_result)
}

async fn join_services(
    http_server: &mut Option<JoinHandle<Result<(), String>>>,
    resp_proxy: &mut Option<JoinHandle<Result<(), String>>>,
) -> (Result<(), String>, Result<(), String>) {
    tokio::join!(
        join_service(http_server, SERVICE_SHUTDOWN_TIMEOUT, "HTTP playground"),
        join_service(resp_proxy, SERVICE_SHUTDOWN_TIMEOUT, "public RESP proxy")
    )
}

async fn join_service(
    service: &mut Option<JoinHandle<Result<(), String>>>,
    grace: Duration,
    name: &str,
) -> Result<(), String> {
    let Some(mut service) = service.take() else {
        return Ok(());
    };

    match timeout(grace, &mut service).await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) if error.is_cancelled() => Ok(()),
        Ok(Err(error)) => Err(format!("{name} task failed: {error}")),
        Err(_) => {
            service.abort();
            let _ = timeout(SERVICE_ABORT_REAP_TIMEOUT, service)
                .await
                .map_err(|_| format!("timed out reaping aborted {name} task"))?;
            Err(format!("timed out waiting for {name} shutdown"))
        }
    }
}

fn unexpected_service_result(
    result: Result<Result<(), String>, tokio::task::JoinError>,
    unexpected_exit: &str,
    task_name: &str,
) -> Result<(), String> {
    match result {
        Ok(Ok(())) => Err(unexpected_exit.to_string()),
        Ok(Err(error)) => Err(error),
        Err(error) => Err(format!("{task_name} task failed: {error}")),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cleanup_consumes_a_service_handle_only_once() {
        let mut service = Some(tokio::spawn(async { Ok(()) }));
        assert!(
            join_service(&mut service, Duration::from_secs(1), "test service")
                .await
                .is_ok()
        );
        assert!(service.is_none());
        assert!(
            join_service(&mut service, Duration::from_secs(1), "test service")
                .await
                .is_ok()
        );
    }

    #[test]
    fn total_internal_shutdown_budget_stays_below_docker_default() {
        assert_eq!(supervisor::SHUTDOWN_TIMEOUT, Duration::from_secs(5));
        assert_eq!(
            MAX_INTERNAL_SHUTDOWN_BUDGET,
            supervisor::SHUTDOWN_TIMEOUT
                + supervisor::KILL_REAP_TIMEOUT
                + SERVICE_SHUTDOWN_TIMEOUT
                + SERVICE_ABORT_REAP_TIMEOUT
        );
        assert!(MAX_INTERNAL_SHUTDOWN_BUDGET < Duration::from_secs(10));
    }

    #[tokio::test]
    async fn remaining_service_tasks_are_joined_and_reaped_together() {
        let mut http = Some(tokio::spawn(async {
            std::future::pending::<Result<(), String>>().await
        }));
        let mut resp = Some(tokio::spawn(async {
            std::future::pending::<Result<(), String>>().await
        }));

        let joined = timeout(Duration::from_secs(2), join_services(&mut http, &mut resp))
            .await
            .expect("parallel service cleanup must fit one service timeout plus abort reap");
        assert!(joined.0.unwrap_err().contains("HTTP playground"));
        assert!(joined.1.unwrap_err().contains("public RESP proxy"));
        assert!(http.is_none());
        assert!(resp.is_none());
    }

    #[tokio::test]
    async fn selected_service_errors_are_preserved_without_polling_again() {
        let mut service = Some(tokio::spawn(async {
            Err("original service error".to_string())
        }));
        let result = service.as_mut().expect("service exists").await;
        service.take();

        assert_eq!(
            unexpected_service_result(
                result,
                "public RESP proxy exited unexpectedly",
                "public RESP proxy",
            )
            .unwrap_err(),
            "original service error"
        );
        assert!(
            join_service(&mut service, Duration::from_millis(10), "public RESP proxy")
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn unexpected_clean_http_and_resp_exits_keep_the_service_name() {
        let http = tokio::spawn(async { Ok(()) }).await;
        let resp = tokio::spawn(async { Ok(()) }).await;

        assert_eq!(
            unexpected_service_result(
                http,
                "HTTP playground server exited unexpectedly",
                "HTTP playground",
            )
            .unwrap_err(),
            "HTTP playground server exited unexpectedly"
        );
        assert_eq!(
            unexpected_service_result(
                resp,
                "public RESP proxy exited unexpectedly",
                "public RESP proxy",
            )
            .unwrap_err(),
            "public RESP proxy exited unexpectedly"
        );
    }
}
