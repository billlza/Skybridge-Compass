//! Verify code handler

use axum::{extract::State, Json};

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{DataResponse, VerifyCodeRequest, VerifyCodeResponse},
    state::AppState,
    utils,
};

/// POST /verify-code
/// 
/// Verify a verification code without performing any action.
pub async fn verify_code(
    State(state): State<AppState>,
    auth_user: AuthUser,
    Json(req): Json<VerifyCodeRequest>,
) -> Result<Json<DataResponse<VerifyCodeResponse>>> {
    let code = req.code.trim();
    let code_type = req.code_type.trim();
    let contact = req.contact.trim();

    // Validate type
    if !["email", "phone"].contains(&code_type) {
        return Err(AppError::bad_request(
            "INVALID_TYPE",
            "验证类型只能是email或phone",
        ));
    }

    // Validate code format
    if !utils::is_valid_code(code) {
        return Err(AppError::bad_request(
            "INVALID_CODE_FORMAT",
            "验证码必须是6位数字",
        ));
    }

    let verification = db::find_latest_pending_code(&state.db, auth_user.id, code_type, contact)
        .await?
        .ok_or_else(|| AppError::bad_request("INVALID_OR_EXPIRED_CODE", "验证码错误或已过期"))?;

    // Check attempts limit
    if verification.attempts >= 5 {
        return Err(AppError::too_many_requests(
            "验证失败次数过多，请重新获取验证码",
        ));
    }

    if verification.code != code {
        let attempts = db::increment_code_attempts(&state.db, verification.id).await?;
        if attempts >= 5 {
            return Err(AppError::too_many_requests(
                "验证失败次数过多，请重新获取验证码",
            ));
        }
        return Err(AppError::bad_request(
            "INVALID_OR_EXPIRED_CODE",
            "验证码错误或已过期",
        ));
    }

    // Mark code as used
    db::mark_code_used(&state.db, verification.id).await?;

    Ok(Json(DataResponse {
        data: VerifyCodeResponse {
            message: "验证码验证成功".to_string(),
            verified: true,
        },
    }))
}



