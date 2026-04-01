//! Request handlers for all API endpoints
//!
//! Each handler corresponds to a Supabase Edge Function endpoint.

mod bind_account;
mod bind_account_v2;
mod check_user_id;
mod cli_login;
mod generate_nebula_id;
mod get_binding_status;
mod get_user_profile;
mod send_verification_code;
mod send_verification_code_v2;
mod unbind_account;
mod unbind_account_v2;
mod update_user_id;
mod verify_code;

pub use bind_account::bind_account;
pub use bind_account_v2::bind_account_v2;
pub use check_user_id::check_user_id_availability;
pub use cli_login::{
    approve_cli_login_session, create_cli_login_session, exchange_cli_login_token,
    get_cli_login_session,
};
pub use generate_nebula_id::generate_nebula_id;
pub use get_binding_status::get_binding_status;
pub use get_user_profile::get_user_profile;
pub use send_verification_code::send_verification_code;
pub use send_verification_code_v2::send_verification_code_v2;
pub use unbind_account::unbind_account;
pub use unbind_account_v2::unbind_account_v2;
pub use update_user_id::update_user_id;
pub use verify_code::verify_code;

/// Health check endpoint
pub async fn health_check() -> &'static str {
    "ok"
}



