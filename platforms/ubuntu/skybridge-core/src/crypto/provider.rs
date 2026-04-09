//! Crypto Provider
//!
//! High-level cryptographic operations using KEM-DEM paradigm.

use serde::{Deserialize, Serialize};
use std::sync::Arc;
use thiserror::Error;

use super::aead::{AeadError, AeadProvider, AesGcmProvider, ChaChaPolyProvider};
use super::kem::{KemError, KemProvider, MlKem768Provider, X25519Provider, XWingProvider};
use super::signature::{
    Ed25519Provider, MlDsa65Provider, P256EcdsaProvider, SignatureAlgorithm, SignatureError,
    SignatureProvider,
};
use super::suite::{CryptoSuite, CryptoSuiteId};

/// Crypto provider errors
#[derive(Debug, Error)]
pub enum CryptoError {
    /// KEM error
    #[error("KEM error: {0}")]
    Kem(#[from] KemError),

    /// AEAD error
    #[error("AEAD error: {0}")]
    Aead(#[from] AeadError),

    /// Signature error
    #[error("Signature error: {0}")]
    Signature(#[from] SignatureError),

    /// Invalid suite
    #[error("Invalid crypto suite: {0}")]
    InvalidSuite(u16),

    /// Sealed box format error
    #[error("Invalid sealed box format")]
    InvalidSealedBox,
}

/// HPKE-style sealed box
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HpkeSealedBox {
    /// Encapsulated key (KEM ciphertext)
    pub encapsulated_key: Vec<u8>,
    /// AEAD ciphertext
    pub ciphertext: Vec<u8>,
    /// AEAD nonce
    pub nonce: Vec<u8>,
    /// Suite used for encryption
    pub suite_id: u16,
}

impl HpkeSealedBox {
    /// Serialize to bytes
    pub fn to_bytes(&self) -> Vec<u8> {
        // Format: suite_id (2) | ek_len (2) | ek | nonce_len (1) | nonce | ciphertext
        let mut result = Vec::new();
        result.extend_from_slice(&self.suite_id.to_be_bytes());
        result.extend_from_slice(&(self.encapsulated_key.len() as u16).to_be_bytes());
        result.extend_from_slice(&self.encapsulated_key);
        result.push(self.nonce.len() as u8);
        result.extend_from_slice(&self.nonce);
        result.extend_from_slice(&self.ciphertext);
        result
    }

    /// Deserialize from bytes
    pub fn from_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < 5 {
            return None;
        }

        let suite_id = u16::from_be_bytes([data[0], data[1]]);
        let ek_len = u16::from_be_bytes([data[2], data[3]]) as usize;

        if data.len() < 4 + ek_len + 1 {
            return None;
        }

        let encapsulated_key = data[4..4 + ek_len].to_vec();
        let nonce_len = data[4 + ek_len] as usize;

        if data.len() < 4 + ek_len + 1 + nonce_len {
            return None;
        }

        let nonce = data[5 + ek_len..5 + ek_len + nonce_len].to_vec();
        let ciphertext = data[5 + ek_len + nonce_len..].to_vec();

        Some(Self {
            encapsulated_key,
            ciphertext,
            nonce,
            suite_id,
        })
    }
}

/// High-level crypto provider
pub struct CryptoProvider {
    suite: CryptoSuite,
    kem: Arc<dyn KemProvider>,
    aead: Arc<dyn AeadProvider>,
    signature: Arc<dyn SignatureProvider>,
}

impl CryptoProvider {
    /// Create a provider for the given suite
    pub fn new(suite_id: CryptoSuiteId) -> Self {
        let suite = CryptoSuite::from_id(suite_id);

        let kem: Arc<dyn KemProvider> = match suite.kem {
            super::kem::KemAlgorithm::X25519 => Arc::new(X25519Provider::new()),
            super::kem::KemAlgorithm::MlKem768 => Arc::new(MlKem768Provider::new()),
            super::kem::KemAlgorithm::XWing => Arc::new(XWingProvider::new()),
        };

        let aead: Arc<dyn AeadProvider> = match suite.aead {
            super::aead::AeadAlgorithm::Aes256Gcm => Arc::new(AesGcmProvider::new()),
            super::aead::AeadAlgorithm::ChaCha20Poly1305 => Arc::new(ChaChaPolyProvider::new()),
        };

        let signature: Arc<dyn SignatureProvider> = match suite.signature {
            SignatureAlgorithm::Ed25519 => Arc::new(Ed25519Provider::new()),
            SignatureAlgorithm::MlDsa65 => Arc::new(MlDsa65Provider::new()),
            SignatureAlgorithm::P256Ecdsa => Arc::new(P256EcdsaProvider::new()),
        };

        Self {
            suite,
            kem,
            aead,
            signature,
        }
    }

    /// Create a provider with the preferred suite
    pub fn preferred() -> Self {
        Self::new(CryptoSuiteId::XWing_AES256GCM_MlDsa65)
    }

    /// Get the crypto suite
    pub fn suite(&self) -> &CryptoSuite {
        &self.suite
    }

    /// Generate a KEM key pair
    pub fn generate_kem_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), CryptoError> {
        Ok(self.kem.generate_keypair()?)
    }

    /// Generate a signature key pair
    pub fn generate_signing_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), CryptoError> {
        Ok(self.signature.generate_keypair()?)
    }

    /// KEM-DEM seal: Encrypt data for a recipient
    pub fn kem_dem_seal(
        &self,
        plaintext: &[u8],
        recipient_public_key: &[u8],
        info: &[u8],
    ) -> Result<HpkeSealedBox, CryptoError> {
        // Encapsulate to get shared secret
        let encap = self.kem.encapsulate(recipient_public_key)?;

        // Derive encryption key from shared secret
        let key = super::kdf::derive_key(&encap.shared_secret, Some(info), b"seal", 32);

        // Encrypt with AEAD
        let encrypted = self.aead.encrypt(&key, plaintext, info)?;

        Ok(HpkeSealedBox {
            encapsulated_key: encap.ciphertext,
            ciphertext: encrypted.ciphertext,
            nonce: encrypted.nonce,
            suite_id: self.suite.id.wire_id(),
        })
    }

    /// KEM-DEM open: Decrypt data
    pub fn kem_dem_open(
        &self,
        sealed_box: &HpkeSealedBox,
        private_key: &[u8],
        info: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        // Verify suite matches
        if sealed_box.suite_id != self.suite.id.wire_id() {
            return Err(CryptoError::InvalidSuite(sealed_box.suite_id));
        }

        // Decapsulate to get shared secret
        let shared_secret = self
            .kem
            .decapsulate(&sealed_box.encapsulated_key, private_key)?;

        // Derive encryption key
        let key = super::kdf::derive_key(&shared_secret, Some(info), b"seal", 32);

        // Decrypt with AEAD
        let encrypted = super::aead::EncryptedData {
            nonce: sealed_box.nonce.clone(),
            ciphertext: sealed_box.ciphertext.clone(),
        };

        Ok(self.aead.decrypt(&key, &encrypted, info)?)
    }

    /// Pure KEM encapsulate
    pub fn kem_encapsulate(
        &self,
        recipient_public_key: &[u8],
    ) -> Result<(Vec<u8>, Vec<u8>), CryptoError> {
        let encap = self.kem.encapsulate(recipient_public_key)?;
        Ok((encap.ciphertext, encap.shared_secret))
    }

    /// Pure KEM decapsulate
    pub fn kem_decapsulate(
        &self,
        encapsulated_key: &[u8],
        private_key: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        Ok(self.kem.decapsulate(encapsulated_key, private_key)?)
    }

    /// Sign data
    pub async fn sign(&self, data: &[u8], private_key: &[u8]) -> Result<Vec<u8>, CryptoError> {
        Ok(self.signature.sign(data, private_key).await?)
    }

    /// Verify signature
    pub async fn verify(
        &self,
        data: &[u8],
        signature: &[u8],
        public_key: &[u8],
    ) -> Result<bool, CryptoError> {
        Ok(self.signature.verify(data, signature, public_key).await?)
    }

    /// Encrypt with AEAD
    pub fn encrypt(
        &self,
        key: &[u8],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<super::aead::EncryptedData, CryptoError> {
        Ok(self.aead.encrypt(key, plaintext, aad)?)
    }

    /// Decrypt with AEAD
    pub fn decrypt(
        &self,
        key: &[u8],
        encrypted: &super::aead::EncryptedData,
        aad: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        Ok(self.aead.decrypt(key, encrypted, aad)?)
    }
}

impl Clone for CryptoProvider {
    fn clone(&self) -> Self {
        Self::new(self.suite.id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kem_dem_roundtrip() {
        let provider = CryptoProvider::new(CryptoSuiteId::X25519_AES256GCM_Ed25519);
        let (private_key, public_key) = provider.generate_kem_keypair().unwrap();

        let plaintext = b"Hello, SkyBridge!";
        let info = b"test context";

        let sealed = provider.kem_dem_seal(plaintext, &public_key, info).unwrap();
        let opened = provider.kem_dem_open(&sealed, &private_key, info).unwrap();

        assert_eq!(plaintext.as_slice(), opened.as_slice());
    }

    #[test]
    fn test_kem_dem_pqc() {
        let provider = CryptoProvider::new(CryptoSuiteId::MlKem768_AES256GCM_MlDsa65);
        let (private_key, public_key) = provider.generate_kem_keypair().unwrap();

        let plaintext = b"Post-quantum secure message";
        let info = b"pqc context";

        let sealed = provider.kem_dem_seal(plaintext, &public_key, info).unwrap();
        let opened = provider.kem_dem_open(&sealed, &private_key, info).unwrap();

        assert_eq!(plaintext.as_slice(), opened.as_slice());
    }

    #[test]
    fn test_kem_dem_hybrid() {
        let provider = CryptoProvider::new(CryptoSuiteId::XWing_AES256GCM_MlDsa65);
        let (private_key, public_key) = provider.generate_kem_keypair().unwrap();

        let plaintext = b"Hybrid post-quantum secure message";
        let info = b"hybrid context";

        let sealed = provider.kem_dem_seal(plaintext, &public_key, info).unwrap();
        let opened = provider.kem_dem_open(&sealed, &private_key, info).unwrap();

        assert_eq!(plaintext.as_slice(), opened.as_slice());
    }

    #[tokio::test]
    async fn test_sign_verify() {
        let provider = CryptoProvider::new(CryptoSuiteId::X25519_AES256GCM_Ed25519);
        let (private_key, public_key) = provider.generate_signing_keypair().unwrap();

        let message = b"Sign this message";
        let signature = provider.sign(message, &private_key).await.unwrap();

        assert!(
            provider
                .verify(message, &signature, &public_key)
                .await
                .unwrap()
        );
    }

    #[test]
    fn test_sealed_box_serialization() {
        let box1 = HpkeSealedBox {
            encapsulated_key: vec![1, 2, 3, 4],
            ciphertext: vec![5, 6, 7, 8, 9],
            nonce: vec![10, 11, 12],
            suite_id: 0x0001,
        };

        let bytes = box1.to_bytes();
        let box2 = HpkeSealedBox::from_bytes(&bytes).unwrap();

        assert_eq!(box1.encapsulated_key, box2.encapsulated_key);
        assert_eq!(box1.ciphertext, box2.ciphertext);
        assert_eq!(box1.nonce, box2.nonce);
        assert_eq!(box1.suite_id, box2.suite_id);
    }
}
