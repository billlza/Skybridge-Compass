mod agent;
mod handlers;
mod models;
mod nebula_id;
mod oauth;
mod state;
mod supabase;

use axum::{
    http::{header, HeaderMap, HeaderName, HeaderValue, Method, Request},
    middleware::{self, Next},
    response::Response,
    routing::{get, patch, post},
    Router,
};
use std::net::SocketAddr;
use tower_http::cors::CorsLayer;
use tower_http::services::ServeDir;
use tracing::{error, info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

/// PNA (Private Network Access) middleware
/// Ensures all responses include Access-Control-Allow-Private-Network header
/// This middleware adds the PNA header to ALL responses, including CORS preflight responses
async fn pna_middleware(request: Request<axum::body::Body>, next: Next) -> Response {
    // Process the request and add PNA header to response
    let mut response = next.run(request).await;

    // Always add PNA header to every response
    response.headers_mut().insert(
        "Access-Control-Allow-Private-Network",
        axum::http::HeaderValue::from_static("true"),
    );

    response
}

#[tokio::main]
async fn main() {
    // Initialize logging
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "backend=debug,tower_http=debug".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    // Initialize state
    let state = state::AppState::new();

    // Setup CORS
    let cors = cors_layer();

    // Build router (HTTP API)
    // Middleware layers are applied in reverse order (last added = outermost)
    // CORS is added first, then PNA, so PNA middleware wraps CORS and adds headers to all responses
    let app = Router::new()
        .route("/health", get(health_check))
        .route("/.well-known/openid-configuration", get(oauth::discovery))
        .route(
            "/oauth/authorize",
            get(oauth::authorize).post(oauth::authorize_submit),
        )
        .route("/oauth/token", post(oauth::token))
        .route("/oauth/userinfo", get(oauth::userinfo))
        .route("/oauth/revoke", post(oauth::revoke))
        .route("/dev/oauth/authorize", post(oauth::dev_authorize))
        .route("/api/webrtc/config", get(webrtc_config))
        .route("/api/webrtc/health", get(webrtc_health))
        .route("/api/auth/login", post(handlers::login))
        .route("/api/auth/register", post(handlers::register))
        .route("/api/auth/send-code", post(handlers::send_code))
        .route("/api/auth/verify-code", post(handlers::verify_code))
        .route("/api/auth/profile", get(handlers::get_profile))
        .route("/api/auth/profile", patch(handlers::update_profile))
        .route("/api/auth/avatar", post(handlers::upload_avatar))
        .route("/api/devices", get(handlers::get_devices))
        .route("/api/monitor/stats", get(handlers::get_system_stats))
        .route("/api/transfer/upload", post(handlers::upload_file))
        .route(
            "/api/transfer/session/start",
            post(handlers::start_upload_session),
        )
        .route("/api/transfer/chunk", post(handlers::upload_chunk))
        .route("/api/transfer/session/status", get(handlers::upload_status))
        .route(
            "/api/transfer/session/commit",
            post(handlers::commit_upload),
        )
        .nest_service("/uploads", ServeDir::new("uploads"))
        .layer(cors)
        .layer(middleware::from_fn(pna_middleware))
        .with_state(state.clone());

    // Run HTTP server
    let addr = bind_address();
    info!("nebula-auth listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    if agent_enabled() {
        tokio::spawn(async move {
            let agent_app = agent::build_router(state.clone());
            let agent_addr = SocketAddr::from(([127, 0, 0, 1], 7001));
            match tokio::net::TcpListener::bind(agent_addr).await {
                Ok(agent_listener) => {
                    info!("agent listening on {}", agent_addr);
                    if let Err(e) = axum::serve(agent_listener, agent_app).await {
                        error!("agent server error: {}", e);
                    }
                }
                Err(e) => {
                    error!("agent bind error: {}", e);
                }
            }
        });
    } else {
        info!("agent server disabled; set SKYBRIDGE_AGENT_ENABLED=true to enable it");
    }
    axum::serve(listener, app).await.unwrap();
}
use axum::{response::IntoResponse, Json};

fn bind_address() -> SocketAddr {
    let host = std::env::var("SKYBRIDGE_BIND_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port = std::env::var("PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .or_else(|| {
            std::env::var("SKYBRIDGE_BIND_PORT")
                .ok()
                .and_then(|value| value.parse::<u16>().ok())
        })
        .unwrap_or(3000);

    format!("{host}:{port}")
        .parse()
        .unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], port)))
}

fn agent_enabled() -> bool {
    matches!(
        std::env::var("SKYBRIDGE_AGENT_ENABLED")
            .unwrap_or_else(|_| "false".to_string())
            .to_lowercase()
            .as_str(),
        "1" | "true" | "yes"
    )
}

fn allowed_origins() -> Vec<HeaderValue> {
    let configured = std::env::var("NEBULA_WEB_ORIGINS")
        .ok()
        .or_else(|| std::env::var("SKYBRIDGE_WEB_ORIGIN").ok())
        .unwrap_or_else(|| {
            [
                "http://localhost:5173",
                "http://127.0.0.1:5173",
                "https://skybridge-compass.vercel.app",
                "https://nebula-technologies.net",
                "https://www.nebula-technologies.net",
            ]
            .join(",")
        });

    let mut parsed = Vec::new();
    for origin in configured.split(',') {
        let trimmed = origin.trim();
        if trimmed.is_empty() {
            continue;
        }

        match trimmed.parse::<HeaderValue>() {
            Ok(value) => parsed.push(value),
            Err(_) => warn!("invalid CORS origin ignored: {}", trimmed),
        }
    }

    if parsed.is_empty() {
        parsed.push(HeaderValue::from_static("http://localhost:5173"));
    }

    parsed
}

fn cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin(allowed_origins())
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::OPTIONS,
        ])
        .allow_headers([
            header::AUTHORIZATION,
            header::CONTENT_TYPE,
            header::ACCEPT,
            HeaderName::from_static("x-api-key"),
        ])
}

async fn health_check() -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );
    (headers, "SkyBridge Compass Backend Operational")
}

async fn webrtc_config() -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );
    let stun = std::env::var("STUN_URL").ok();
    let turn = std::env::var("TURN_URL").ok();
    let turn_user = std::env::var("TURN_USER").ok();
    let turn_pass = std::env::var("TURN_PASS").ok();
    let status = if stun.is_some() || (turn.is_some() && turn_user.is_some() && turn_pass.is_some())
    {
        "configured"
    } else {
        "missing"
    };
    (
        headers,
        Json(serde_json::json!({
            "stun": stun,
            "turn": turn,
            "turnUser": turn_user,
            "turnPass": turn_pass,
            "status": status,
        })),
    )
}

async fn webrtc_health() -> impl IntoResponse {
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );
    let stun = std::env::var("STUN_URL").ok();
    let turn = std::env::var("TURN_URL").ok();
    let configured = stun.is_some() || turn.is_some();
    (headers, Json(serde_json::json!({ "ok": configured })))
}

/// PNA header constant for testing
pub const PNA_HEADER_NAME: &str = "Access-Control-Allow-Private-Network";
pub const PNA_HEADER_VALUE: &str = "true";

/// Build the application router with PNA middleware for testing
/// Note: Middleware layers are applied in reverse order (last added = outermost)
/// So we add CORS first, then PNA, meaning PNA runs after CORS and can add headers to CORS responses
pub fn build_test_app(state: state::AppState) -> Router {
    let cors = cors_layer();

    Router::new()
        .route("/health", get(health_check))
        .route("/.well-known/openid-configuration", get(oauth::discovery))
        .route(
            "/oauth/authorize",
            get(oauth::authorize).post(oauth::authorize_submit),
        )
        .route("/oauth/token", post(oauth::token))
        .route("/oauth/userinfo", get(oauth::userinfo))
        .route("/oauth/revoke", post(oauth::revoke))
        .route("/dev/oauth/authorize", post(oauth::dev_authorize))
        .route("/api/webrtc/config", get(webrtc_config))
        .route("/api/webrtc/health", get(webrtc_health))
        .route("/api/auth/login", post(handlers::login))
        .route("/api/auth/register", post(handlers::register))
        .route("/api/auth/send-code", post(handlers::send_code))
        .route("/api/auth/verify-code", post(handlers::verify_code))
        .route("/api/auth/profile", get(handlers::get_profile))
        .route("/api/auth/profile", patch(handlers::update_profile))
        .route("/api/auth/avatar", post(handlers::upload_avatar))
        .route("/api/devices", get(handlers::get_devices))
        .route("/api/monitor/stats", get(handlers::get_system_stats))
        .route("/api/transfer/upload", post(handlers::upload_file))
        .route(
            "/api/transfer/session/start",
            post(handlers::start_upload_session),
        )
        .route("/api/transfer/chunk", post(handlers::upload_chunk))
        .route("/api/transfer/session/status", get(handlers::upload_status))
        .route(
            "/api/transfer/session/commit",
            post(handlers::commit_upload),
        )
        .layer(cors)
        .layer(middleware::from_fn(pna_middleware))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use proptest::prelude::*;
    use tower::ServiceExt;

    /// List of all API endpoints for testing
    const API_ENDPOINTS: &[(&str, &str)] = &[
        ("GET", "/health"),
        ("GET", "/api/webrtc/config"),
        ("GET", "/api/webrtc/health"),
        ("GET", "/api/devices"),
        ("GET", "/api/monitor/stats"),
    ];

    /// Strategy for generating valid HTTP methods
    fn http_method_strategy() -> impl Strategy<Value = &'static str> {
        prop_oneof![
            Just("GET"),
            Just("POST"),
            Just("PUT"),
            Just("PATCH"),
            Just("DELETE"),
            Just("OPTIONS"),
        ]
    }

    /// Strategy for generating valid API paths
    fn api_path_strategy() -> impl Strategy<Value = &'static str> {
        prop_oneof![
            Just("/health"),
            Just("/api/webrtc/config"),
            Just("/api/webrtc/health"),
            Just("/api/devices"),
            Just("/api/monitor/stats"),
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: skybridge-compass-web, Property 10: PNA Header Inclusion**
        /// *For any* HTTP response from localhost backend, the Access-Control-Allow-Private-Network
        /// header SHALL be present with value "true".
        /// **Validates: Requirements 7.1**
        #[test]
        fn prop_pna_header_present_in_get_responses(path in api_path_strategy()) {
            // Create a runtime for async test
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(async {
                let state = state::AppState::new();
                let app = build_test_app(state);

                let request = Request::builder()
                    .method("GET")
                    .uri(path)
                    .body(Body::empty())
                    .unwrap();

                let response = app.oneshot(request).await.unwrap();

                // Check that PNA header is present
                let pna_header = response.headers().get(PNA_HEADER_NAME);
                prop_assert!(
                    pna_header.is_some(),
                    "PNA header should be present for GET {}",
                    path
                );

                // Check that PNA header value is "true"
                if let Some(value) = pna_header {
                    prop_assert_eq!(
                        value.to_str().unwrap(),
                        PNA_HEADER_VALUE,
                        "PNA header value should be 'true' for GET {}",
                        path
                    );
                }

                Ok(())
            })?;
        }

        /// **Feature: skybridge-compass-web, Property 10: PNA Header Inclusion (OPTIONS)**
        /// *For any* OPTIONS preflight request, the response SHALL include PNA header
        /// and appropriate CORS headers.
        /// **Validates: Requirements 7.1**
        #[test]
        fn prop_pna_header_in_preflight_response(path in api_path_strategy()) {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(async {
                let state = state::AppState::new();
                let app = build_test_app(state);

                let request = Request::builder()
                    .method("OPTIONS")
                    .uri(path)
                    .header("Origin", "http://localhost:5173")
                    .header("Access-Control-Request-Method", "POST")
                    .body(Body::empty())
                    .unwrap();

                let response = app.oneshot(request).await.unwrap();

                // CORS layer returns 200 OK for preflight requests
                prop_assert!(
                    response.status().is_success(),
                    "Preflight response should be successful for OPTIONS {}",
                    path
                );

                // Check PNA header is present (added by our middleware)
                let pna_header = response.headers().get(PNA_HEADER_NAME);
                prop_assert!(
                    pna_header.is_some(),
                    "PNA header should be present in preflight response for OPTIONS {}",
                    path
                );

                if let Some(value) = pna_header {
                    prop_assert_eq!(
                        value.to_str().unwrap(),
                        PNA_HEADER_VALUE,
                        "PNA header value should be 'true' in preflight for OPTIONS {}",
                        path
                    );
                }

                // Check CORS headers are present (added by CORS layer)
                prop_assert!(
                    response.headers().get("Access-Control-Allow-Origin").is_some(),
                    "Access-Control-Allow-Origin should be present in preflight"
                );

                Ok(())
            })?;
        }

        /// **Feature: skybridge-compass-web, Property 10: PNA Header Inclusion (Consistency)**
        /// *For any* two requests to the same endpoint, both responses SHALL have
        /// identical PNA header values.
        /// **Validates: Requirements 7.1**
        #[test]
        fn prop_pna_header_consistency(path in api_path_strategy()) {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(async {
                let state = state::AppState::new();

                // First request
                let app1 = build_test_app(state.clone());
                let request1 = Request::builder()
                    .method("GET")
                    .uri(path)
                    .body(Body::empty())
                    .unwrap();
                let response1 = app1.oneshot(request1).await.unwrap();
                let pna1 = response1.headers().get(PNA_HEADER_NAME)
                    .map(|v| v.to_str().unwrap().to_string());

                // Second request
                let app2 = build_test_app(state);
                let request2 = Request::builder()
                    .method("GET")
                    .uri(path)
                    .body(Body::empty())
                    .unwrap();
                let response2 = app2.oneshot(request2).await.unwrap();
                let pna2 = response2.headers().get(PNA_HEADER_NAME)
                    .map(|v| v.to_str().unwrap().to_string());

                prop_assert_eq!(
                    pna1, pna2,
                    "PNA header should be consistent across requests to {}",
                    path
                );

                Ok(())
            })?;
        }
    }

    // Unit tests for PNA header
    #[tokio::test]
    async fn test_pna_header_in_health_check() {
        let state = state::AppState::new();
        let app = build_test_app(state);

        let request = Request::builder()
            .method("GET")
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let response = app.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let pna = response.headers().get(PNA_HEADER_NAME);
        assert!(pna.is_some());
        assert_eq!(pna.unwrap().to_str().unwrap(), PNA_HEADER_VALUE);
    }

    #[tokio::test]
    async fn test_pna_header_in_devices_endpoint() {
        let state = state::AppState::new();
        let app = build_test_app(state);

        let request = Request::builder()
            .method("GET")
            .uri("/api/devices")
            .body(Body::empty())
            .unwrap();

        let response = app.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let pna = response.headers().get(PNA_HEADER_NAME);
        assert!(pna.is_some());
        assert_eq!(pna.unwrap().to_str().unwrap(), PNA_HEADER_VALUE);
    }

    #[tokio::test]
    async fn test_pna_header_in_monitor_stats() {
        let state = state::AppState::new();
        let app = build_test_app(state);

        let request = Request::builder()
            .method("GET")
            .uri("/api/monitor/stats")
            .body(Body::empty())
            .unwrap();

        let response = app.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let pna = response.headers().get(PNA_HEADER_NAME);
        assert!(pna.is_some());
        assert_eq!(pna.unwrap().to_str().unwrap(), PNA_HEADER_VALUE);
    }

    #[tokio::test]
    async fn test_preflight_request_has_pna_header() {
        let state = state::AppState::new();
        let app = build_test_app(state);

        let request = Request::builder()
            .method("OPTIONS")
            .uri("/api/auth/login")
            .header("Origin", "http://localhost:5173")
            .header("Access-Control-Request-Method", "POST")
            .body(Body::empty())
            .unwrap();

        let response = app.oneshot(request).await.unwrap();

        // CORS layer returns 200 OK for preflight
        assert!(response.status().is_success());
        // PNA header should still be present
        let pna = response.headers().get(PNA_HEADER_NAME);
        assert!(pna.is_some());
        assert_eq!(pna.unwrap().to_str().unwrap(), PNA_HEADER_VALUE);
    }

    #[tokio::test]
    async fn test_preflight_has_cors_headers() {
        let state = state::AppState::new();
        let app = build_test_app(state);

        let request = Request::builder()
            .method("OPTIONS")
            .uri("/api/devices")
            .header("Origin", "http://localhost:5173")
            .header("Access-Control-Request-Method", "GET")
            .body(Body::empty())
            .unwrap();

        let response = app.oneshot(request).await.unwrap();

        // CORS headers from tower-http CorsLayer
        assert!(response
            .headers()
            .get("Access-Control-Allow-Origin")
            .is_some());
        // PNA header from our middleware
        assert!(response.headers().get(PNA_HEADER_NAME).is_some());
    }
}
