//! Generate nebula ID handler

use axum::{extract::State, Json};

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{DataResponse, GenerateNebulaIdResponse},
    state::AppState,
};

/// POST /generate-nebula-id
/// 
/// Generate a unique Nebula ID for the authenticated user.
/// Returns error if user already has a Nebula ID.
pub async fn generate_nebula_id(
    State(state): State<AppState>,
    auth_user: AuthUser,
) -> Result<Json<DataResponse<GenerateNebulaIdResponse>>> {
    // Check if user already has a nebula_id
    let profile = db::get_user_profile(&state.db, auth_user.id)
        .await?
        .ok_or_else(|| AppError::not_found("USER_PROFILE_NOT_FOUND", "用户资料不存在"))?;

    if profile.nebula_id.is_some() {
        return Err(AppError::bad_request(
            "NEBULA_ID_EXISTS",
            "您已经有星云ID，无需重复生成",
        ));
    }

    // Generate new nebula_id
    let nebula_id = db::generate_nebula_id(&state.db, auth_user.id).await?;

    Ok(Json(DataResponse {
        data: GenerateNebulaIdResponse {
            nebula_id,
            message: "星云ID生成成功".to_string(),
        },
    }))
}




