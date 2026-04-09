//! Key Encapsulation Mechanisms (KEM)
//!
//! Provides X25519, ML-KEM-768, and X-Wing (hybrid) implementations.

use async_trait::async_trait;
use oqs::kem::{Algorithm as OqsKemAlgorithm, Kem as OqsKem};
use serde::{Deserialize, Serialize};
use sha3::{Digest, Sha3_256};
use std::sync::OnceLock;
use thiserror::Error;
use x25519_dalek::{EphemeralSecret, PublicKey, StaticSecret};

/// KEM algorithm identifiers
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KemAlgorithm {
    /// X25519 (classic ECDH)
    X25519,
    /// ML-KEM-768 (post-quantum, NIST FIPS 203)
    MlKem768,
    /// X-Wing: X25519 + ML-KEM-768 (hybrid PQC)
    XWing,
}

impl KemAlgorithm {
    /// Wire protocol ID
    pub fn wire_id(&self) -> u8 {
        match self {
            KemAlgorithm::X25519 => 0x01,
            KemAlgorithm::MlKem768 => 0x02,
            KemAlgorithm::XWing => 0x03,
        }
    }

    /// Parse from wire ID
    pub fn from_wire_id(id: u8) -> Option<Self> {
        match id {
            0x01 => Some(KemAlgorithm::X25519),
            0x02 => Some(KemAlgorithm::MlKem768),
            0x03 => Some(KemAlgorithm::XWing),
            _ => None,
        }
    }

    /// Is this a post-quantum algorithm?
    pub fn is_pqc(&self) -> bool {
        matches!(self, KemAlgorithm::MlKem768 | KemAlgorithm::XWing)
    }

    /// Is this a hybrid algorithm?
    pub fn is_hybrid(&self) -> bool {
        matches!(self, KemAlgorithm::XWing)
    }
}

/// KEM errors
#[derive(Debug, Error)]
pub enum KemError {
    /// Invalid key length
    #[error("Invalid key length: expected {expected}, got {got}")]
    InvalidKeyLength { expected: usize, got: usize },

    /// Encapsulation failed
    #[error("Encapsulation failed")]
    EncapsulationFailed,

    /// Decapsulation failed
    #[error("Decapsulation failed")]
    DecapsulationFailed,

    /// Key generation failed
    #[error("Key generation failed: {0}")]
    KeyGenerationFailed(String),
}

/// Encapsulation result
#[derive(Debug, Clone)]
pub struct EncapsulatedKey {
    /// Ciphertext to send to the recipient
    pub ciphertext: Vec<u8>,
    /// Shared secret (known only to sender)
    pub shared_secret: Vec<u8>,
}

/// KEM provider trait
#[async_trait]
pub trait KemProvider: Send + Sync {
    /// Get the algorithm type
    fn algorithm(&self) -> KemAlgorithm;

    /// Generate a new key pair (private, public)
    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), KemError>;

    /// Encapsulate: generate ciphertext and shared secret using recipient's public key
    fn encapsulate(&self, public_key: &[u8]) -> Result<EncapsulatedKey, KemError>;

    /// Decapsulate: derive shared secret from ciphertext using private key
    fn decapsulate(&self, ciphertext: &[u8], private_key: &[u8]) -> Result<Vec<u8>, KemError>;
}

/// X25519 KEM provider
pub struct X25519Provider;

impl X25519Provider {
    /// Create a new X25519 provider
    pub fn new() -> Self {
        Self
    }

    /// X25519 public key size
    pub const PUBLIC_KEY_SIZE: usize = 32;
    /// X25519 private key size
    pub const PRIVATE_KEY_SIZE: usize = 32;
    /// X25519 ciphertext size (ephemeral public key)
    pub const CIPHERTEXT_SIZE: usize = 32;
    /// X25519 shared secret size
    pub const SHARED_SECRET_SIZE: usize = 32;
}

impl Default for X25519Provider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl KemProvider for X25519Provider {
    fn algorithm(&self) -> KemAlgorithm {
        KemAlgorithm::X25519
    }

    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), KemError> {
        let private = StaticSecret::random();
        let public = PublicKey::from(&private);

        Ok((private.to_bytes().to_vec(), public.to_bytes().to_vec()))
    }

    fn encapsulate(&self, public_key: &[u8]) -> Result<EncapsulatedKey, KemError> {
        let pk_bytes: [u8; 32] = public_key
            .try_into()
            .map_err(|_| KemError::InvalidKeyLength {
                expected: 32,
                got: public_key.len(),
            })?;

        let recipient_public = PublicKey::from(pk_bytes);

        // Generate ephemeral key pair
        let ephemeral_secret = EphemeralSecret::random();
        let ephemeral_public = PublicKey::from(&ephemeral_secret);

        // Compute shared secret
        let shared_secret = ephemeral_secret.diffie_hellman(&recipient_public);

        Ok(EncapsulatedKey {
            ciphertext: ephemeral_public.to_bytes().to_vec(),
            shared_secret: shared_secret.to_bytes().to_vec(),
        })
    }

    fn decapsulate(&self, ciphertext: &[u8], private_key: &[u8]) -> Result<Vec<u8>, KemError> {
        let ct_bytes: [u8; 32] = ciphertext
            .try_into()
            .map_err(|_| KemError::InvalidKeyLength {
                expected: 32,
                got: ciphertext.len(),
            })?;

        let sk_bytes: [u8; 32] =
            private_key
                .try_into()
                .map_err(|_| KemError::InvalidKeyLength {
                    expected: 32,
                    got: private_key.len(),
                })?;

        let ephemeral_public = PublicKey::from(ct_bytes);
        let static_secret = StaticSecret::from(sk_bytes);

        let shared_secret = static_secret.diffie_hellman(&ephemeral_public);

        Ok(shared_secret.to_bytes().to_vec())
    }
}

/// ML-KEM-768 provider.
///
/// IMPORTANT: we intentionally use liboqs here rather than pqcrypto's standalone
/// ML-KEM implementation, because live Apple interoperability is currently
/// anchored to liboqs/OQSRAII semantics.
pub struct MlKem768Provider;

impl MlKem768Provider {
    /// Create a new ML-KEM-768 provider
    pub fn new() -> Self {
        Self
    }
}

impl Default for MlKem768Provider {
    fn default() -> Self {
        Self::new()
    }
}

fn oqs_mlkem768() -> Result<&'static OqsKem, KemError> {
    static OQS_MLKEM768: OnceLock<Result<OqsKem, String>> = OnceLock::new();
    match OQS_MLKEM768.get_or_init(|| {
        oqs::init();
        OqsKem::new(OqsKemAlgorithm::MlKem768).map_err(|err| format!("{err:?}"))
    }) {
        Ok(kem) => Ok(kem),
        Err(message) => Err(KemError::KeyGenerationFailed(message.clone())),
    }
}

fn map_oqs_error(err: oqs::Error, fallback: KemError) -> KemError {
    match err {
        oqs::Error::InvalidLength => KemError::InvalidKeyLength {
            expected: 0,
            got: 0,
        },
        _ => fallback,
    }
}

#[async_trait]
impl KemProvider for MlKem768Provider {
    fn algorithm(&self) -> KemAlgorithm {
        KemAlgorithm::MlKem768
    }

    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), KemError> {
        let kem = oqs_mlkem768()?;
        let (pk, sk) = kem
            .keypair()
            .map_err(|err| KemError::KeyGenerationFailed(format!("{err:?}")))?;
        Ok((sk.into_vec(), pk.into_vec()))
    }

    fn encapsulate(&self, public_key: &[u8]) -> Result<EncapsulatedKey, KemError> {
        let kem = oqs_mlkem768()?;
        let pk =
            kem.public_key_from_bytes(public_key)
                .ok_or_else(|| KemError::InvalidKeyLength {
                    expected: kem.length_public_key(),
                    got: public_key.len(),
                })?;
        let (ct, ss) = kem
            .encapsulate(pk)
            .map_err(|err| map_oqs_error(err, KemError::EncapsulationFailed))?;

        Ok(EncapsulatedKey {
            ciphertext: ct.into_vec(),
            shared_secret: ss.into_vec(),
        })
    }

    fn decapsulate(&self, ciphertext: &[u8], private_key: &[u8]) -> Result<Vec<u8>, KemError> {
        let kem = oqs_mlkem768()?;
        let sk =
            kem.secret_key_from_bytes(private_key)
                .ok_or_else(|| KemError::InvalidKeyLength {
                    expected: kem.length_secret_key(),
                    got: private_key.len(),
                })?;
        let ct =
            kem.ciphertext_from_bytes(ciphertext)
                .ok_or_else(|| KemError::InvalidKeyLength {
                    expected: kem.length_ciphertext(),
                    got: ciphertext.len(),
                })?;
        let ss = kem
            .decapsulate(sk, ct)
            .map_err(|err| map_oqs_error(err, KemError::DecapsulationFailed))?;

        Ok(ss.into_vec())
    }
}

/// X-Wing: Hybrid X25519 + ML-KEM-768 provider
pub struct XWingProvider {
    x25519: X25519Provider,
    ml_kem: MlKem768Provider,
}

impl XWingProvider {
    /// Create a new X-Wing provider
    pub fn new() -> Self {
        Self {
            x25519: X25519Provider::new(),
            ml_kem: MlKem768Provider::new(),
        }
    }

    /// X-Wing combiner (draft-connolly-cfrg-xwing-kem-09):
    /// SHA3-256(ss_M || ss_X || ct_X || pk_X || "X-Wing")
    fn combine_secrets(ml_kem_ss: &[u8], x25519_ss: &[u8], ct_x: &[u8], pk_x: &[u8]) -> Vec<u8> {
        let mut hasher = Sha3_256::new();
        hasher.update(ml_kem_ss);
        hasher.update(x25519_ss);
        hasher.update(ct_x);
        hasher.update(pk_x);
        hasher.update(b"X-Wing");
        hasher.finalize().to_vec()
    }
}

impl Default for XWingProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl KemProvider for XWingProvider {
    fn algorithm(&self) -> KemAlgorithm {
        KemAlgorithm::XWing
    }

    fn generate_keypair(&self) -> Result<(Vec<u8>, Vec<u8>), KemError> {
        let (x25519_sk, x25519_pk) = self.x25519.generate_keypair()?;
        let (ml_kem_sk, ml_kem_pk) = self.ml_kem.generate_keypair()?;

        // Private key format: X25519 || ML-KEM-768 (local storage only)
        let mut private_key = x25519_sk;
        private_key.extend_from_slice(&ml_kem_sk);

        // Public key format (X-Wing draft-09): ML-KEM-768 || X25519
        let mut public_key = ml_kem_pk;
        public_key.extend_from_slice(&x25519_pk);

        Ok((private_key, public_key))
    }

    fn encapsulate(&self, public_key: &[u8]) -> Result<EncapsulatedKey, KemError> {
        // Split X-Wing public key: pk_M (1184) || pk_X (32)
        let ml_kem_pk_len = oqs_mlkem768()?.length_public_key();
        let x25519_pk_len = X25519Provider::PUBLIC_KEY_SIZE;
        if public_key.len() != ml_kem_pk_len + x25519_pk_len {
            return Err(KemError::InvalidKeyLength {
                expected: ml_kem_pk_len + x25519_pk_len,
                got: public_key.len(),
            });
        }

        let ml_kem_pk = &public_key[..ml_kem_pk_len];
        let x25519_pk = &public_key[ml_kem_pk_len..];

        // Encapsulate with both. Ciphertext order per spec: ct_M || ct_X.
        let ml_kem_result = self.ml_kem.encapsulate(ml_kem_pk)?;
        let x25519_result = self.x25519.encapsulate(x25519_pk)?;

        let mut ciphertext = ml_kem_result.ciphertext;
        ciphertext.extend_from_slice(&x25519_result.ciphertext);

        // Combine shared secrets per draft-09 combiner.
        let shared_secret = Self::combine_secrets(
            &ml_kem_result.shared_secret,
            &x25519_result.shared_secret,
            &x25519_result.ciphertext,
            x25519_pk,
        );

        Ok(EncapsulatedKey {
            ciphertext,
            shared_secret,
        })
    }

    fn decapsulate(&self, ciphertext: &[u8], private_key: &[u8]) -> Result<Vec<u8>, KemError> {
        // Split private key (local storage format): X25519 || ML-KEM-768
        let x25519_sk_len = X25519Provider::PRIVATE_KEY_SIZE;
        let ml_kem_sk_len = oqs_mlkem768()?.length_secret_key();
        if private_key.len() < x25519_sk_len {
            return Err(KemError::InvalidKeyLength {
                expected: x25519_sk_len + ml_kem_sk_len,
                got: private_key.len(),
            });
        }

        let x25519_sk = &private_key[..x25519_sk_len];
        let ml_kem_sk = &private_key[x25519_sk_len..];

        // Split ciphertext: ct_M (1088) || ct_X (32)
        let ml_kem_ct_len = oqs_mlkem768()?.length_ciphertext();
        let x25519_ct_len = X25519Provider::CIPHERTEXT_SIZE;
        if ciphertext.len() != ml_kem_ct_len + x25519_ct_len {
            return Err(KemError::InvalidKeyLength {
                expected: ml_kem_ct_len + x25519_ct_len,
                got: ciphertext.len(),
            });
        }

        let ml_kem_ct = &ciphertext[..ml_kem_ct_len];
        let x25519_ct = &ciphertext[ml_kem_ct_len..];

        // Decapsulate with both
        let ml_kem_ss = self.ml_kem.decapsulate(ml_kem_ct, ml_kem_sk)?;
        let x25519_ss = self.x25519.decapsulate(x25519_ct, x25519_sk)?;

        // Derive pk_X from sk_X for combiner input.
        let sk_bytes: [u8; 32] = x25519_sk
            .try_into()
            .map_err(|_| KemError::InvalidKeyLength {
                expected: 32,
                got: x25519_sk.len(),
            })?;
        let pk_x = PublicKey::from(&StaticSecret::from(sk_bytes)).to_bytes();

        Ok(Self::combine_secrets(
            &ml_kem_ss, &x25519_ss, x25519_ct, &pk_x,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_x25519_kem() {
        let provider = X25519Provider::new();
        let (private_key, public_key) = provider.generate_keypair().unwrap();

        let encap = provider.encapsulate(&public_key).unwrap();
        let decap_ss = provider
            .decapsulate(&encap.ciphertext, &private_key)
            .unwrap();

        assert_eq!(encap.shared_secret, decap_ss);
    }

    #[test]
    fn test_ml_kem_768() {
        let provider = MlKem768Provider::new();
        let (private_key, public_key) = provider.generate_keypair().unwrap();

        let encap = provider.encapsulate(&public_key).unwrap();
        let decap_ss = provider
            .decapsulate(&encap.ciphertext, &private_key)
            .unwrap();

        assert_eq!(encap.shared_secret, decap_ss);
    }

    #[test]
    fn test_xwing() {
        let provider = XWingProvider::new();
        let (private_key, public_key) = provider.generate_keypair().unwrap();

        // X-Wing draft-09 public key: ML-KEM-768 (1184) || X25519 (32)
        let ml_kem = oqs_mlkem768().unwrap();
        assert_eq!(
            public_key.len(),
            ml_kem.length_public_key() + X25519Provider::PUBLIC_KEY_SIZE
        );
        assert_eq!(
            private_key.len(),
            X25519Provider::PRIVATE_KEY_SIZE + ml_kem.length_secret_key()
        );
        assert!(
            ml_kem
                .public_key_from_bytes(&public_key[..ml_kem.length_public_key()])
                .is_some()
        );

        let encap = provider.encapsulate(&public_key).unwrap();
        let decap_ss = provider
            .decapsulate(&encap.ciphertext, &private_key)
            .unwrap();

        // Ciphertext: ct_M (1088) || ct_X (32)
        assert_eq!(
            encap.ciphertext.len(),
            ml_kem.length_ciphertext() + X25519Provider::CIPHERTEXT_SIZE
        );
        assert!(
            ml_kem
                .ciphertext_from_bytes(&encap.ciphertext[..ml_kem.length_ciphertext()])
                .is_some()
        );
        assert_eq!(encap.shared_secret.len(), 32);

        assert_eq!(encap.shared_secret, decap_ss);
    }
}
