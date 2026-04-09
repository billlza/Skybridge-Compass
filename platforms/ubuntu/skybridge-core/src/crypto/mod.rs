//! Cryptography module
//!
//! Provides cryptographic primitives and protocols compatible with
//! macOS/Android implementations, including post-quantum algorithms.

#![allow(missing_docs)]

pub mod aead;
pub mod kem;
pub mod provider;
pub mod signature;
pub mod suite;

pub use aead::{AeadProvider, AesGcmProvider, ChaChaPolyProvider};
pub use kem::{KemProvider, MlKem768Provider, X25519Provider, XWingProvider};
pub use provider::{CryptoProvider, HpkeSealedBox};
pub use signature::{Ed25519Provider, MlDsa65Provider, SignatureAlgorithm, SignatureProvider};
pub use suite::{CryptoSuite, CryptoSuiteId};

/// Key derivation with HKDF-SHA256
pub mod kdf {
    use hkdf::Hkdf;
    use sha2::Sha256;

    /// Derive a key using HKDF-SHA256
    pub fn derive_key(ikm: &[u8], salt: Option<&[u8]>, info: &[u8], output_len: usize) -> Vec<u8> {
        let hkdf = Hkdf::<Sha256>::new(salt, ikm);
        let mut output = vec![0u8; output_len];
        hkdf.expand(info, &mut output)
            .expect("HKDF expand failed - output length too large");
        output
    }

    /// Derive multiple keys from the same IKM
    pub fn derive_session_keys(
        shared_secret: &[u8],
        transcript: &[u8],
    ) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        let salt = crate::domain_separator::KEY_DERIVATION;

        // Derive keys for different channels
        let control_key = derive_key(
            shared_secret,
            Some(salt),
            &[transcript, b"control"].concat(),
            32,
        );
        let video_key = derive_key(
            shared_secret,
            Some(salt),
            &[transcript, b"video"].concat(),
            32,
        );
        let file_key = derive_key(
            shared_secret,
            Some(salt),
            &[transcript, b"file"].concat(),
            32,
        );

        (control_key, video_key, file_key)
    }
}
