//! Transfer key registry (PQC session keys).

use std::collections::HashMap;

use parking_lot::RwLock;

use crate::p2p::{P2PConnection, P2PError, SessionKeys};

/// Stores PQC session keys per peer for file transfer encryption.
#[derive(Default)]
pub struct TransferKeyStore {
    inner: RwLock<HashMap<String, SessionKeys>>,
}

impl TransferKeyStore {
    /// Create a new key store.
    pub fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }

    /// Register session keys for a peer.
    pub fn register(&self, peer_id: impl Into<String>, keys: SessionKeys) {
        self.inner.write().insert(peer_id.into(), keys);
    }

    /// Register session keys from an active P2P connection.
    pub fn register_from_connection(
        &self,
        peer_id: impl Into<String>,
        connection: &P2PConnection,
    ) -> Result<(), P2PError> {
        let keys = connection
            .session_keys()
            .ok_or(P2PError::SessionNotEstablished)?;
        self.register(peer_id, keys.clone());
        Ok(())
    }

    /// Remove a peer entry.
    pub fn remove(&self, peer_id: &str) {
        self.inner.write().remove(peer_id);
    }

    /// Get the file-send key for a peer.
    pub fn send_file_key(&self, peer_id: &str) -> Option<Vec<u8>> {
        self.inner
            .read()
            .get(peer_id)
            .map(|keys| keys.send_file_key.clone())
    }

    /// Get the file-receive key for a peer.
    pub fn recv_file_key(&self, peer_id: &str) -> Option<Vec<u8>> {
        self.inner
            .read()
            .get(peer_id)
            .map(|keys| keys.recv_file_key.clone())
    }
}
