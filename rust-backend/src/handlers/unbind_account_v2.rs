//! Unbind account handler (v2) - uses RPC

use axum::{
    extract::State,
    http::request::Parts,
    Json,
};
use chrono::Utc;

use crate::{
    auth::{get_client_ip, get_user_agent, AuthUser},
    db,
    error::{AppError, Result},
    models::{DataResponse, UnbindAccountV2Request, UnbindAccountV2Response},
    state::AppState,
    utils,
};

/// POST /unbind-account-v2
/// 
/// Unbind contact using database RPC function.
pub async fn unbind_account_v2(
    State(state): State<AppState>,
    auth_user: AuthUser,
    parts: Parts,
    Json(req): Json<UnbindAccountV2Request>,
) -> Result<Json<DataResponse<UnbindAccountV2Response>>> {
    let contact_type = req.contact_type.trim();
    let verification_code = req.verification_code.trim();

    // Validate contact_type
    if !["email", "phone"].contains(&contact_type) {
        return Err(AppError::bad_request(
            "INVALID_CONTACT_TYPE",
            "联系方式类型只能是email或phone",
        ));
    }

    // Nebula ID cannot be unbound
    if contact_type == "nebula_id" {
        return Err(AppError::forbidden(
            "NEBULA_ID_CANNOT_UNBIND",
            "星云ID不允许解绑，它是您的永久标识符",
        ));
    }

    // Validate code format
    if !utils::is_valid_code(verification_code) {
        return Err(AppError::bad_request(
            "INVALID_CODE_FORMAT",
            "验证码必须是6位数字",
        ));
    }

    let client_ip = get_client_ip(&parts);
    let user_agent = get_user_agent(&parts);

    // Call RPC function
    let unbind_result = db::call_unbind_contact_method(
        &state.http_client,
        &state.config.supabase_url,
        &state.config.supabase_service_key,
        contact_type,
        verification_code,
        &client_ip,
        &user_agent,
    )
    .await?;

    // Check result
    let success = unbind_result.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
    if !success {
        let code = unbind_result.get("code").and_then(|v| v.as_str()).unwrap_or("UNBIND_FAILED");
        let error = unbind_result.get("error").and_then(|v| v.as_str()).unwrap_or("解绑失败");
        return Err(AppError::bad_request(code, error));
    }

    // Get updated binding status
    let binding_status = db::call_get_binding_status(
        &state.http_client,
        &state.config.supabase_url,
        &state.config.supabase_service_key,
        &auth_user.token,
        auth_user.id,
    )
    .await
    .ok();

    let message = unbind_result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("解绑成功")
        .to_string();

    let previous_value = unbind_result
        .get("previous_value")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    Ok(Json(DataResponse {
        data: UnbindAccountV2Response {
            message,
            contact_type: contact_type.to_string(),
            previous_value,
            binding_status,
            timestamp: Utc::now().to_rfc3339(),
        },
    }))
}




