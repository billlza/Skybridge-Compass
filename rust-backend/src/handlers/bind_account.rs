//! Bind account handler (v1)

use axum::{extract::State, Json};

use crate::{
    auth::AuthUser,
    db,
    error::{AppError, Result},
    models::{BindAccountRequest, BindAccountResponse, DataResponse, UserProfileResponse},
    state::AppState,
    utils,
};

/// POST /bind-account
/// 
/// Bind an email or phone number to the user's account.
pub async fn bind_account(
    State(state): State<AppState>,
    auth_user: AuthUser,
    Json(req): Json<BindAccountRequest>,
) -> Result<Json<DataResponse<BindAccountResponse>>> {
    let bind_type = req.bind_type.trim();
    let contact = req.contact.trim();

    // Validate type
    if !["email", "phone"].contains(&bind_type) {
        return Err(AppError::bad_request(
            "INVALID_TYPE",
            "绑定类型只能是email或phone",
        ));
    }

    // Validate contact format
    if bind_type == "email" && !utils::is_valid_email(contact) {
        return Err(AppError::bad_request("INVALID_EMAIL", "邮箱格式不正确"));
    }
    if bind_type == "phone" && !utils::is_valid_phone(contact) {
        return Err(AppError::bad_request("INVALID_PHONE", "手机号格式不正确"));
    }

    // Require verification code
    let code = req.code.as_deref().ok_or_else(|| {
        AppError::bad_request(
            "CODE_REQUIRED",
            format!(
                "绑定{}需要验证码",
                if bind_type == "email" { "邮箱" } else { "手机号" }
            ),
        )
    })?;

    // Validate code format
    if !utils::is_valid_code(code) {
        return Err(AppError::bad_request(
            "INVALID_CODE_FORMAT",
            "验证码必须是6位数字",
        ));
    }

    let verification = db::find_latest_pending_code(&state.db, auth_user.id, bind_type, contact)
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

    // Check if contact is already bound to another user
    if db::is_contact_bound_to_other(&state.db, bind_type, contact, auth_user.id).await? {
        return Err(AppError::conflict(
            "ALREADY_BOUND",
            format!(
                "该{}已被其他用户绑定",
                if bind_type == "email" { "邮箱" } else { "手机号" }
            ),
        ));
    }

    db::mark_code_used(&state.db, verification.id).await?;

    // Get current profile
    let profile = db::get_user_profile(&state.db, auth_user.id)
        .await?
        .ok_or_else(|| AppError::not_found("USER_PROFILE_NOT_FOUND", "用户资料不存在"))?;

    // Generate nebula_id if not exists
    let nebula_id = if profile.nebula_id.is_none() {
        Some(db::generate_nebula_id(&state.db, auth_user.id).await?)
    } else {
        None
    };

    // Update profile
    let updated_profile = db::update_user_profile(
        &state.db,
        auth_user.id,
        if bind_type == "email" { Some(contact) } else { None },
        if bind_type == "phone" { Some(contact) } else { None },
        nebula_id.as_deref(),
        None,
    )
    .await?;

    Ok(Json(DataResponse {
        data: BindAccountResponse {
            message: format!(
                "{}绑定成功",
                if bind_type == "email" { "邮箱" } else { "手机号" }
            ),
            profile: UserProfileResponse::from(updated_profile),
        },
    }))
}
