//! Get user profile handler

use axum::{extract::State, Json};

use crate::{
    auth::AuthUser,
    db,
    error::Result,
    models::{DataResponse, UserProfileResponse},
    state::AppState,
};

/// GET /get-user-profile
/// 
/// Retrieve the authenticated user's profile. Creates a basic profile if none exists.
pub async fn get_user_profile(
    State(state): State<AppState>,
    auth_user: AuthUser,
) -> Result<Json<DataResponse<UserProfileResponse>>> {
    // Try to get existing profile
    let profile = match db::get_user_profile(&state.db, auth_user.id).await? {
        Some(p) => p,
        None => {
            // Create basic profile if not found
            tracing::info!("Creating new profile for user: {}", auth_user.id);
            db::create_user_profile(
                &state.db,
                auth_user.id,
                auth_user.email.as_deref(),
                "email",
            )
            .await?
        }
    };

    Ok(Json(DataResponse {
        data: UserProfileResponse::from(profile),
    }))
}




