use axum::{
    routing::get,
    Router,
    Json,
};
use serde::{Serialize};
use std::net::SocketAddr;
use tower_http::cors::{CorsLayer};
use axum::http::HeaderValue;

#[tokio::main]
async fn main() {
    // Initialize tracing (optional but good for debugging)
    // tracing_subscriber::fmt::init();

    // CORS Layer to allow frontend access
    // SECURITY: Do not use allow_origin(Any) in production.
    // Restrict to explicit origins (default: localhost dev).
    let allowed_origin = std::env::var("SKYBRIDGE_WEB_ORIGIN")
        .unwrap_or_else(|_| "http://localhost:3000".to_string());
    let cors = CorsLayer::new()
        .allow_origin(allowed_origin.parse::<HeaderValue>().unwrap())
        .allow_methods([axum::http::Method::GET])
        .allow_headers([axum::http::header::CONTENT_TYPE]);

    // Build our application with a route
    let app = Router::new()
        .route("/", get(root))
        .route("/api/status", get(get_status))
        .layer(cors);

    // Run it
    // Bind address (default localhost only)
    let bind_host = std::env::var("SKYBRIDGE_BIND_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let bind_port: u16 = std::env::var("SKYBRIDGE_BIND_PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8080);
    let addr: SocketAddr = format!("{bind_host}:{bind_port}").parse().unwrap();
    println!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
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
