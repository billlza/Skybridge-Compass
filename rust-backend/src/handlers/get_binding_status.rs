//! Get binding status handler

use axum::{extract::State, Json};
use chrono::Utc;

use crate::{
    auth::AuthUser,
    db,
    error::Result,
    models::{BindingHistoryItem, BindingStatusResponse, DataResponse, PendingVerification},
    state::AppState,
    utils,
};

/// GET/POST /get-binding-status
/// 
/// Get the user's current binding status, history, and pending verifications.
pub async fn get_binding_status(
    State(state): State<AppState>,
    auth_user: AuthUser,
) -> Result<Json<DataResponse<BindingStatusResponse>>> {
    // Get binding status via RPC
    let binding_status = db::call_get_binding_status(
        &state.http_client,
        &state.config.supabase_url,
        &state.config.supabase_service_key,
        &auth_user.token,
        auth_user.id,
    )
    .await
    .unwrap_or(serde_json::json!(null));

    // Get binding history
    let history = db::get_binding_history(&state.db, auth_user.id, 10).await?;
    let binding_history: Vec<BindingHistoryItem> = history
        .into_iter()
        .map(|record| BindingHistoryItem {
            contact_type: record.contact_type.clone(),
            action: record.action,
            contact_masked: utils::mask_contact(&record.contact_type, &record.contact_value),
            created_at: record.created_at,
            ip_address: record.ip_address,
        })
        .collect();

    // Get pending verification codes
    let pending_codes = db::get_pending_codes(&state.db, auth_user.id).await?;
    let pending_verifications: Vec<PendingVerification> = pending_codes
        .into_iter()
        .map(|code| {
            let contact_type = code.contact_type.clone().or(code.code_type.clone()).unwrap_or_default();
            let contact_value = code.contact_value.clone().or(code.contact.clone()).unwrap_or_default();
            PendingVerification {
                contact_type: contact_type.clone(),
                contact_masked: utils::mask_contact(&contact_type, &contact_value),
                expires_at: code.expires_at,
                created_at: code.created_at,
            }
        })
        .collect();

    Ok(Json(DataResponse {
        data: BindingStatusResponse {
            binding_status,
            binding_history,
            pending_verifications,
            timestamp: Utc::now().to_rfc3339(),
        },
    }))
}




