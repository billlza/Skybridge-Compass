//! Send verification code handler (v1)

use axum::{extract::State, Json};
use chrono::{Duration, Utc};

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{DataResponse, SendVerificationCodeRequest, SendVerificationCodeResponse},
    state::AppState,
    utils,
};

/// POST /send-verification-code
/// 
/// Send a verification code to the user's email or phone.
pub async fn send_verification_code(
    State(state): State<AppState>,
    auth_user: AuthUser,
    Json(req): Json<SendVerificationCodeRequest>,
) -> Result<Json<DataResponse<SendVerificationCodeResponse>>> {
    let code_type = req.code_type.trim();
    let contact = req.contact.trim();

    // Validate type
    if !["email", "phone"].contains(&code_type) {
        return Err(AppError::bad_request(
            "INVALID_TYPE",
            "验证类型只能是email或phone",
        ));
    }

    // Validate contact format
    if code_type == "email" && !utils::is_valid_email(contact) {
        return Err(AppError::bad_request("INVALID_EMAIL", "邮箱格式不正确"));
    }
    if code_type == "phone" && !utils::is_valid_phone(contact) {
        return Err(AppError::bad_request("INVALID_PHONE", "手机号格式不正确"));
    }

    // Check rate limit (60 seconds cooldown)
    if db::has_recent_code(&state.db, auth_user.id, code_type, contact, 60).await? {
        return Err(AppError::too_many_requests(
            "验证码发送过于频繁，请60秒后再试",
        ));
    }

    // Generate code
    let code = utils::generate_verification_code();
    let expires_at = Utc::now() + Duration::minutes(5);

    // Save to database
    db::create_verification_code(
        &state.db,
        auth_user.id,
        &code,
        code_type,
        contact,
        expires_at,
        None,
    )
    .await?;

    // TODO: Actually send the code via email/SMS service
    // For now, log it (in production, integrate with actual service)
    tracing::info!(
        "Verification code issued for {} ({})",
        utils::mask_contact(code_type, contact),
        code_type
    );

    Ok(Json(DataResponse {
        data: SendVerificationCodeResponse {
            message: format!(
                "验证码已发送到 {}",
                if code_type == "email" { "邮箱" } else { "手机" }
            ),
            expires_at: expires_at.to_rfc3339(),
        },
    }))
}



