//! Signature algorithms
//!
//! Provides Ed25519 and ML-DSA-65 signature implementations.

use async_trait::async_trait;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use p256::ecdsa::{
    Signature as P256Signature, SigningKey as P256SigningKey, VerifyingKey as P256VerifyingKey,
};
use pqcrypto::sign::mldsa65;
use pqcrypto_traits::sign::{
    DetachedSignature as PqDetachedSignature, PublicKey as PqPublicKey, SecretKey as PqSecretKey,
};
use rand::RngExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// Signature algorithm identifiers
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SignatureAlgorithm {
    /// Ed25519 (classic, RFC 8032)
    Ed25519,
    /// ML-DSA-65 (post-quantum, NIST FIPS 204)
    MlDsa65,
    /// P-256 ECDSA (legacy compatibility / SE PoP)
    P256Ecdsa,
}

impl SignatureAlgorithm {
    /// Wire protocol ID for the algorithm
    pub fn wire_id(&self) -> u8 {
        match self {
            SignatureAlgorithm::Ed25519 => 0x01,
            SignatureAlgorithm::MlDsa65 => 0x02,
            SignatureAlgorithm::P256Ecdsa => 0x03,
        }
    }

    /// Parse from wire ID
    pub fn from_wire_id(id: u8) -> Option<Self> {
        match id {
            0x01 => Some(SignatureAlgorithm::Ed25519),
            0x02 => Some(SignatureAlgorithm::MlDsa65),
            0x03 => Some(SignatureAlgorithm::P256Ecdsa),
            _ => None,
        }
    }

    /// Get the public key size in bytes
    pub fn public_key_size(&self) -> usize {
        match self {
            SignatureAlgorithm::Ed25519 => 32,
            SignatureAlgorithm::MlDsa65 => mldsa65::public_key_bytes(),
            SignatureAlgorithm::P256Ecdsa => 65,
        }
    }

    /// Get the signature size in bytes
    pub fn signature_size(&self) -> usize {
        match self {
            SignatureAlgorithm::Ed25519 => 64,
            SignatureAlgorithm::MlDsa65 => mldsa65::signature_bytes(),
            SignatureAlgorithm::P256Ecdsa => 72,
        }
    }

    /// Is this a post-quantum algorithm?
    pub fn is_pqc(&self) -> bool {
        matches!(self, SignatureAlgorithm::MlDsa65)
    }

    /// Cross-platform current-path protocol label used by Apple clients and the
    /// signaling control plane.
    pub fn protocol_name(&self) -> &'static str {
        match self {
            SignatureAlgorithm::Ed25519 => "Ed25519",
            SignatureAlgorithm::MlDsa65 => "ML-DSA-65",
            SignatureAlgorithm::P256Ecdsa => "P-256-ECDSA",
        }
    }

    /// Parse an Apple-compatible protocol label.
    pub fn from_protocol_name(value: &str) -> Option<Self> {
        match value.trim() {
            "Ed25519" => Some(SignatureAlgorithm::Ed25519),
            "ML-DSA-65" => Some(SignatureAlgorithm::MlDsa65),
            "P-256-ECDSA" => Some(SignatureAlgorithm::P256Ecdsa),
            _ => None,
        }
    }
}

/// Legacy discovery / pre-current-path fingerprint used by older Ubuntu code.
pub fn compute_legacy_public_key_fingerprint(public_key: &[u8]) -> String {
    hex::encode(Sha256::digest(public_key))
}

/// Current-path authoritative fingerprint compatible with Apple clients.
///
/// This is intentionally distinct from the legacy `sha256(pubkey)` fingerprint:
/// it includes the signing algorithm label and key length in the hash preimage.
pub fn compute_authoritative_public_key_fingerprint(
    algorithm: SignatureAlgorithm,
    public_key: &[u8],
) -> String {
    let tag = algorithm.protocol_name().as_bytes();
    let mut data = Vec::with_capacity(2 + tag.len() + 4 + public_key.len());
    data.extend_from_slice(&(tag.len() as u16).to_le_bytes());
    data.extend_from_slice(tag);
    data.extend_from_slice(&(public_key.len() as u32).to_le_bytes());
    data.extend_from_slice(public_key);
    hex::encode(Sha256::digest(&data))
}

/// Signature errors
#[derive(Debug, Error)]
pub enum SignatureError {
    /// Invalid key length
    #[error("Invalid key length: expected {expected}, got {got}")]
    InvalidKeyLength { expected: usize, got: usize },

    /// Invalid signature
    #[error("Invalid signature")]
    InvalidSignature,

    /// Verification failed
    #[error("Signature verification failed")]
    VerificationFailed,

    /// Key generation failed
    #[error("Key generation failed: {0}")]
    KeyGenerationFailed(String),
}

/// Signature provider trait
#[async_trait]
pub trait SignatureProvider: Send + Sync {
    /// Get the algorithm type
    fn algorithm(&self) -> SignatureAlgorithm;

    /// Generate a new key pair
    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), SignatureError>;

    /// Sign data with a private key
    async fn sign(&self, data: &[u8], private_key: &[u8]) -> Result<Vec<u8>, SignatureError>;

    /// Verify a signature
    async fn verify(
        &self,
        data: &[u8],
        signature: &[u8],
        public_key: &[u8],
    ) -> Result<bool, SignatureError>;
}

/// Ed25519 signature provider
pub struct Ed25519Provider;

impl Ed25519Provider {
    /// Create a new Ed25519 provider
    pub fn new() -> Self {
        Self
    }
}

impl Default for Ed25519Provider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SignatureProvider for Ed25519Provider {
    fn algorithm(&self) -> SignatureAlgorithm {
        SignatureAlgorithm::Ed25519
    }

    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), SignatureError> {
        let mut secret = [0u8; 32];
        rand::rng().fill(&mut secret);
        let signing_key = SigningKey::from_bytes(&secret);
        let verifying_key = signing_key.verifying_key();

        Ok((
            signing_key.to_bytes().to_vec(),
            verifying_key.to_bytes().to_vec(),
        ))
    }

    async fn sign(&self, data: &[u8], private_key: &[u8]) -> Result<Vec<u8>, SignatureError> {
        let key_bytes: [u8; 32] =
            private_key
                .try_into()
                .map_err(|_| SignatureError::InvalidKeyLength {
                    expected: 32,
                    got: private_key.len(),
                })?;

        let signing_key = SigningKey::from_bytes(&key_bytes);
        let signature: Signature = signing_key.sign(data);

        Ok(signature.to_bytes().to_vec())
    }

    async fn verify(
        &self,
        data: &[u8],
        signature: &[u8],
        public_key: &[u8],
    ) -> Result<bool, SignatureError> {
        let key_bytes: [u8; 32] =
            public_key
                .try_into()
                .map_err(|_| SignatureError::InvalidKeyLength {
                    expected: 32,
                    got: public_key.len(),
                })?;

        let sig_bytes: [u8; 64] = signature
            .try_into()
            .map_err(|_| SignatureError::InvalidSignature)?;

        let verifying_key =
            VerifyingKey::from_bytes(&key_bytes).map_err(|_| SignatureError::InvalidSignature)?;
        let sig = Signature::from_bytes(&sig_bytes);

        Ok(verifying_key.verify(data, &sig).is_ok())
    }
}

/// ML-DSA-65 signature provider.
///
/// IMPORTANT: this uses the standardized ML-DSA-65 implementation, not the
/// pre-standardization Dilithium3 API. Apple's current PQC stack verifies the
/// FIPS 204 form, and the older Dilithium3 signatures are not wire-compatible.
pub struct MlDsa65Provider;

impl MlDsa65Provider {
    /// Create a new ML-DSA-65 provider
    pub fn new() -> Self {
        Self
    }
}

impl Default for MlDsa65Provider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SignatureProvider for MlDsa65Provider {
    fn algorithm(&self) -> SignatureAlgorithm {
        SignatureAlgorithm::MlDsa65
    }

    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), SignatureError> {
        let (pk, sk) = mldsa65::keypair();

        Ok((sk.as_bytes().to_vec(), pk.as_bytes().to_vec()))
    }

    async fn sign(&self, data: &[u8], private_key: &[u8]) -> Result<Vec<u8>, SignatureError> {
        let sk = mldsa65::SecretKey::from_bytes(private_key).map_err(|_| {
            SignatureError::InvalidKeyLength {
                expected: mldsa65::secret_key_bytes(),
                got: private_key.len(),
            }
        })?;

        Ok(mldsa65::detached_sign(data, &sk).as_bytes().to_vec())
    }

    async fn verify(
        &self,
        data: &[u8],
        signature: &[u8],
        public_key: &[u8],
    ) -> Result<bool, SignatureError> {
        let pk = mldsa65::PublicKey::from_bytes(public_key).map_err(|_| {
            SignatureError::InvalidKeyLength {
                expected: mldsa65::public_key_bytes(),
                got: public_key.len(),
            }
        })?;

        let sig = mldsa65::DetachedSignature::from_bytes(signature)
            .map_err(|_| SignatureError::InvalidSignature)?;

        Ok(mldsa65::verify_detached_signature(&sig, data, &pk).is_ok())
    }
}

/// P-256 ECDSA signature provider
pub struct P256EcdsaProvider;

impl P256EcdsaProvider {
    /// Create a new P-256 ECDSA provider
    pub fn new() -> Self {
        Self
    }
}

impl Default for P256EcdsaProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SignatureProvider for P256EcdsaProvider {
    fn algorithm(&self) -> SignatureAlgorithm {
        SignatureAlgorithm::P256Ecdsa
    }

    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), SignatureError> {
        let signing_key = loop {
            let mut secret = [0u8; 32];
            rand::rng().fill(&mut secret);
            if let Ok(sk) = P256SigningKey::from_bytes((&secret).into()) {
                break sk;
            }
        };
        let public_key = signing_key
            .verifying_key()
            .to_encoded_point(false)
            .as_bytes()
            .to_vec();
        Ok((signing_key.to_bytes().to_vec(), public_key))
    }

    async fn sign(&self, data: &[u8], private_key: &[u8]) -> Result<Vec<u8>, SignatureError> {
        let key_bytes: [u8; 32] =
            private_key
                .try_into()
                .map_err(|_| SignatureError::InvalidKeyLength {
                    expected: 32,
                    got: private_key.len(),
                })?;
        let signing_key = P256SigningKey::from_bytes((&key_bytes).into())
            .map_err(|_| SignatureError::InvalidSignature)?;
        let signature: P256Signature = signing_key.sign(data);
        Ok(signature.to_der().as_bytes().to_vec())
    }

    async fn verify(
        &self,
        data: &[u8],
        signature: &[u8],
        public_key: &[u8],
    ) -> Result<bool, SignatureError> {
        if public_key.len() != 65 && public_key.len() != 33 {
            return Err(SignatureError::InvalidKeyLength {
                expected: 65,
                got: public_key.len(),
            });
        }

        let verifying_key = P256VerifyingKey::from_sec1_bytes(public_key)
            .map_err(|_| SignatureError::InvalidSignature)?;

        let parsed_signature = if signature.len() == 64 {
            P256Signature::from_slice(signature).map_err(|_| SignatureError::InvalidSignature)?
        } else {
            P256Signature::from_der(signature).map_err(|_| SignatureError::InvalidSignature)?
        };

        Ok(verifying_key.verify(data, &parsed_signature).is_ok())
    }
}

/// Verify signature data with a specific algorithm.
pub async fn verify_with_algorithm(
    algorithm: SignatureAlgorithm,
    data: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> Result<bool, SignatureError> {
    match algorithm {
        SignatureAlgorithm::Ed25519 => {
            Ed25519Provider::new()
                .verify(data, signature, public_key)
                .await
        }
        SignatureAlgorithm::MlDsa65 => {
            MlDsa65Provider::new()
                .verify(data, signature, public_key)
                .await
        }
        SignatureAlgorithm::P256Ecdsa => {
            P256EcdsaProvider::new()
                .verify(data, signature, public_key)
                .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_ed25519_sign_verify() {
        let provider = Ed25519Provider::new();
        let (private_key, public_key) = provider.generate_keypair().unwrap();

        let message = b"Hello, SkyBridge!";
        let signature = provider.sign(message, &private_key).await.unwrap();

        assert!(
            provider
                .verify(message, &signature, &public_key)
                .await
                .unwrap()
        );

        // Test with wrong message
        let wrong_message = b"Wrong message";
        assert!(
            !provider
                .verify(wrong_message, &signature, &public_key)
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn test_ml_dsa65_sign_verify() {
        let provider = MlDsa65Provider::new();
        let (private_key, public_key) = provider.generate_keypair().unwrap();

        let message = b"Hello, Quantum World!";
        let signature = provider.sign(message, &private_key).await.unwrap();

        assert!(
            provider
                .verify(message, &signature, &public_key)
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn test_p256_ecdsa_sign_verify() {
        let provider = P256EcdsaProvider::new();
        let (private_key, public_key) = provider.generate_keypair().unwrap();

        let message = b"Hello, Legacy P-256!";
        let signature = provider.sign(message, &private_key).await.unwrap();

        assert!(
            provider
                .verify(message, &signature, &public_key)
                .await
                .unwrap()
        );

        assert!(
            !provider
                .verify(b"wrong message", &signature, &public_key)
                .await
                .unwrap()
        );
    }
}
