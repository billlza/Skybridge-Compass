//! Sinan Backend - High-performance Rust API Server
//!
//! This is a Rust replacement for the Supabase Edge Functions,
//! providing better performance and type safety.
//!
//! # Endpoints
//!
//! All endpoints match the original Supabase function paths:
//! - POST /bind-account - Bind email/phone (v1)
//! - POST /bind-account-v2 - Bind email/phone (v2 with RPC)
//! - POST /check-user-id-availability - Check if user ID is available
//! - POST /generate-nebula-id - Generate unique Nebula ID
//! - GET|POST /get-binding-status - Get user's binding status
//! - GET /get-user-profile - Get user profile
//! - POST /send-verification-code - Send verification code (v1)
//! - POST /send-verification-code-v2 - Send verification code (v2)
//! - POST /unbind-account - Unbind email/phone (v1)
//! - POST /unbind-account-v2 - Unbind email/phone (v2 with RPC)
//! - PUT /update-user-id - Update custom user ID
//! - POST /verify-code - Verify a verification code

mod auth;
mod cli_login;
mod config;
mod db;
mod error;
mod handlers;
mod models;
mod state;
mod utils;

use axum::{
    error_handling::HandleErrorLayer,
    body::Body,
    extract::DefaultBodyLimit,
    http::{
        header::{self, ACCEPT, AUTHORIZATION, CONTENT_TYPE},
        HeaderValue, Method, Request,
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Router,
};
use sqlx::postgres::PgPoolOptions;
use std::{net::SocketAddr, time::Duration};
use tower::{BoxError, ServiceBuilder};
use tower_http::{
    compression::CompressionLayer,
    cors::CorsLayer,
    trace::TraceLayer,
};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use crate::{config::Config, state::AppState};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load configuration
    let config = Config::from_env()?;

    // Initialize tracing
    init_tracing(&config);

    tracing::info!("Starting Sinan Backend Server...");

    // Create database connection pool
    let db_pool = PgPoolOptions::new()
        .max_connections(20)
        .connect(&config.database_url)
        .await?;

    tracing::info!("Database connection established");

    // Create application state
    let state = AppState::new(db_pool, config.clone())?;

    let cors = build_cors(&config)?;

    // Build router with all endpoints
    let app = Router::new()
        // Health check
        .route("/health", get(handlers::health_check))
        // CLI browser login
        .route(
            "/api/cli-login/sessions",
            post(handlers::create_cli_login_session),
        )
        .route(
            "/api/cli-login/sessions/{session_id}",
            get(handlers::get_cli_login_session),
        )
        .route(
            "/api/cli-login/sessions/{session_id}/approve",
            post(handlers::approve_cli_login_session),
        )
        .route(
            "/api/cli-login/token",
            post(handlers::exchange_cli_login_token),
        )
        // User profile endpoints
        .route("/get-user-profile", get(handlers::get_user_profile))
        .route("/update-user-id", put(handlers::update_user_id))
        .route(
            "/check-user-id-availability",
            post(handlers::check_user_id_availability),
        )
        // Nebula ID
        .route("/generate-nebula-id", post(handlers::generate_nebula_id))
        // Binding status
        .route(
            "/get-binding-status",
            get(handlers::get_binding_status).post(handlers::get_binding_status),
        )
        // Verification codes
        .route(
            "/send-verification-code",
            post(handlers::send_verification_code),
        )
        .route(
            "/send-verification-code-v2",
            post(handlers::send_verification_code_v2),
        )
        .route("/verify-code", post(handlers::verify_code))
        // Account binding (v1)
        .route("/bind-account", post(handlers::bind_account))
        .route("/unbind-account", post(handlers::unbind_account))
        // Account binding (v2 with RPC)
        .route("/bind-account-v2", post(handlers::bind_account_v2))
        .route("/unbind-account-v2", post(handlers::unbind_account_v2))
        // Add layers
        .layer(
            ServiceBuilder::new()
                .layer(HandleErrorLayer::new(handle_timeout_error))
                .timeout(Duration::from_secs(15)),
        )
        .layer(middleware::from_fn(set_security_headers))
        .layer(DefaultBodyLimit::max(16 * 1024))
        .layer(cors)
        .layer(CompressionLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // Parse server address
    let addr: SocketAddr = config.server_addr().parse()?;
    tracing::info!("Server listening on http://{}", addr);

    // Start server
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

fn build_cors(config: &Config) -> anyhow::Result<CorsLayer> {
    let allowed_origins = config
        .cors_origins
        .iter()
        .map(|origin| HeaderValue::from_str(origin))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(CorsLayer::new()
        .allow_origin(allowed_origins)
        .allow_methods([Method::GET, Method::POST, Method::PUT, Method::OPTIONS])
        .allow_headers([AUTHORIZATION, CONTENT_TYPE, ACCEPT])
        .max_age(Duration::from_secs(3600)))
}

async fn set_security_headers(req: Request<Body>, next: Next) -> Response {
    let mut response = next.run(req).await;
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::HeaderName::from_static("x-frame-options"),
        HeaderValue::from_static("DENY"),
    );
    headers.insert(
        header::HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        header::HeaderName::from_static("permissions-policy"),
        HeaderValue::from_static("camera=(), microphone=(), geolocation=()"),
    );
    response
}

async fn handle_timeout_error(_: BoxError) -> Response {
    (
        axum::http::StatusCode::REQUEST_TIMEOUT,
        "request timed out".to_string(),
    )
        .into_response()
}

/// Initialize tracing/logging
fn init_tracing(config: &Config) {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(&config.log_level));

    tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer().with_target(true))
        .init();
}
