//! Error handling module for the Sinan backend
//!
//! Provides a unified error type that can be converted to HTTP responses.

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;

/// Application error type with automatic HTTP response conversion
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Unauthorized: {message}")]
    Unauthorized { code: String, message: String },

    #[error("Bad request: {message}")]
    BadRequest { code: String, message: String },

    #[error("Not found: {message}")]
    NotFound { code: String, message: String },

    #[error("Conflict: {message}")]
    Conflict { code: String, message: String },

    #[error("Too many requests: {message}")]
    TooManyRequests { code: String, message: String },

    #[error("Forbidden: {message}")]
    Forbidden { code: String, message: String },

    #[error("Method not allowed")]
    MethodNotAllowed,

    #[error("Internal server error: {0}")]
    Internal(String),

    #[error("Database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("Request error: {0}")]
    Request(#[from] reqwest::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Validation error: {0}")]
    Validation(String),
}

/// Error response body
#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub error: ErrorDetail,
}

#[derive(Debug, Serialize)]
pub struct ErrorDetail {
    pub code: String,
    pub message: String,
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match &self {
            AppError::Unauthorized { code, message } => {
                (StatusCode::UNAUTHORIZED, code.clone(), message.clone())
            }
            AppError::BadRequest { code, message } => {
                (StatusCode::BAD_REQUEST, code.clone(), message.clone())
            }
            AppError::NotFound { code, message } => {
                (StatusCode::NOT_FOUND, code.clone(), message.clone())
            }
            AppError::Conflict { code, message } => {
                (StatusCode::CONFLICT, code.clone(), message.clone())
            }
            AppError::TooManyRequests { code, message } => {
                (StatusCode::TOO_MANY_REQUESTS, code.clone(), message.clone())
            }
            AppError::Forbidden { code, message } => {
                (StatusCode::FORBIDDEN, code.clone(), message.clone())
            }
            AppError::MethodNotAllowed => (
                StatusCode::METHOD_NOT_ALLOWED,
                "METHOD_NOT_ALLOWED".to_string(),
                "Method not allowed".to_string(),
            ),
            AppError::Internal(msg) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL_ERROR".to_string(),
                {
                    tracing::error!("Internal application error: {}", msg);
                    "Internal server error".to_string()
                },
            ),
            AppError::Database(e) => {
                tracing::error!("Database error: {:?}", e);
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "DATABASE_ERROR".to_string(),
                    "Database operation failed".to_string(),
                )
            }
            AppError::Request(e) => {
                tracing::error!("Request error: {:?}", e);
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "REQUEST_ERROR".to_string(),
                    "External request failed".to_string(),
                )
            }
            AppError::Json(e) => (
                StatusCode::BAD_REQUEST,
                "JSON_ERROR".to_string(),
                format!("Invalid JSON: {}", e),
            ),
            AppError::Validation(msg) => (
                StatusCode::BAD_REQUEST,
                "VALIDATION_ERROR".to_string(),
                msg.clone(),
            ),
        };

        let body = ErrorResponse {
            error: ErrorDetail { code, message },
        };

        (status, Json(body)).into_response()
    }
}

/// Convenience constructors for common errors
impl AppError {
    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::Unauthorized {
            code: "UNAUTHORIZED".to_string(),
            message: message.into(),
        }
    }

    pub fn invalid_token() -> Self {
        Self::Unauthorized {
            code: "UNAUTHORIZED".to_string(),
            message: "无效的授权token".to_string(),
        }
    }

    pub fn missing_auth() -> Self {
        Self::Unauthorized {
            code: "UNAUTHORIZED".to_string(),
            message: "缺少授权头".to_string(),
        }
    }

    pub fn bad_request(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::BadRequest {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn not_found(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::NotFound {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn conflict(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Conflict {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn too_many_requests(message: impl Into<String>) -> Self {
        Self::TooManyRequests {
            code: "TOO_FREQUENT".to_string(),
            message: message.into(),
        }
    }

    pub fn forbidden(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Forbidden {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }
}

/// Result type alias for handlers
pub type Result<T> = std::result::Result<T, AppError>;



