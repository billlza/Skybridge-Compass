//! Authenticated Encryption with Associated Data (AEAD)
//!
//! Provides AES-256-GCM and ChaCha20-Poly1305 implementations.

use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, KeyInit, Payload},
};
use rand::RngExt;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// AEAD algorithm identifiers
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AeadAlgorithm {
    /// AES-256-GCM
    Aes256Gcm,
    /// ChaCha20-Poly1305
    ChaCha20Poly1305,
}

impl AeadAlgorithm {
    /// Wire protocol ID
    pub fn wire_id(&self) -> u8 {
        match self {
            AeadAlgorithm::Aes256Gcm => 0x01,
            AeadAlgorithm::ChaCha20Poly1305 => 0x02,
        }
    }

    /// Parse from wire ID
    pub fn from_wire_id(id: u8) -> Option<Self> {
        match id {
            0x01 => Some(AeadAlgorithm::Aes256Gcm),
            0x02 => Some(AeadAlgorithm::ChaCha20Poly1305),
            _ => None,
        }
    }

    /// Get the key size in bytes
    pub fn key_size(&self) -> usize {
        match self {
            AeadAlgorithm::Aes256Gcm => 32,
            AeadAlgorithm::ChaCha20Poly1305 => 32,
        }
    }

    /// Get the nonce size in bytes
    pub fn nonce_size(&self) -> usize {
        match self {
            AeadAlgorithm::Aes256Gcm => 12,
            AeadAlgorithm::ChaCha20Poly1305 => 12,
        }
    }

    /// Get the authentication tag size in bytes
    pub fn tag_size(&self) -> usize {
        match self {
            AeadAlgorithm::Aes256Gcm => 16,
            AeadAlgorithm::ChaCha20Poly1305 => 16,
        }
    }
}

/// AEAD errors
#[derive(Debug, Error)]
pub enum AeadError {
    /// Invalid key length
    #[error("Invalid key length: expected {expected}, got {got}")]
    InvalidKeyLength { expected: usize, got: usize },

    /// Invalid nonce length
    #[error("Invalid nonce length: expected {expected}, got {got}")]
    InvalidNonceLength { expected: usize, got: usize },

    /// Encryption failed
    #[error("Encryption failed")]
    EncryptionFailed,

    /// Decryption failed (authentication or decryption error)
    #[error("Decryption failed")]
    DecryptionFailed,
}

/// Encrypted data with nonce
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedData {
    /// Nonce used for encryption
    pub nonce: Vec<u8>,
    /// Ciphertext with authentication tag
    pub ciphertext: Vec<u8>,
}

impl EncryptedData {
    /// Serialize to bytes (nonce || ciphertext)
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut result = self.nonce.clone();
        result.extend_from_slice(&self.ciphertext);
        result
    }

    /// Deserialize from bytes
    pub fn from_bytes(data: &[u8], nonce_size: usize) -> Option<Self> {
        if data.len() < nonce_size {
            return None;
        }

        Some(Self {
            nonce: data[..nonce_size].to_vec(),
            ciphertext: data[nonce_size..].to_vec(),
        })
    }
}

/// AEAD provider trait
pub trait AeadProvider: Send + Sync {
    /// Get the algorithm type
    fn algorithm(&self) -> AeadAlgorithm;

    /// Encrypt data with associated data
    fn encrypt(&self, key: &[u8], plaintext: &[u8], aad: &[u8])
    -> Result<EncryptedData, AeadError>;

    /// Decrypt data with associated data
    fn decrypt(
        &self,
        key: &[u8],
        encrypted: &EncryptedData,
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError>;

    /// Encrypt with explicit nonce (for deterministic testing or special protocols)
    fn encrypt_with_nonce(
        &self,
        key: &[u8],
        nonce: &[u8],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError>;

    /// Decrypt with explicit nonce
    fn decrypt_with_nonce(
        &self,
        key: &[u8],
        nonce: &[u8],
        ciphertext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError>;
}

/// AES-256-GCM provider
pub struct AesGcmProvider;

impl AesGcmProvider {
    /// Create a new AES-GCM provider
    pub fn new() -> Self {
        Self
    }

    /// Generate a random nonce
    fn generate_nonce() -> [u8; 12] {
        let mut nonce = [0u8; 12];
        rand::rng().fill(&mut nonce);
        nonce
    }
}

impl Default for AesGcmProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl AeadProvider for AesGcmProvider {
    fn algorithm(&self) -> AeadAlgorithm {
        AeadAlgorithm::Aes256Gcm
    }

    fn encrypt(
        &self,
        key: &[u8],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<EncryptedData, AeadError> {
        let nonce = Self::generate_nonce();
        let ciphertext = self.encrypt_with_nonce(key, &nonce, plaintext, aad)?;

        Ok(EncryptedData {
            nonce: nonce.to_vec(),
            ciphertext,
        })
    }

    fn decrypt(
        &self,
        key: &[u8],
        encrypted: &EncryptedData,
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        self.decrypt_with_nonce(key, &encrypted.nonce, &encrypted.ciphertext, aad)
    }

    fn encrypt_with_nonce(
        &self,
        key: &[u8],
        nonce: &[u8],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        if key.len() != 32 {
            return Err(AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            });
        }

        if nonce.len() != 12 {
            return Err(AeadError::InvalidNonceLength {
                expected: 12,
                got: nonce.len(),
            });
        }

        let key_array: [u8; 32] = key.try_into().unwrap();
        let cipher =
            Aes256Gcm::new_from_slice(&key_array).map_err(|_| AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            })?;

        let nonce = Nonce::from_slice(nonce);
        let payload = Payload {
            msg: plaintext,
            aad,
        };

        cipher
            .encrypt(nonce, payload)
            .map_err(|_| AeadError::EncryptionFailed)
    }

    fn decrypt_with_nonce(
        &self,
        key: &[u8],
        nonce: &[u8],
        ciphertext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        if key.len() != 32 {
            return Err(AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            });
        }

        if nonce.len() != 12 {
            return Err(AeadError::InvalidNonceLength {
                expected: 12,
                got: nonce.len(),
            });
        }

        let key_array: [u8; 32] = key.try_into().unwrap();
        let cipher =
            Aes256Gcm::new_from_slice(&key_array).map_err(|_| AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            })?;

        let nonce = Nonce::from_slice(nonce);
        let payload = Payload {
            msg: ciphertext,
            aad,
        };

        cipher
            .decrypt(nonce, payload)
            .map_err(|_| AeadError::DecryptionFailed)
    }
}

/// ChaCha20-Poly1305 provider
pub struct ChaChaPolyProvider;

impl ChaChaPolyProvider {
    /// Create a new ChaCha20-Poly1305 provider
    pub fn new() -> Self {
        Self
    }

    /// Generate a random nonce
    fn generate_nonce() -> [u8; 12] {
        let mut nonce = [0u8; 12];
        rand::rng().fill(&mut nonce);
        nonce
    }
}

impl Default for ChaChaPolyProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl AeadProvider for ChaChaPolyProvider {
    fn algorithm(&self) -> AeadAlgorithm {
        AeadAlgorithm::ChaCha20Poly1305
    }

    fn encrypt(
        &self,
        key: &[u8],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<EncryptedData, AeadError> {
        use chacha20poly1305::{ChaCha20Poly1305, KeyInit, aead::Aead};

        if key.len() != 32 {
            return Err(AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            });
        }

        let nonce = Self::generate_nonce();
        let cipher =
            ChaCha20Poly1305::new_from_slice(key).map_err(|_| AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            })?;

        let nonce_obj = chacha20poly1305::Nonce::from_slice(&nonce);
        let payload = chacha20poly1305::aead::Payload {
            msg: plaintext,
            aad,
        };

        let ciphertext = cipher
            .encrypt(nonce_obj, payload)
            .map_err(|_| AeadError::EncryptionFailed)?;

        Ok(EncryptedData {
            nonce: nonce.to_vec(),
            ciphertext,
        })
    }

    fn decrypt(
        &self,
        key: &[u8],
        encrypted: &EncryptedData,
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        self.decrypt_with_nonce(key, &encrypted.nonce, &encrypted.ciphertext, aad)
    }

    fn encrypt_with_nonce(
        &self,
        key: &[u8],
        nonce: &[u8],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        use chacha20poly1305::{ChaCha20Poly1305, KeyInit, aead::Aead};

        if key.len() != 32 {
            return Err(AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            });
        }

        if nonce.len() != 12 {
            return Err(AeadError::InvalidNonceLength {
                expected: 12,
                got: nonce.len(),
            });
        }

        let cipher =
            ChaCha20Poly1305::new_from_slice(key).map_err(|_| AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            })?;

        let nonce_obj = chacha20poly1305::Nonce::from_slice(nonce);
        let payload = chacha20poly1305::aead::Payload {
            msg: plaintext,
            aad,
        };

        cipher
            .encrypt(nonce_obj, payload)
            .map_err(|_| AeadError::EncryptionFailed)
    }

    fn decrypt_with_nonce(
        &self,
        key: &[u8],
        nonce: &[u8],
        ciphertext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        use chacha20poly1305::{ChaCha20Poly1305, KeyInit, aead::Aead};

        if key.len() != 32 {
            return Err(AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            });
        }

        if nonce.len() != 12 {
            return Err(AeadError::InvalidNonceLength {
                expected: 12,
                got: nonce.len(),
            });
        }

        let cipher =
            ChaCha20Poly1305::new_from_slice(key).map_err(|_| AeadError::InvalidKeyLength {
                expected: 32,
                got: key.len(),
            })?;

        let nonce_obj = chacha20poly1305::Nonce::from_slice(nonce);
        let payload = chacha20poly1305::aead::Payload {
            msg: ciphertext,
            aad,
        };

        cipher
            .decrypt(nonce_obj, payload)
            .map_err(|_| AeadError::DecryptionFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_aes_gcm_roundtrip() {
        let provider = AesGcmProvider::new();
        let key = [0u8; 32];
        let plaintext = b"Hello, SkyBridge!";
        let aad = b"associated data";

        let encrypted = provider.encrypt(&key, plaintext, aad).unwrap();
        let decrypted = provider.decrypt(&key, &encrypted, aad).unwrap();

        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }

    #[test]
    fn test_aes_gcm_wrong_aad() {
        let provider = AesGcmProvider::new();
        let key = [0u8; 32];
        let plaintext = b"Hello, SkyBridge!";
        let aad = b"associated data";
        let wrong_aad = b"wrong data";

        let encrypted = provider.encrypt(&key, plaintext, aad).unwrap();
        let result = provider.decrypt(&key, &encrypted, wrong_aad);

        assert!(result.is_err());
    }

    #[test]
    fn test_chacha_poly_roundtrip() {
        let provider = ChaChaPolyProvider::new();
        let key = [0u8; 32];
        let plaintext = b"Hello, Quantum World!";
        let aad = b"";

        let encrypted = provider.encrypt(&key, plaintext, aad).unwrap();
        let decrypted = provider.decrypt(&key, &encrypted, aad).unwrap();

        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }
}
