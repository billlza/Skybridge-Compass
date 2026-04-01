//! Send verification code handler (v2) - with enhanced features

use axum::{
    extract::State,
    http::request::Parts,
    Json,
};
use chrono::{Duration, Utc};

use crate::{
    auth::{get_client_ip, AuthUser},
    db,
    error::{AppError, Result},
    models::{DataResponse, SendVerificationCodeV2Request, SendVerificationCodeV2Response},
    state::AppState,
    utils,
};

/// POST /send-verification-code-v2
/// 
/// Send a verification code with enhanced features (purpose tracking, IP logging).
pub async fn send_verification_code_v2(
    State(state): State<AppState>,
    auth_user: AuthUser,
    parts: Parts,
    Json(req): Json<SendVerificationCodeV2Request>,
) -> Result<Json<DataResponse<SendVerificationCodeV2Response>>> {
    let contact_type = req.contact_type.trim();
    let contact_value = req.contact_value.trim();
    let purpose = req.purpose.trim();

    // Validate contact_type
    if !["email", "phone"].contains(&contact_type) {
        return Err(AppError::bad_request(
            "INVALID_CONTACT_TYPE",
            "联系方式类型只能是email或phone",
        ));
    }

    // Validate purpose
    if !["bind", "unbind", "verify"].contains(&purpose) {
        return Err(AppError::bad_request(
            "INVALID_PURPOSE",
            "目的只能是bind、unbind或verify",
        ));
    }

    // Validate contact format
    if contact_type == "email" && !utils::is_valid_email(contact_value) {
        return Err(AppError::bad_request(
            "INVALID_EMAIL_FORMAT",
            "邮箱格式不正确",
        ));
    }
    if contact_type == "phone" && !utils::is_valid_phone(contact_value) {
        return Err(AppError::bad_request(
            "INVALID_PHONE_FORMAT",
            "手机号格式不正确，请输入11位中国大陆手机号",
        ));
    }

    // Check rate limit (60 seconds cooldown)
    if db::has_recent_code(&state.db, auth_user.id, contact_type, contact_value, 60).await? {
        return Err(AppError::too_many_requests(
            "验证码发送过于频繁，请60秒后再试",
        ));
    }

    // Get client IP
    let client_ip = get_client_ip(&parts);

    // Generate code
    let code = utils::generate_verification_code();
    let expires_at = Utc::now() + Duration::minutes(5);

    // Save to database
    db::create_verification_code(
        &state.db,
        auth_user.id,
        &code,
        contact_type,
        contact_value,
        expires_at,
        Some(&client_ip),
    )
    .await?;

    // TODO: Actually send the code via email/SMS service (e.g., Aliyun)
    let send_success = simulate_send_code(contact_type, contact_value, &code).await;

    if !send_success {
        // Delete the code if sending failed
        db::delete_verification_code(&state.db, auth_user.id, contact_value, &code).await?;
        return Err(AppError::internal(format!(
            "{}发送失败，请稍后重试",
            if contact_type == "email" { "邮件" } else { "短信" }
        )));
    }

    Ok(Json(DataResponse {
        data: SendVerificationCodeV2Response {
            message: format!(
                "验证码已发送到您的{}",
                if contact_type == "email" { "邮箱" } else { "手机" }
            ),
            contact_type: contact_type.to_string(),
            contact_masked: utils::mask_contact(contact_type, contact_value),
            expires_in: 300,      // 5 minutes
            can_resend_after: 60, // 60 seconds
        },
    }))
}

/// Simulate sending verification code (replace with actual service integration)
async fn simulate_send_code(contact_type: &str, contact_value: &str, _code: &str) -> bool {
    tracing::info!(
        "[{}] Verification code issued for {}",
        contact_type.to_uppercase(),
        utils::mask_contact(contact_type, contact_value)
    );
    
    // Simulate 95% success rate for email, 90% for SMS
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let threshold = if contact_type == "email" { 0.05 } else { 0.10 };
    rng.gen::<f64>() > threshold
}


