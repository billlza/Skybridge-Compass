mod connect;
mod create;

use anyhow::Context;

pub(crate) use connect::connect_code;
pub(crate) use create::code_create;

async fn cleanup_managed_session_attempt(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    expected_registration_id: &str,
    reason: &str,
) -> anyhow::Result<bool> {
    skybridge_agent::disconnect_managed_session_if_registration(
        paths,
        session_id,
        expected_registration_id,
        Some(reason.to_owned()),
    )
    .await
    .context("failed to close managed session with a durable stopped retry anchor")
}

#[cfg(test)]
use crate::CodeCreateArgs;
#[cfg(test)]
use anyhow::Result;
#[cfg(test)]
use create::code_create_with_client;
#[cfg(test)]
use serde_json::json;
#[cfg(test)]
use skybridge_agent::{
    ensure_device_identity, load_session_registry, resolve_paths, upsert_session_runtime,
};
#[cfg(test)]
use skybridge_core::{
    RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState,
    SignalServerClient,
};

#[cfg(test)]
mod tests;
