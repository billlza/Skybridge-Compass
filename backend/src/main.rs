use axum::http::{HeaderName, HeaderValue, Method, StatusCode};
use axum::{Json, Router, routing::get};
use serde::Serialize;
use std::{net::SocketAddr, time::Duration};
use tower_http::{
    catch_panic::CatchPanicLayer,
    compression::CompressionLayer,
    cors::CorsLayer,
    limit::RequestBodyLimitLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use tracing::warn;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() {
    // Structured logs (set `RUST_LOG=debug` etc to tune verbosity).
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer())
        .try_init();

    // CORS Layer to allow frontend access
    // SECURITY: Do not use allow_origin(Any) in production.
    // Restrict to explicit origins (default: localhost dev).
    let allowed_origins_raw = std::env::var("SKYBRIDGE_WEB_ORIGIN")
        .unwrap_or_else(|_| "http://localhost:3000".to_string());
    let mut allowed_origins: Vec<HeaderValue> = Vec::new();
    for origin in allowed_origins_raw.split(',') {
        let origin = origin.trim();
        if origin.is_empty() {
            continue;
        }
        if origin == "*" {
            warn!("SKYBRIDGE_WEB_ORIGIN includes '*', which is insecure; ignoring");
            continue;
        }
        match origin.parse::<HeaderValue>() {
            Ok(v) => allowed_origins.push(v),
            Err(_) => warn!("Invalid CORS origin in SKYBRIDGE_WEB_ORIGIN: {}", origin),
        }
    }
    if allowed_origins.is_empty() {
        allowed_origins.push(HeaderValue::from_static("http://localhost:3000"));
    }
    let cors = CorsLayer::new()
        .allow_origin(allowed_origins)
        .allow_methods([Method::GET])
        .allow_headers([axum::http::header::CONTENT_TYPE]);

    // Build our application with a route
    let x_request_id = HeaderName::from_static("x-request-id");
    let app = Router::new()
        .route("/", get(root))
        .route("/api/status", get(get_status))
        // Safety/stability middleware (defense-in-depth)
        .layer(PropagateRequestIdLayer::new(x_request_id.clone()))
        .layer(SetRequestIdLayer::new(x_request_id, MakeRequestUuid))
        .layer(TraceLayer::new_for_http())
        .layer(CompressionLayer::new())
        .layer(RequestBodyLimitLayer::new(1024 * 1024)) // 1MB
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(10),
        ))
        .layer(CatchPanicLayer::new())
        .layer(cors);

    // Run it
    // Bind address:
    // - Render/containers: must listen on 0.0.0.0 and the platform-provided PORT.
    // - Local dev: you can still override via SKYBRIDGE_BIND_HOST/SKYBRIDGE_BIND_PORT.
    let bind_host = std::env::var("SKYBRIDGE_BIND_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let bind_port: u16 = std::env::var("SKYBRIDGE_BIND_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .or_else(|| std::env::var("PORT").ok().and_then(|v| v.parse().ok()))
        .unwrap_or(8080);
    let addr: SocketAddr = format!("{bind_host}:{bind_port}").parse().unwrap();
    println!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();
}

async fn root() -> &'static str {
    "SkyBridge Backend Running"
}

#[derive(Serialize)]
struct SystemStatus {
    status: String,
    online_devices: u32,
    active_sessions: u32,
    transfer_tasks: u32,
}

async fn get_status() -> Json<SystemStatus> {
    Json(SystemStatus {
        status: "Running Smoothly".to_string(),
        online_devices: 0,
        active_sessions: 0,
        transfer_tasks: 0,
    })
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut term = signal(SignalKind::terminate()).expect("failed to install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = term.recv() => {},
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
