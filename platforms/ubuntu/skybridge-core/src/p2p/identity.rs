//! Local identity storage for P2P handshake keys.

use std::fs;
use std::path::PathBuf;

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use super::driver::LocalIdentity;
use crate::crypto::suite::CryptoSuiteId;
use crate::p2p::P2PError;

/// Errors for local identity persistence.
#[derive(Debug, Error)]
pub enum LocalIdentityError {
    /// Project directory unavailable
    #[error("Identity store directory unavailable")]
    NoProjectDir,
    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    /// Serialization error
    #[error("Serialization error: {0}")]
    Serde(#[from] serde_json::Error),
    /// Identity generation failed
    #[error("Identity generation failed: {0}")]
    Generate(String),
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredIdentity {
    identity: LocalIdentity,
}

/// Local identity store (JSON on disk).
#[derive(Debug)]
pub struct LocalIdentityStore;

impl LocalIdentityStore {
    /// Load identity from disk if present.
    pub fn load() -> Result<Option<LocalIdentity>, LocalIdentityError> {
        let path = Self::store_path()?;
        if !path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(&path)?;
        let stored: StoredIdentity = serde_json::from_str(&raw)?;
        let mut identity = stored.identity;
        let migrated =
            identity.normalize_xwing_public_key_order() | identity.ensure_interop_suite_aliases();
        if migrated {
            let _ = Self::save(&identity);
        }
        Ok(Some(identity))
    }

    /// Save identity to disk (atomic).
    pub fn save(identity: &LocalIdentity) -> Result<(), LocalIdentityError> {
        let path = Self::store_path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp_path = path.with_extension("tmp");
        let serialized = serde_json::to_string_pretty(&StoredIdentity {
            identity: identity.clone(),
        })?;
        fs::write(&tmp_path, serialized)?;
        fs::rename(tmp_path, &path)?;
        Ok(())
    }

    /// Load identity from disk or generate and persist a new one.
    pub fn load_or_generate(suites: &[CryptoSuiteId]) -> Result<LocalIdentity, LocalIdentityError> {
        if let Some(identity) = Self::load()? {
            return Ok(identity);
        }
        let device_id = Uuid::new_v4().to_string();
        let identity = LocalIdentity::generate(device_id, suites)
            .map_err(|err| LocalIdentityError::Generate(err.to_string()))?;
        Self::save(&identity)?;
        Ok(identity)
    }

    fn store_path() -> Result<PathBuf, LocalIdentityError> {
        let project = ProjectDirs::from("com", "SkyBridge", "Compass")
            .ok_or(LocalIdentityError::NoProjectDir)?;
        Ok(project.data_dir().join("p2p_identity.json"))
    }
}

impl From<P2PError> for LocalIdentityError {
    fn from(err: P2PError) -> Self {
        LocalIdentityError::Generate(err.to_string())
    }
}
