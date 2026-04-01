//! Unbind account handler (v1)

use axum::{extract::State, Json};

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{DataResponse, UnbindAccountRequest, UnbindAccountResponse, UserProfileResponse},
    state::AppState,
    utils,
};

/// POST /unbind-account
/// 
/// Unbind an email or phone number from the user's account.
pub async fn unbind_account(
    State(state): State<AppState>,
    auth_user: AuthUser,
    Json(req): Json<UnbindAccountRequest>,
) -> Result<Json<DataResponse<UnbindAccountResponse>>> {
    let unbind_type = req.unbind_type.trim();
    let code = req.code.trim();

    // Validate type
    if !["email", "phone"].contains(&unbind_type) {
        return Err(AppError::bad_request(
            "INVALID_TYPE",
            "解绑类型只能是email或phone",
        ));
    }

    // Nebula ID cannot be unbound
    if unbind_type == "nebula_id" {
        return Err(AppError::forbidden(
            "NEBULA_ID_CANNOT_UNBIND",
            "星云ID不允许解绑，它是您的永久标识符",
        ));
    }

    // Validate code format
    if !utils::is_valid_code(code) {
        return Err(AppError::bad_request(
            "INVALID_CODE_FORMAT",
            "验证码必须是6位数字",
        ));
    }

    // Get current profile
    let profile = db::get_user_profile(&state.db, auth_user.id)
        .await?
        .ok_or_else(|| AppError::not_found("USER_PROFILE_NOT_FOUND", "用户资料不存在"))?;

    // Get current contact value
    let current_contact = match unbind_type {
        "email" => profile.email.as_deref(),
        "phone" => profile.phone.as_deref(),
        _ => None,
    };

    let current_contact = current_contact.ok_or_else(|| {
        AppError::bad_request(
            "NOT_BOUND",
            format!(
                "您尚未绑定{}",
                if unbind_type == "email" { "邮箱" } else { "手机号" }
            ),
        )
    })?;

    let verification = db::find_latest_pending_code(&state.db, auth_user.id, unbind_type, current_contact)
        .await?
        .ok_or_else(|| AppError::bad_request("INVALID_OR_EXPIRED_CODE", "验证码错误或已过期"))?;

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

    db::mark_code_used(&state.db, verification.id).await?;

    // Clear the contact field
    let updated_profile = db::clear_user_contact(&state.db, auth_user.id, unbind_type).await?;

    Ok(Json(DataResponse {
        data: UnbindAccountResponse {
            message: format!(
                "{}解绑成功",
                if unbind_type == "email" { "邮箱" } else { "手机号" }
            ),
            profile: UserProfileResponse::from(updated_profile),
        },
    }))
}



