//! Authentication module
//!
//! Provides authentication services and NebulaID generation compatible
//! with macOS and Android implementations.

#![allow(missing_docs)]

mod nebula_id;
mod service;
mod session;

pub use nebula_id::{NebulaId, NebulaIdError, NebulaIdGenerator};
pub use service::{AuthEndpoint, AuthError, AuthenticationService, SupabaseConfig};
pub use session::{AuthSession, SessionToken, UserProfile};
