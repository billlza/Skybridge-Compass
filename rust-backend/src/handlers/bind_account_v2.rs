//! Bind account handler (v2) - uses RPC

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
    models::{BindAccountV2Request, BindAccountV2Response, DataResponse},
    state::AppState,
    utils,
};

/// POST /bind-account-v2
/// 
/// Bind an email or phone using database RPC function.
pub async fn bind_account_v2(
    State(state): State<AppState>,
    auth_user: AuthUser,
    parts: Parts,
    Json(req): Json<BindAccountV2Request>,
) -> Result<Json<DataResponse<BindAccountV2Response>>> {
    let contact_type = req.contact_type.trim();
    let contact_value = req.contact_value.trim();
    let verification_code = req.verification_code.trim();

    // Validate contact_type
    if !["email", "phone"].contains(&contact_type) {
        return Err(AppError::bad_request(
            "INVALID_CONTACT_TYPE",
            "联系方式类型只能是email或phone",
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
    let bind_result = db::call_bind_contact_method(
        &state.http_client,
        &state.config.supabase_url,
        &state.config.supabase_service_key,
        contact_type,
        contact_value,
        verification_code,
        &client_ip,
        &user_agent,
    )
    .await?;

    // Check result
    let success = bind_result.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
    if !success {
        let code = bind_result.get("code").and_then(|v| v.as_str()).unwrap_or("BIND_FAILED");
        let error = bind_result.get("error").and_then(|v| v.as_str()).unwrap_or("绑定失败");
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

    let message = bind_result
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("绑定成功")
        .to_string();

    Ok(Json(DataResponse {
        data: BindAccountV2Response {
            message,
            contact_type: contact_type.to_string(),
            contact_value: contact_value.to_string(),
            binding_status,
            timestamp: Utc::now().to_rfc3339(),
        },
    }))
}




