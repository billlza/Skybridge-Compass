//! Check user ID availability handler

use axum::{extract::State, Json};
use regex::Regex;

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{CheckUserIdRequest, CheckUserIdResponse, DataResponse},
    state::AppState,
};

/// POST /check-user-id-availability
/// 
/// Check if a custom user ID is available for use.
pub async fn check_user_id_availability(
    State(state): State<AppState>,
    auth_user: AuthUser,
    Json(req): Json<CheckUserIdRequest>,
) -> Result<Json<DataResponse<CheckUserIdResponse>>> {
    let custom_user_id = req.custom_user_id.trim();

    // Validate: not empty
    if custom_user_id.is_empty() {
        return Ok(Json(DataResponse {
            data: CheckUserIdResponse {
                available: false,
                reason: "用户ID不能为空".to_string(),
            },
        }));
    }

    // Validate: format (letters, numbers, Chinese, underscore, hyphen)
    let id_regex = Regex::new(r"^[a-zA-Z0-9_\u4e00-\u9fff-]+$").unwrap();
    if !id_regex.is_match(custom_user_id) {
        return Ok(Json(DataResponse {
            data: CheckUserIdResponse {
                available: false,
                reason: "用户ID只能包含字母、数字、汉字、下划线和连字符".to_string(),
            },
        }));
    }

    // Validate: length (3-30 characters)
    if custom_user_id.len() < 3 || custom_user_id.len() > 30 {
        return Ok(Json(DataResponse {
            data: CheckUserIdResponse {
                available: false,
                reason: "用户ID长度必须在3-30个字符之间".to_string(),
            },
        }));
    }

    // Check availability in database
    let is_available = db::is_custom_user_id_available(&state.db, custom_user_id, auth_user.id)
        .await
        .map_err(|e| AppError::internal(format!("检查用户ID时发生错误: {}", e)))?;

    Ok(Json(DataResponse {
        data: CheckUserIdResponse {
            available: is_available,
            reason: if is_available {
                "用户ID可用".to_string()
            } else {
                "此用户ID已被其他用户使用".to_string()
            },
        },
    }))
}




