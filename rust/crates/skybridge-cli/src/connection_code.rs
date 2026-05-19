mod connect;
mod create;
mod inline_runtime;
mod inline_state;

pub(crate) use connect::connect_code;
pub(crate) use create::code_create;

#[cfg(test)]
use crate::CodeCreateArgs;
#[cfg(test)]
use anyhow::Result;
#[cfg(test)]
use create::code_create_with_client;
#[cfg(test)]
use inline_state::{InlineConnectState, InlineLifecycleDecision};
#[cfg(test)]
use serde_json::json;
#[cfg(test)]
use skybridge_agent::{ensure_device_identity, load_session_registry, resolve_paths};
#[cfg(test)]
use skybridge_core::{
    RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState, SignalServerClient,
};

#[cfg(test)]
mod tests;
