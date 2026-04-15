use std::{net::SocketAddr, sync::Arc};

use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Serialize;
use tokio::net::TcpListener;
use tracing::info;

use crate::{
    config::MailServiceConfig,
    readiness::MailReadiness,
    template::{RegistrationSuccessEmailContent, render_registration_success_email},
};

#[derive(Clone)]
pub struct MailAppState {
    config: Arc<MailServiceConfig>,
    readiness: Arc<MailReadiness>,
}

impl MailAppState {
    pub fn new(config: MailServiceConfig) -> Self {
        let readiness = MailReadiness::from_config(&config);
        Self {
            config: Arc::new(config),
            readiness: Arc::new(readiness),
        }
    }

    pub fn readiness(&self) -> &MailReadiness {
        self.readiness.as_ref()
    }
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    ready: bool,
    mode: crate::config::MailMode,
    require_smtp_ready: bool,
    listen_addr: String,
    smtp_configured: bool,
    reasons: Vec<String>,
    missing_configuration: Vec<String>,
}

#[derive(Debug, Serialize)]
struct ReadyResponse {
    status: &'static str,
    mode: crate::config::MailMode,
    smtp_ready: bool,
    reasons: Vec<String>,
    missing_configuration: Vec<String>,
}

pub async fn run_mail_server(config: MailServiceConfig) -> Result<()> {
    let state = MailAppState::new(config);
    let address: SocketAddr = state
        .config
        .listen_addr
        .parse()
        .with_context(|| format!("invalid listen addr: {}", state.config.listen_addr))?;

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/health", get(health))
        .route("/readyz", get(readyz))
        .route(
            "/v1/notifications/registration-success/render",
            post(render_registration_success),
        )
        .with_state(state.clone());

    let listener = TcpListener::bind(address)
        .await
        .with_context(|| format!("failed to bind {}", state.config.listen_addr))?;
    info!(listen_addr = %address, "skybridge auth-mail server listening");
    axum::serve(listener, app)
        .await
        .context("mail server exited")
}

async fn healthz() -> &'static str {
    "ok"
}

async fn health(State(state): State<MailAppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: if state.readiness.ready {
            "ok"
        } else {
            "degraded"
        },
        ready: state.readiness.ready,
        mode: state.config.mode,
        require_smtp_ready: state.config.require_smtp_ready,
        listen_addr: state.config.listen_addr.clone(),
        smtp_configured: state.readiness.smtp_configured,
        reasons: state.readiness.reasons.clone(),
        missing_configuration: state.readiness.missing_configuration.clone(),
    })
}

async fn readyz(State(state): State<MailAppState>) -> Response {
    let status = if state.readiness.ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        status,
        Json(ReadyResponse {
            status: if state.readiness.ready {
                "ready"
            } else {
                "not_ready"
            },
            mode: state.config.mode,
            smtp_ready: state.readiness.ready,
            reasons: state.readiness.reasons.clone(),
            missing_configuration: state.readiness.missing_configuration.clone(),
        }),
    )
        .into_response()
}

async fn render_registration_success(
    Json(payload): Json<RegistrationSuccessEmailContent>,
) -> Json<crate::template::RenderedEmail> {
    Json(render_registration_success_email(&payload))
}
