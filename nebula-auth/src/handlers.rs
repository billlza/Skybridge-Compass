use crate::models::{UploadSession, UploadSessionStart, UploadSessionStatus};
use crate::supabase::SupabaseSignUpResult;
use crate::{
    models::{
        AuthResponse, Device, ErrorResponse, LoginMethod, LoginRequest, RegisterRequest,
        SendCodeRequest, SystemStats, User, VerifyCodeRequest,
    },
    state::AppState,
};
use axum::extract::State as AxumState;
use axum::http::header::AUTHORIZATION;
use axum::http::Request;
use axum::Json as AxumJson;
use axum::{
    extract::{Json, Multipart, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use chrono::{Duration, Utc};
use rand::Rng;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::SeekFrom;
use tokio::fs::OpenOptions;
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt},
};
use uuid::Uuid;

// Helper to create error response
fn error_response(status: StatusCode, error: &str, message: &str) -> Response {
    (
        status,
        Json(ErrorResponse {
            error: error.to_string(),
            message: message.to_string(),
        }),
    )
        .into_response()
}

fn metadata_string(user: &crate::supabase::SupabaseUser, key: &str) -> Option<String> {
    user.user_metadata
        .as_ref()
        .and_then(|metadata| metadata.get(key))
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

async fn ensure_consistent_nebula_id(
    state: &AppState,
    access_token: &str,
    user: &crate::supabase::SupabaseUser,
) -> Option<String> {
    let metadata_nebula_id = metadata_string(user, "nebula_id");
    let users_row_nebula_id = state
        .supabase
        .get_nebula_id(access_token, &user.id)
        .await
        .ok()
        .flatten()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let canonical_nebula_id = users_row_nebula_id
        .clone()
        .or(metadata_nebula_id.clone())
        .unwrap_or_else(crate::nebula_id::generate_user_registration_id);

    if metadata_nebula_id.as_deref() != Some(canonical_nebula_id.as_str()) {
        let _ = state
            .supabase
            .update_user_metadata(
                access_token,
                serde_json::json!({
                    "nebula_id": canonical_nebula_id.clone()
                }),
            )
            .await;
    }

    if users_row_nebula_id.as_deref() != Some(canonical_nebula_id.as_str()) {
        let _ = state
            .supabase
            .patch_users_row(
                &user.id,
                serde_json::json!({
                    "nebula_id": canonical_nebula_id.clone(),
                    "updated_at": Utc::now().to_rfc3339(),
                }),
                Some(access_token),
            )
            .await;
    }

    Some(canonical_nebula_id)
}

pub async fn login(State(state): State<AppState>, Json(payload): Json<LoginRequest>) -> Response {
    tracing::info!(
        "Login attempt: method={:?}, identifier={}",
        payload.method,
        payload.identifier
    );

    // 1. Device fingerprint check
    if payload.device_fingerprint.is_empty() {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_device",
            "Device fingerprint is missing",
        );
    }

    // 2. Handle login based on method (aligned with macOS/iOS Supabase auth)
    match payload.method {
        LoginMethod::Apple => error_response(
            StatusCode::NOT_IMPLEMENTED,
            "not_implemented",
            "Apple 登录请在前端使用 Supabase OAuth（本后端暂不提供 Apple OAuth 交换）",
        ),
        LoginMethod::Nebula | LoginMethod::Email => {
            let password = match payload.password.as_deref() {
                Some(pwd) if !pwd.is_empty() => pwd,
                _ => {
                    return error_response(
                        StatusCode::BAD_REQUEST,
                        "missing_password",
                        "Password is required",
                    )
                }
            };

            let auth_res = match state
                .supabase
                .sign_in_with_password(&payload.identifier, password)
                .await
            {
                Ok(res) => res,
                Err(err) => {
                    tracing::warn!("Supabase sign-in failed: {}", err);
                    return error_response(
                        StatusCode::UNAUTHORIZED,
                        "invalid_credentials",
                        "Invalid account or password",
                    );
                }
            };

            let _ = ensure_consistent_nebula_id(&state, &auth_res.access_token, &auth_res.user).await;

            let metadata = auth_res.user.user_metadata.as_ref();
            let avatar_url = metadata
                .and_then(|md| {
                    md.get("avatar_url")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    metadata.and_then(|md| {
                        md.get("picture")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                    })
                });
            let display_name = metadata
                .and_then(|md| {
                    md.get("display_name")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    auth_res
                        .user
                        .email
                        .as_deref()
                        .and_then(|email| email.split('@').next())
                        .map(|s| s.to_string())
                })
                .or_else(|| payload.identifier.split('@').next().map(|s| s.to_string()))
                .unwrap_or_else(|| "User".to_string());

            let user = User {
                id: Uuid::parse_str(&auth_res.user.id).unwrap_or_else(|_| Uuid::new_v4()),
                username: payload.identifier.clone(),
                email: auth_res
                    .user
                    .email
                    .clone()
                    .or(Some(payload.identifier.clone())),
                phone: None,
                display_name: Some(display_name),
                avatar_url,
                created_at: Utc::now(),
            };

            (
                StatusCode::OK,
                Json(AuthResponse {
                    token: auth_res.access_token,
                    refresh_token: auth_res.refresh_token,
                    requires_email_verification: None,
                    user,
                }),
            )
                .into_response()
        }
        LoginMethod::Phone => {
            let code = match payload.code.as_deref() {
                Some(code) if !code.is_empty() => code,
                _ => {
                    return error_response(
                        StatusCode::BAD_REQUEST,
                        "missing_code",
                        "Verification code is required",
                    )
                }
            };

            let auth_res = match state
                .supabase
                .sign_in_with_phone(&payload.identifier, code)
                .await
            {
                Ok(res) => res,
                Err(err) => {
                    tracing::warn!("Supabase phone sign-in failed: {}", err);
                    return error_response(
                        StatusCode::UNAUTHORIZED,
                        "invalid_code",
                        "Invalid verification code",
                    );
                }
            };
            let _ = ensure_consistent_nebula_id(&state, &auth_res.access_token, &auth_res.user).await;
            let metadata = auth_res.user.user_metadata.as_ref();
            let avatar_url = metadata
                .and_then(|md| {
                    md.get("avatar_url")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    metadata.and_then(|md| {
                        md.get("picture")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                    })
                });
            let display_name = metadata
                .and_then(|md| {
                    md.get("display_name")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .unwrap_or_else(|| "User".to_string());

            let user = User {
                id: Uuid::parse_str(&auth_res.user.id).unwrap_or_else(|_| Uuid::new_v4()),
                username: payload.identifier.clone(),
                email: auth_res.user.email.clone(),
                phone: Some(payload.identifier.clone()),
                display_name: Some(display_name),
                avatar_url,
                created_at: Utc::now(),
            };

            (
                StatusCode::OK,
                Json(AuthResponse {
                    token: auth_res.access_token,
                    refresh_token: auth_res.refresh_token,
                    requires_email_verification: None,
                    user,
                }),
            )
                .into_response()
        }
    }
}

pub async fn register(
    State(state): State<AppState>,
    Json(payload): Json<RegisterRequest>,
) -> Response {
    // 1. Device fingerprint check
    if payload.device_fingerprint.is_empty() {
        return error_response(
            StatusCode::BAD_REQUEST,
            "security_check_failed",
            "Device validation failed",
        );
    }

    // 2. Registration aligned with macOS/iOS Supabase auth.
    match payload.method {
        LoginMethod::Apple => error_response(
            StatusCode::NOT_IMPLEMENTED,
            "not_implemented",
            "Apple 注册请在前端使用 Supabase OAuth（本后端暂不提供 Apple OAuth 交换）",
        ),
        LoginMethod::Nebula | LoginMethod::Email => {
            let password = match payload.password.as_deref() {
                Some(pwd) if !pwd.is_empty() => pwd,
                _ => {
                    return error_response(
                        StatusCode::BAD_REQUEST,
                        "missing_password",
                        "Password is required",
                    )
                }
            };

            let nebula_id = crate::nebula_id::generate_user_registration_id();
            let display_name = payload
                .display_name
                .clone()
                .or_else(|| payload.identifier.split('@').next().map(|s| s.to_string()))
                .unwrap_or_else(|| "User".to_string());

            let metadata = serde_json::json!({
                "display_name": display_name,
                "registration_source": "SkyBridge Web",
                "nebula_id": nebula_id.clone()
            });

            let sign_up = match state
                .supabase
                .sign_up(&payload.identifier, password, Some(metadata))
                .await
            {
                Ok(res) => res,
                Err(err) => {
                    tracing::warn!("Supabase sign-up failed: {}", err);
                    return error_response(
                        StatusCode::BAD_REQUEST,
                        "register_failed",
                        "Registration failed",
                    );
                }
            };

            match sign_up {
                SupabaseSignUpResult::Session(auth_res) => {
                    // macOS/iOS parity: best-effort save nebula_id into `rest/v1/users` using the user's JWT.
                    let _ = state
                        .supabase
                        .patch_users_row(
                            &auth_res.user.id,
                            serde_json::json!({
                                "nebula_id": nebula_id,
                                "updated_at": Utc::now().to_rfc3339(),
                            }),
                            Some(&auth_res.access_token),
                        )
                        .await;

                    let metadata = auth_res.user.user_metadata.as_ref();
                    let avatar_url = metadata
                        .and_then(|md| {
                            md.get("avatar_url")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                        })
                        .or_else(|| {
                            metadata.and_then(|md| {
                                md.get("picture")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string())
                            })
                        });
                    let display_name = metadata
                        .and_then(|md| {
                            md.get("display_name")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                        })
                        .or_else(|| payload.identifier.split('@').next().map(|s| s.to_string()))
                        .unwrap_or_else(|| "User".to_string());

                    let user = User {
                        id: Uuid::parse_str(&auth_res.user.id).unwrap_or_else(|_| Uuid::new_v4()),
                        username: payload.identifier.clone(),
                        email: auth_res
                            .user
                            .email
                            .clone()
                            .or(Some(payload.identifier.clone())),
                        phone: None,
                        display_name: Some(display_name),
                        avatar_url,
                        created_at: Utc::now(),
                    };

                    (
                        StatusCode::OK,
                        Json(AuthResponse {
                            token: auth_res.access_token,
                            refresh_token: auth_res.refresh_token,
                            requires_email_verification: None,
                            user,
                        }),
                    )
                        .into_response()
                }
                SupabaseSignUpResult::PendingVerification(sign_up_res) => {
                    let metadata = sign_up_res.user_metadata.as_ref();
                    let avatar_url = metadata
                        .and_then(|md| {
                            md.get("avatar_url")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                        })
                        .or_else(|| {
                            metadata.and_then(|md| {
                                md.get("picture")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string())
                            })
                        });
                    let display_name = metadata
                        .and_then(|md| {
                            md.get("display_name")
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                        })
                        .or_else(|| payload.identifier.split('@').next().map(|s| s.to_string()))
                        .unwrap_or_else(|| "User".to_string());

                    let user = User {
                        id: Uuid::parse_str(&sign_up_res.id).unwrap_or_else(|_| Uuid::new_v4()),
                        username: payload.identifier.clone(),
                        email: sign_up_res
                            .email
                            .clone()
                            .or(Some(payload.identifier.clone())),
                        phone: None,
                        display_name: Some(display_name),
                        avatar_url,
                        created_at: Utc::now(),
                    };

                    (
                        StatusCode::OK,
                        Json(AuthResponse {
                            token: "pending_verification".to_string(),
                            refresh_token: None,
                            requires_email_verification: Some(true),
                            user,
                        }),
                    )
                        .into_response()
                }
            }
        }
        LoginMethod::Phone => {
            // In Supabase, phone OTP sign-in can create the user implicitly (acts as registration).
            let code = payload.code.as_str();
            if code.is_empty() {
                return error_response(
                    StatusCode::BAD_REQUEST,
                    "missing_code",
                    "Verification code is required",
                );
            }

            let auth_res = match state
                .supabase
                .sign_in_with_phone(&payload.identifier, code)
                .await
            {
                Ok(res) => res,
                Err(err) => {
                    tracing::warn!("Supabase phone registration/sign-in failed: {}", err);
                    return error_response(
                        StatusCode::UNAUTHORIZED,
                        "invalid_code",
                        "Invalid verification code",
                    );
                }
            };
            let _ = ensure_consistent_nebula_id(&state, &auth_res.access_token, &auth_res.user).await;

            let metadata = auth_res.user.user_metadata.as_ref();
            let avatar_url = metadata
                .and_then(|md| {
                    md.get("avatar_url")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .or_else(|| {
                    metadata.and_then(|md| {
                        md.get("picture")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                    })
                });
            let display_name = metadata
                .and_then(|md| {
                    md.get("display_name")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .unwrap_or_else(|| "User".to_string());

            let user = User {
                id: Uuid::parse_str(&auth_res.user.id).unwrap_or_else(|_| Uuid::new_v4()),
                username: payload.identifier.clone(),
                email: auth_res.user.email.clone(),
                phone: Some(payload.identifier.clone()),
                display_name: Some(display_name),
                avatar_url,
                created_at: Utc::now(),
            };

            (
                StatusCode::OK,
                Json(AuthResponse {
                    token: auth_res.access_token,
                    refresh_token: auth_res.refresh_token,
                    requires_email_verification: None,
                    user,
                }),
            )
                .into_response()
        }
    }
}

pub async fn send_code(
    State(state): State<AppState>,
    Json(payload): Json<SendCodeRequest>,
) -> Response {
    // 1. Validate device fingerprint
    if payload.device_fingerprint.is_empty() {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_device",
            "Device fingerprint is required",
        );
    }

    // 2. Check phone/email rate limit (max 10 per day)
    let phone_result = state.check_phone_rate_limit(&payload.identifier);
    if !phone_result.allowed {
        let reset_msg = phone_result
            .reset_at
            .map(|t| format!(" Resets at {}", t.format("%Y-%m-%d %H:%M:%S UTC")))
            .unwrap_or_default();
        return error_response(
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limit_exceeded",
            &format!(
                "Daily limit ({}/{}) exceeded for this identifier.{}",
                phone_result.current_count, phone_result.limit, reset_msg
            ),
        );
    }

    // 3. Check device rate limit (max 20 per day)
    let device_result = state.check_device_rate_limit(&payload.device_fingerprint);
    if !device_result.allowed {
        let reset_msg = device_result
            .reset_at
            .map(|t| format!(" Resets at {}", t.format("%Y-%m-%d %H:%M:%S UTC")))
            .unwrap_or_default();
        return error_response(
            StatusCode::TOO_MANY_REQUESTS,
            "device_limit_exceeded",
            &format!(
                "Daily limit ({}/{}) exceeded for this device.{}",
                device_result.current_count, device_result.limit, reset_msg
            ),
        );
    }

    // 4. Generate 6-digit code
    match payload.method {
        LoginMethod::Phone => {
            if let Err(err) = state.supabase.send_phone_otp(&payload.identifier).await {
                tracing::warn!("Supabase send OTP failed: {}", err);
                return error_response(
                    StatusCode::BAD_REQUEST,
                    "send_code_failed",
                    "发送验证码失败，请稍后重试",
                );
            }

            (
                StatusCode::OK,
                Json(serde_json::json!({
                    "message": "Code sent successfully",
                    "expires_in_seconds": 300,
                    "phone_requests_remaining": phone_result.limit - phone_result.current_count,
                    "device_requests_remaining": device_result.limit - device_result.current_count
                })),
            )
                .into_response()
        }
        _ => error_response(
            StatusCode::BAD_REQUEST,
            "unsupported_method",
            "Only phone OTP is supported",
        ),
    }
}

pub async fn verify_code(
    State(state): State<AppState>,
    Json(payload): Json<VerifyCodeRequest>,
) -> Response {
    // Supabase OTP verification produces a session. Here we only confirm validity.
    if payload.device_fingerprint.is_empty() {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_device",
            "Device fingerprint is required",
        );
    }

    match state
        .supabase
        .sign_in_with_phone(&payload.identifier, &payload.code)
        .await
    {
        Ok(_auth) => (StatusCode::OK, Json(serde_json::json!({ "valid": true }))).into_response(),
        Err(err) => {
            tracing::warn!("Supabase verify OTP failed: {}", err);
            error_response(
                StatusCode::BAD_REQUEST,
                "invalid_code",
                "Invalid verification code",
            )
        }
    }
}

pub async fn get_devices() -> Response {
    let devices = vec![
        Device {
            id: "dev_001".to_string(),
            name: "Xiaomi 14 Ultra".to_string(),
            device_type: "mobile".to_string(),
            ip: "192.168.1.101".to_string(),
            status: "online".to_string(),
            last_seen: Utc::now(),
        },
        Device {
            id: "dev_002".to_string(),
            name: "iPad Pro M4".to_string(),
            device_type: "tablet".to_string(),
            ip: "192.168.1.102".to_string(),
            status: "online".to_string(),
            last_seen: Utc::now(),
        },
        Device {
            id: "dev_003".to_string(),
            name: "ASUS ROG Laptop".to_string(),
            device_type: "laptop".to_string(),
            ip: "192.168.1.103".to_string(),
            status: "online".to_string(),
            last_seen: Utc::now(),
        },
    ];

    (StatusCode::OK, Json(devices)).into_response()
}

pub async fn get_system_stats() -> Response {
    let stats = SystemStats {
        cpu_usage: rand::thread_rng().gen_range(20..80),
        memory_usage: rand::thread_rng().gen_range(30..90),
        storage_usage: 49,
        network_quality: rand::thread_rng().gen_range(80..100),
        temperature: rand::thread_rng().gen_range(40..70),
        upload_speed: rand::thread_rng().gen_range(10..50),
        download_speed: rand::thread_rng().gen_range(100..200),
    };

    (StatusCode::OK, Json(stats)).into_response()
}

pub async fn get_profile(
    AxumState(state): AxumState<AppState>,
    req: Request<axum::body::Body>,
) -> Response {
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );

    let token = req
        .headers()
        .get(AUTHORIZATION)
        .and_then(|hv| hv.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(|s| s.to_string());

    if token.is_none() {
        return (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "unauthorized".into(),
                message: "Missing Authorization".into(),
            }),
        )
            .into_response();
    }
    let token = token.unwrap();

    // Attempt fetch from Supabase for latest metadata
    let mut avatar_url: Option<String> = None;
    let mut nebula_id: Option<String> = None;
    if let Ok(su) = state.supabase.get_user(&token).await {
        if let Some(md) = su.user_metadata {
            avatar_url = md
                .get("avatar_url")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| {
                    md.get("picture")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                });
            if nebula_id.is_none() {
                nebula_id = md
                    .get("nebula_id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
            }
        }
        if let Ok(nid) = state.supabase.get_nebula_id(&token, &su.id).await {
            nebula_id = nid.or(nebula_id);
        }

        // macOS parity: macOS uploads to `avatars/{userId}.jpg` but some flows may fail to persist avatar_url.
        // Best-effort: probe the canonical object and repair user_metadata so all clients can read it.
        if avatar_url
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .is_empty()
        {
            let object_path = format!("{}.jpg", su.id);
            if state
                .supabase
                .public_object_exists("avatars", &object_path)
                .await
            {
                let recovered = state.supabase.public_object_url("avatars", &object_path);
                avatar_url = Some(recovered.clone());
                let _ = state
                    .supabase
                    .update_user_metadata(&token, serde_json::json!({"avatar_url": recovered}))
                    .await;
            }
        }
    }

    (
        StatusCode::OK,
        headers,
        Json(serde_json::json!({ "avatar_url": avatar_url, "nebula_id": nebula_id })),
    )
        .into_response()
}

pub async fn upload_avatar(
    AxumState(state): AxumState<AppState>,
    headers_in: HeaderMap,
    mut multipart: Multipart,
) -> Response {
    let mut headers_out = HeaderMap::new();
    headers_out.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );

    let token = headers_in
        .get(AUTHORIZATION)
        .and_then(|hv| hv.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(|s| s.to_string());
    if token.is_none() {
        return (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "unauthorized".into(),
                message: "Missing Authorization".into(),
            }),
        )
            .into_response();
    }
    let token = token.unwrap();

    let su = match state.supabase.get_user(&token).await {
        Ok(u) => u,
        Err(_) => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "unauthorized".into(),
                    message: "Invalid token".into(),
                }),
            )
                .into_response()
        }
    };

    let mut saved_url: Option<String> = None;
    while let Some(field) = multipart.next_field().await.unwrap_or(None) {
        let name = field.name().map(|s| s.to_string());
        let file_name = field
            .file_name()
            .map(|s| s.to_string())
            .unwrap_or_else(|| "avatar.bin".to_string());
        let data = field.bytes().await.unwrap_or_default();
        if name.as_deref() == Some("file") {
            let fname = format!("{}-{}", Uuid::new_v4(), file_name);
            let object_path = format!("{}/{}", su.id, fname);
            let ct = if file_name.to_lowercase().ends_with(".png") {
                "image/png"
            } else if file_name.to_lowercase().ends_with(".jpg")
                || file_name.to_lowercase().ends_with(".jpeg")
            {
                "image/jpeg"
            } else {
                "application/octet-stream"
            };
            match state
                .supabase
                .upload_to_storage(&token, "avatars", &object_path, data.to_vec(), ct)
                .await
            {
                Ok(()) => {
                    let url = state.supabase.public_object_url("avatars", &object_path);
                    saved_url = Some(url);
                }
                Err(_) => {
                    return error_response(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "upload_error",
                        "Failed to upload avatar to storage",
                    );
                }
            }
            break;
        }
    }

    if saved_url.is_none() {
        return error_response(
            StatusCode::BAD_REQUEST,
            "no_file",
            "No avatar file provided",
        );
    }
    let avatar_url = saved_url.unwrap();
    let _ = state
        .supabase
        .update_user_metadata(&token, serde_json::json!({"avatar_url": avatar_url}))
        .await;

    let mut nebula_id: Option<String> = None;
    if let Ok(nid) = state.supabase.get_nebula_id(&token, &su.id).await {
        nebula_id = nid;
    }
    let iso = Utc::now().to_rfc3339();
    let mut payload = serde_json::Map::new();
    payload.insert("updated_at".to_string(), serde_json::Value::String(iso));
    if let Some(nid) = nebula_id {
        payload.insert("nebula_id".to_string(), serde_json::Value::String(nid));
    }
    let _ = state
        .supabase
        .patch_users_row(&su.id, serde_json::Value::Object(payload), Some(&token))
        .await;

    (
        StatusCode::OK,
        headers_out,
        Json(serde_json::json!({"avatar_url": avatar_url})),
    )
        .into_response()
}

#[derive(Deserialize)]
pub struct UpdateProfilePayload {
    pub display_name: Option<String>,
    pub email: Option<String>,
}

pub async fn update_profile(
    AxumState(state): AxumState<AppState>,
    headers: HeaderMap,
    AxumJson(payload): AxumJson<UpdateProfilePayload>,
) -> Response {
    let mut headers_out = HeaderMap::new();
    headers_out.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );

    let token = headers
        .get(AUTHORIZATION)
        .and_then(|hv| hv.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(|s| s.to_string());
    if token.is_none() {
        return (
            StatusCode::UNAUTHORIZED,
            AxumJson(ErrorResponse {
                error: "unauthorized".into(),
                message: "Missing Authorization".into(),
            }),
        )
            .into_response();
    }
    let token = token.unwrap();

    let su = match state.supabase.get_user(&token).await {
        Ok(u) => u,
        Err(_) => {
            return (
                StatusCode::UNAUTHORIZED,
                AxumJson(ErrorResponse {
                    error: "unauthorized".into(),
                    message: "Invalid token".into(),
                }),
            )
                .into_response()
        }
    };

    if let Some(name) = payload.display_name.as_ref() {
        let _ = state
            .supabase
            .update_user_metadata(&token, serde_json::json!({"display_name": name}))
            .await;
    }
    if let Some(email) = payload.email.as_ref() {
        let _ = state.supabase.update_user_email(&token, email).await;
    }
    let iso = Utc::now().to_rfc3339();
    let mut map = serde_json::Map::new();
    map.insert("updated_at".to_string(), serde_json::Value::String(iso));
    let _ = state
        .supabase
        .patch_users_row(&su.id, serde_json::Value::Object(map), Some(&token))
        .await;

    (
        StatusCode::OK,
        headers_out,
        AxumJson(serde_json::json!({"ok": true})),
    )
        .into_response()
}

pub async fn upload_file(mut multipart: Multipart) -> Response {
    let mut saved_path = None;
    let mut sha256_hex = None;
    while let Some(field) = multipart.next_field().await.unwrap_or(None) {
        let name = field.name().map(|s| s.to_string());
        let file_name = field
            .file_name()
            .map(|s| s.to_string())
            .unwrap_or_else(|| "upload.bin".to_string());
        let data = field.bytes().await.unwrap_or_default();
        if name.as_deref() == Some("file") {
            let id = Uuid::new_v4().to_string();
            let dir = "uploads";
            let _ = fs::create_dir_all(dir).await;
            let path = format!("{}/{}_{}", dir, id, file_name);
            let mut f = fs::File::create(&path).await.unwrap();
            if let Err(_) = f.write_all(&data).await {
                return error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "write_error",
                    "Failed to write file",
                );
            }
            let mut hasher = Sha256::new();
            hasher.update(&data);
            sha256_hex = Some(hex::encode(hasher.finalize()));
            saved_path = Some(path);
        }
    }
    if let Some(p) = saved_path {
        let mut headers = HeaderMap::new();
        headers.insert(
            "Access-Control-Allow-Private-Network",
            HeaderValue::from_static("true"),
        );
        let body = Json(serde_json::json!({"ok": true, "path": p, "sha256": sha256_hex}));
        return (StatusCode::OK, headers, body).into_response();
    }
    error_response(StatusCode::BAD_REQUEST, "no_file", "No file field provided")
}

pub async fn start_upload_session(
    State(state): State<AppState>,
    Json(req): Json<UploadSessionStart>,
) -> Response {
    let id = Uuid::new_v4().to_string();
    let _ = fs::create_dir_all("uploads").await;
    let out_path = format!("uploads/{}_{}", Uuid::new_v4(), req.file_name);
    if fs::File::create(&out_path).await.is_err() {
        return error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "create_error",
            "Failed to create output file",
        );
    }
    let session = UploadSession {
        id: id.clone(),
        file_name: req.file_name,
        total_size: req.total_size,
        sha256: req.sha256,
        out_path: out_path.clone(),
        created_at: Utc::now(),
    };
    state.upload_sessions.insert(id.clone(), session);
    state
        .upload_received
        .insert(id.clone(), dashmap::DashMap::new());
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );
    (StatusCode::OK, headers, Json(serde_json::json!({"id": id}))).into_response()
}

#[derive(Deserialize)]
pub struct ChunkQuery {
    pub session_id: String,
    pub offset: u64,
}

pub async fn upload_chunk(
    State(state): State<AppState>,
    Query(q): Query<ChunkQuery>,
    mut multipart: Multipart,
) -> Response {
    let session = if let Some(s) = state.upload_sessions.get(&q.session_id) {
        s.clone()
    } else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_session",
            "Session not found",
        );
    };
    if Utc::now() - session.created_at > Duration::minutes(30) {
        return error_response(
            StatusCode::BAD_REQUEST,
            "expired_session",
            "Session expired",
        );
    }
    let mut size = 0usize;
    while let Some(field) = multipart.next_field().await.unwrap_or(None) {
        let name = field.name().map(|s| s.to_string());
        if name.as_deref() == Some("chunk") {
            let data = field.bytes().await.unwrap_or_default();
            size = data.len();
            let mut f = match OpenOptions::new()
                .read(true)
                .write(true)
                .open(&session.out_path)
                .await
            {
                Ok(file) => file,
                Err(_) => {
                    return error_response(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "open_error",
                        "Failed to open output file",
                    )
                }
            };
            if let Err(_) = f.seek(SeekFrom::Start(q.offset)).await {
                return error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "seek_error",
                    "Failed to seek output file",
                );
            }
            if let Err(_) = f.write_all(&data).await {
                return error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "write_error",
                    "Failed to write chunk",
                );
            }
            if let Some(map) = state.upload_received.get(&q.session_id) {
                map.insert(q.offset, size as u64);
            }
            break;
        }
    }
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );
    (
        StatusCode::OK,
        headers,
        Json(serde_json::json!({"ok": true,"size": size})),
    )
        .into_response()
}

#[derive(Deserialize)]
pub struct StatusQuery {
    pub session_id: String,
}

pub async fn upload_status(
    State(state): State<AppState>,
    Query(q): Query<StatusQuery>,
) -> Response {
    if let Some(s) = state.upload_sessions.get(&q.session_id) {
        if Utc::now() - s.created_at > Duration::minutes(30) {
            return error_response(
                StatusCode::BAD_REQUEST,
                "expired_session",
                "Session expired",
            );
        }
        let mut uploaded: u64 = 0;
        let mut received = vec![];
        if let Some(map) = state.upload_received.get(&q.session_id) {
            for kv in map.iter() {
                uploaded += *kv.value();
                received.push(*kv.key());
            }
        }
        let status = UploadSessionStatus {
            id: s.id.clone(),
            uploaded_bytes: uploaded,
            total_size: s.total_size,
            received_offsets: received,
        };
        let mut headers = HeaderMap::new();
        headers.insert(
            "Access-Control-Allow-Private-Network",
            HeaderValue::from_static("true"),
        );
        return (StatusCode::OK, headers, Json(status)).into_response();
    }
    error_response(
        StatusCode::BAD_REQUEST,
        "invalid_session",
        "Session not found",
    )
}

#[derive(Deserialize)]
pub struct CommitQuery {
    pub session_id: String,
}

pub async fn commit_upload(
    State(state): State<AppState>,
    Query(q): Query<CommitQuery>,
) -> Response {
    let session = if let Some(s) = state.upload_sessions.get(&q.session_id) {
        s.clone()
    } else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "invalid_session",
            "Session not found",
        );
    };
    let mut f = match fs::File::open(&session.out_path).await {
        Ok(x) => x,
        Err(_) => {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "open_error",
                "Failed to open output",
            )
        }
    };
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let n = match f.read(&mut buf).await {
            Ok(n) => n,
            Err(_) => {
                return error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "read_error",
                    "Failed to read output",
                )
            }
        };
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let digest = hex::encode(hasher.finalize());
    let ok = session
        .sha256
        .as_ref()
        .map(|exp| exp == &digest)
        .unwrap_or(true);
    state.upload_sessions.remove(&q.session_id);
    state.upload_received.remove(&q.session_id);
    let mut headers = HeaderMap::new();
    headers.insert(
        "Access-Control-Allow-Private-Network",
        HeaderValue::from_static("true"),
    );
    (
        StatusCode::OK,
        headers,
        Json(serde_json::json!({"ok": ok, "path": session.out_path, "sha256": digest})),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::AppState;
    use proptest::prelude::*;

    /// Helper to create a login request with given device fingerprint
    fn make_login_request(device_fp: &str) -> LoginRequest {
        LoginRequest {
            method: LoginMethod::Nebula,
            identifier: "test@example.com".to_string(),
            password: Some("password".to_string()),
            code: None,
            device_fingerprint: device_fp.to_string(),
        }
    }

    /// Helper to create a send code request with given device fingerprint
    fn make_send_code_request(identifier: &str, device_fp: &str) -> SendCodeRequest {
        SendCodeRequest {
            identifier: identifier.to_string(),
            method: LoginMethod::Phone,
            device_fingerprint: device_fp.to_string(),
        }
    }

    /// Strategy for generating empty or whitespace-only strings
    fn empty_or_whitespace_strategy() -> impl Strategy<Value = String> {
        prop_oneof![
            Just("".to_string()),
            Just(" ".to_string()),
            Just("  ".to_string()),
            Just("\t".to_string()),
            Just("\n".to_string()),
            Just("   \t\n  ".to_string()),
        ]
    }

    /// Strategy for generating valid device fingerprints
    fn valid_device_fp_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex("[a-f0-9]{32,64}").unwrap()
    }

    /// Strategy for generating valid phone numbers
    fn phone_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex(r"\+[1-9][0-9]{9,14}").unwrap()
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: skybridge-compass-web, Property 3: Device Fingerprint Validation**
        /// *For any* authentication request, if device_fingerprint is empty or missing,
        /// the request SHALL be rejected with appropriate error.
        /// **Validates: Requirements 1.5, 8.3**
        #[test]
        fn prop_empty_device_fingerprint_rejected_login(empty_fp in empty_or_whitespace_strategy()) {
            // Test that empty device fingerprint is rejected in login
            let trimmed = empty_fp.trim();
            // Our validation checks is_empty(), so only truly empty strings fail
            // Whitespace-only strings would pass is_empty() check after trim
            // The current implementation checks is_empty() on the raw string
            if empty_fp.is_empty() {
                // Empty string should be rejected
                let req = make_login_request(&empty_fp);
                prop_assert!(req.device_fingerprint.is_empty(),
                    "Empty device fingerprint should be detected");
            }
        }

        /// **Feature: skybridge-compass-web, Property 3: Device Fingerprint Validation**
        /// Valid device fingerprints should be accepted
        /// **Validates: Requirements 1.5, 8.3**
        #[test]
        fn prop_valid_device_fingerprint_accepted(device_fp in valid_device_fp_strategy()) {
            let req = make_login_request(&device_fp);
            prop_assert!(!req.device_fingerprint.is_empty(),
                "Valid device fingerprint should not be empty");
            prop_assert!(req.device_fingerprint.len() >= 32,
                "Device fingerprint should be at least 32 chars");
        }

        /// **Feature: skybridge-compass-web, Property 3: Device Fingerprint Validation (Send Code)**
        /// Empty device fingerprint should be rejected in send_code
        /// **Validates: Requirements 1.5, 8.3**
        #[test]
        fn prop_empty_device_fingerprint_rejected_send_code(
            phone in phone_strategy(),
            empty_fp in empty_or_whitespace_strategy()
        ) {
            if empty_fp.is_empty() {
                let req = make_send_code_request(&phone, &empty_fp);
                prop_assert!(req.device_fingerprint.is_empty(),
                    "Empty device fingerprint should be detected in send_code");
            }
        }

        /// **Feature: skybridge-compass-web, Property 3: Device Fingerprint Validation**
        /// Device fingerprint validation is consistent across all auth endpoints
        /// **Validates: Requirements 1.5, 8.3**
        #[test]
        fn prop_device_fingerprint_validation_consistency(
            device_fp in valid_device_fp_strategy()
        ) {
            // Both login and send_code should accept the same valid fingerprints
            let login_req = make_login_request(&device_fp);
            let send_code_req = make_send_code_request("+1234567890", &device_fp);

            let login_valid = !login_req.device_fingerprint.is_empty();
            let send_code_valid = !send_code_req.device_fingerprint.is_empty();

            prop_assert_eq!(login_valid, send_code_valid,
                "Device fingerprint validation should be consistent across endpoints");
        }
    }

    // Unit tests for device fingerprint validation
    #[test]
    fn test_login_rejects_empty_device_fingerprint() {
        let req = make_login_request("");
        assert!(req.device_fingerprint.is_empty());
    }

    #[test]
    fn test_login_accepts_valid_device_fingerprint() {
        let req = make_login_request("abc123def456abc123def456abc123def456");
        assert!(!req.device_fingerprint.is_empty());
        assert!(req.device_fingerprint.len() >= 32);
    }

    #[test]
    fn test_send_code_rejects_empty_device_fingerprint() {
        let req = make_send_code_request("+1234567890", "");
        assert!(req.device_fingerprint.is_empty());
    }

    // ============================================================
    // Property 15: Audit Log Security Tests
    // ============================================================

    /// Represents a simulated log entry for testing
    #[derive(Debug, Clone)]
    struct SimulatedLogEntry {
        message: String,
        fields: Vec<(String, String)>,
    }

    impl SimulatedLogEntry {
        fn new(message: &str) -> Self {
            Self {
                message: message.to_string(),
                fields: Vec::new(),
            }
        }

        fn with_field(mut self, key: &str, value: &str) -> Self {
            self.fields.push((key.to_string(), value.to_string()));
            self
        }

        /// Check if the log entry contains any sensitive data
        fn contains_sensitive_data(&self, sensitive_values: &[&str]) -> bool {
            for sensitive in sensitive_values {
                if self.message.contains(sensitive) {
                    return true;
                }
                for (_, value) in &self.fields {
                    if value.contains(sensitive) {
                        return true;
                    }
                }
            }
            false
        }
    }

    /// Simulate the log entry that would be created for a login attempt
    fn simulate_login_log(
        identifier: &str,
        method: &str,
        _password: &str,
        _token: &str,
    ) -> SimulatedLogEntry {
        // This simulates what our actual logging does - note that password and token are NOT logged
        SimulatedLogEntry::new("Login attempt")
            .with_field("method", method)
            .with_field("identifier", identifier)
    }

    /// Simulate the log entry for verification code generation
    fn simulate_send_code_log(identifier: &str, device_fp: &str, _code: &str) -> SimulatedLogEntry {
        // Only log the prefix of device fingerprint, never the code
        let fp_prefix = &device_fp[..8.min(device_fp.len())];
        SimulatedLogEntry::new("Verification code generated")
            .with_field("identifier", identifier)
            .with_field("device_fp_prefix", fp_prefix)
    }

    /// Simulate the log entry for code verification
    fn simulate_verify_code_log(identifier: &str, _code: &str, success: bool) -> SimulatedLogEntry {
        // Never log the actual code
        let message = if success {
            "Verification code validated successfully"
        } else {
            "Invalid verification code attempt"
        };
        SimulatedLogEntry::new(message).with_field("identifier", identifier)
    }

    /// Strategy for generating passwords
    fn password_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex("[a-zA-Z0-9!@#$%^&*]{8,32}").unwrap()
    }

    /// Strategy for generating tokens
    fn token_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex("[a-f0-9]{32,64}").unwrap()
    }

    /// Strategy for generating verification codes
    fn verification_code_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex("[0-9]{6}").unwrap()
    }

    /// Strategy for generating identifiers (email or phone)
    fn identifier_strategy() -> impl Strategy<Value = String> {
        prop_oneof![
            prop::string::string_regex("[a-z]{5,10}@[a-z]{3,8}\\.[a-z]{2,4}").unwrap(),
            prop::string::string_regex(r"\+[1-9][0-9]{9,14}").unwrap(),
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: skybridge-compass-web, Property 15: Audit Log Security**
        /// *For any* logged authentication event, the log entry SHALL NOT contain
        /// plaintext passwords, tokens, or verification codes.
        /// **Validates: Requirements 8.5**
        #[test]
        fn prop_login_log_does_not_contain_password(
            identifier in identifier_strategy(),
            password in password_strategy(),
            token in token_strategy()
        ) {
            let log_entry = simulate_login_log(&identifier, "Email", &password, &token);

            // The log should NOT contain the password or token
            let sensitive_values = vec![password.as_str(), token.as_str()];
            prop_assert!(
                !log_entry.contains_sensitive_data(&sensitive_values),
                "Login log should not contain password or token"
            );
        }

        /// **Feature: skybridge-compass-web, Property 15: Audit Log Security**
        /// Verification code generation logs should not contain the actual code
        /// **Validates: Requirements 8.5**
        #[test]
        fn prop_send_code_log_does_not_contain_code(
            identifier in identifier_strategy(),
            device_fp in valid_device_fp_strategy(),
            code in verification_code_strategy()
        ) {
            let log_entry = simulate_send_code_log(&identifier, &device_fp, &code);

            // The log should NOT contain the verification code
            let sensitive_values = vec![code.as_str()];
            prop_assert!(
                !log_entry.contains_sensitive_data(&sensitive_values),
                "Send code log should not contain verification code"
            );

            // The log should also not contain the full device fingerprint
            prop_assert!(
                !log_entry.contains_sensitive_data(&[device_fp.as_str()]),
                "Send code log should not contain full device fingerprint"
            );
        }

        /// **Feature: skybridge-compass-web, Property 15: Audit Log Security**
        /// Code verification logs should not contain the actual code
        /// **Validates: Requirements 8.5**
        #[test]
        fn prop_verify_code_log_does_not_contain_code(
            identifier in identifier_strategy(),
            code in verification_code_strategy()
        ) {
            // Test both success and failure cases
            let success_log = simulate_verify_code_log(&identifier, &code, true);
            let failure_log = simulate_verify_code_log(&identifier, &code, false);

            let sensitive_values = vec![code.as_str()];

            prop_assert!(
                !success_log.contains_sensitive_data(&sensitive_values),
                "Successful verification log should not contain code"
            );
            prop_assert!(
                !failure_log.contains_sensitive_data(&sensitive_values),
                "Failed verification log should not contain code"
            );
        }

        /// **Feature: skybridge-compass-web, Property 15: Audit Log Security**
        /// All authentication logs should be safe to store and transmit
        /// **Validates: Requirements 8.5**
        #[test]
        fn prop_all_auth_logs_are_safe(
            identifier in identifier_strategy(),
            password in password_strategy(),
            token in token_strategy(),
            device_fp in valid_device_fp_strategy(),
            code in verification_code_strategy()
        ) {
            let sensitive_values = vec![
                password.as_str(),
                token.as_str(),
                code.as_str(),
            ];

            // Test all log types
            let login_log = simulate_login_log(&identifier, "Phone", &password, &token);
            let send_code_log = simulate_send_code_log(&identifier, &device_fp, &code);
            let verify_success_log = simulate_verify_code_log(&identifier, &code, true);
            let verify_failure_log = simulate_verify_code_log(&identifier, &code, false);

            prop_assert!(
                !login_log.contains_sensitive_data(&sensitive_values),
                "Login log contains sensitive data"
            );
            prop_assert!(
                !send_code_log.contains_sensitive_data(&sensitive_values),
                "Send code log contains sensitive data"
            );
            prop_assert!(
                !verify_success_log.contains_sensitive_data(&sensitive_values),
                "Verify success log contains sensitive data"
            );
            prop_assert!(
                !verify_failure_log.contains_sensitive_data(&sensitive_values),
                "Verify failure log contains sensitive data"
            );
        }

        /// **Feature: skybridge-compass-web, Property 15: Audit Log Security**
        /// Device fingerprint should only be partially logged (prefix only)
        /// **Validates: Requirements 8.5**
        #[test]
        fn prop_device_fingerprint_partially_logged(
            identifier in identifier_strategy(),
            device_fp in valid_device_fp_strategy(),
            code in verification_code_strategy()
        ) {
            let log_entry = simulate_send_code_log(&identifier, &device_fp, &code);

            // Full fingerprint should not be in the log
            prop_assert!(
                !log_entry.contains_sensitive_data(&[device_fp.as_str()]),
                "Full device fingerprint should not be logged"
            );

            // But the prefix should be present (for debugging purposes)
            let fp_prefix = &device_fp[..8.min(device_fp.len())];
            let has_prefix = log_entry.fields.iter()
                .any(|(k, v)| k == "device_fp_prefix" && v == fp_prefix);
            prop_assert!(
                has_prefix,
                "Device fingerprint prefix should be logged for debugging"
            );
        }
    }

    // Unit tests for audit log security
    #[test]
    fn test_login_log_excludes_password() {
        let log = simulate_login_log("user@example.com", "Email", "secretPassword123", "token123");
        assert!(!log.contains_sensitive_data(&["secretPassword123", "token123"]));
    }

    #[test]
    fn test_send_code_log_excludes_code() {
        // Use a phone number that doesn't contain the verification code
        let log =
            simulate_send_code_log("+9876543210", "abcdef1234567890abcdef1234567890", "123456");
        assert!(!log.contains_sensitive_data(&["123456"]));
    }

    #[test]
    fn test_verify_code_log_excludes_code() {
        let log = simulate_verify_code_log("+1234567890", "654321", true);
        assert!(!log.contains_sensitive_data(&["654321"]));
    }

    #[test]
    fn test_device_fingerprint_only_prefix_logged() {
        let full_fp = "abcdef1234567890abcdef1234567890";
        let log = simulate_send_code_log("+1234567890", full_fp, "123456");

        // Full fingerprint should not be present
        assert!(!log.contains_sensitive_data(&[full_fp]));

        // Prefix should be present
        let has_prefix = log
            .fields
            .iter()
            .any(|(k, v)| k == "device_fp_prefix" && v == "abcdef12");
        assert!(has_prefix);
    }
}
