use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::ProtocolSigningAlgorithm;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthState {
    LoggedOut,
    LoggedIn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnrollmentStatus {
    Unenrolled,
    PendingApproval,
    Enrolled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentRuntimeStatus {
    Starting,
    Healthy,
    Degraded,
    Stopping,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceIdentitySummary {
    pub device_id: String,
    pub device_name: String,
    #[serde(default = "default_protocol_signing_algorithm")]
    pub protocol_signing_algorithm: ProtocolSigningAlgorithm,
    #[serde(default, with = "base64_standard::option")]
    pub protocol_public_key_bytes: Option<Vec<u8>>,
    pub public_key_fingerprint: Option<String>,
    pub enrollment_status: EnrollmentStatus,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalIdentityState {
    pub schema_version: u32,
    pub account_id: Option<String>,
    pub auth_state: AuthState,
    pub device: DeviceIdentitySummary,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentHealthSnapshot {
    pub schema_version: u32,
    /// Random identifier for the process instance that owns the runtime lease.
    #[serde(default)]
    pub instance_id: String,
    pub status: AgentRuntimeStatus,
    pub pid: u32,
    pub state_dir: String,
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
    pub active_sessions: usize,
    /// Current transfer count, or `None` until the runtime wires an authoritative
    /// cross-session counter. Never use zero as a stand-in for unknown.
    #[serde(default)]
    pub active_transfers: Option<usize>,
    /// Observed fallback invocations, or `None` until the policy driver exposes
    /// an authoritative process-wide counter.
    #[serde(default)]
    pub fallback_invocation_count: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentRuntimeLease {
    pub schema_version: u32,
    pub instance_id: String,
    pub pid: u32,
    pub state_dir: String,
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
}

impl LocalIdentityState {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn placeholder(device_name: impl Into<String>, device_id: impl Into<String>) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            account_id: None,
            auth_state: AuthState::LoggedOut,
            device: DeviceIdentitySummary {
                device_id: device_id.into(),
                device_name: device_name.into(),
                protocol_signing_algorithm: ProtocolSigningAlgorithm::Ed25519,
                protocol_public_key_bytes: None,
                public_key_fingerprint: None,
                enrollment_status: EnrollmentStatus::Unenrolled,
                created_at: now,
                updated_at: now,
            },
        }
    }
}

fn default_protocol_signing_algorithm() -> ProtocolSigningAlgorithm {
    ProtocolSigningAlgorithm::Ed25519
}

mod base64_standard {
    pub mod option {
        use base64::Engine;
        use base64::engine::general_purpose::STANDARD;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            match value {
                Some(value) => serializer.serialize_some(&STANDARD.encode(value)),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
        where
            D: Deserializer<'de>,
        {
            let value = Option::<String>::deserialize(deserializer)?;
            value
                .map(|value| {
                    STANDARD
                        .decode(value.as_bytes())
                        .map_err(serde::de::Error::custom)
                })
                .transpose()
        }
    }
}

impl AgentHealthSnapshot {
    pub const SCHEMA_VERSION: u32 = 3;

    pub fn new(status: AgentRuntimeStatus, pid: u32, state_dir: impl Into<String>) -> Self {
        Self::new_for_instance(status, pid, state_dir, uuid::Uuid::now_v7().to_string())
    }

    pub fn new_for_instance(
        status: AgentRuntimeStatus,
        pid: u32,
        state_dir: impl Into<String>,
        instance_id: impl Into<String>,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            instance_id: instance_id.into(),
            status,
            pid,
            state_dir: state_dir.into(),
            started_at: now,
            updated_at: now,
            active_sessions: 0,
            active_transfers: None,
            fallback_invocation_count: None,
        }
    }

    pub fn touch(&mut self, status: AgentRuntimeStatus) {
        self.status = status;
        self.updated_at = OffsetDateTime::now_utc();
    }
}

impl AgentRuntimeLease {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn new(instance_id: impl Into<String>, pid: u32, state_dir: impl Into<String>) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            instance_id: instance_id.into(),
            pid,
            state_dir: state_dir.into(),
            started_at: OffsetDateTime::now_utc(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_snapshot_never_encodes_unobserved_counters_as_zero() {
        let health = AgentHealthSnapshot::new(AgentRuntimeStatus::Healthy, 42, "/state");
        let encoded = serde_json::to_value(&health).expect("health should serialize");
        assert_eq!(
            encoded["schema_version"],
            serde_json::json!(AgentHealthSnapshot::SCHEMA_VERSION)
        );
        assert!(encoded["active_transfers"].is_null());
        assert!(encoded["fallback_invocation_count"].is_null());
    }
}
