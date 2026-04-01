//! Update user ID handler

use axum::{extract::State, Json};
use chrono::Utc;
use regex::Regex;

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{DataResponse, UpdateUserIdRequest, UpdateUserIdResponse},
    state::AppState,
};

/// PUT /update-user-id
/// 
/// Update the user's custom user ID.
pub async fn update_user_id(
    State(state): State<AppState>,
    auth_user: AuthUser,
    Json(req): Json<UpdateUserIdRequest>,
) -> Result<Json<DataResponse<UpdateUserIdResponse>>> {
    let custom_user_id = req.custom_user_id.trim();

    // Validate: not empty
    if custom_user_id.is_empty() {
        return Err(AppError::bad_request("INVALID_INPUT", "用户ID不能为空"));
    }

    // Validate: format (letters, numbers, Chinese, underscore, hyphen)
    let id_regex = Regex::new(r"^[a-zA-Z0-9_\u4e00-\u9fff-]+$").unwrap();
    if !id_regex.is_match(custom_user_id) {
        return Err(AppError::bad_request(
            "INVALID_FORMAT",
            "用户ID只能包含字母、数字、汉字、下划线和连字符",
        ));
    }

    // Validate: length (3-30 characters)
    if custom_user_id.len() < 3 || custom_user_id.len() > 30 {
        return Err(AppError::bad_request(
            "INVALID_LENGTH",
            "用户ID长度必须在3-30个字符之间",
        ));
    }

    // Check if ID is available
    if !db::is_custom_user_id_available(&state.db, custom_user_id, auth_user.id).await? {
        return Err(AppError::conflict(
            "ID_ALREADY_EXISTS",
            "此用户ID已被其他用户使用，请选择其他ID",
        ));
    }

    // Update the user ID
    let updated_profile = db::update_custom_user_id(&state.db, auth_user.id, custom_user_id).await?;

    Ok(Json(DataResponse {
        data: UpdateUserIdResponse {
            custom_user_id: updated_profile.custom_user_id.unwrap_or_default(),
            updated_at: updated_profile
                .updated_at
                .map(|t| t.to_rfc3339())
                .unwrap_or_else(|| Utc::now().to_rfc3339()),
            message: "用户ID更新成功".to_string(),
        },
    }))
}




