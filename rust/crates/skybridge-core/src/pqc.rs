use anyhow::{Result, anyhow, bail};
use pqcrypto_mldsa::mldsa65;
use pqcrypto_mlkem::mlkem768;
use pqcrypto_traits::kem::{
    Ciphertext as KemCiphertextTrait, PublicKey as KemPublicKeyTrait,
    SecretKey as KemSecretKeyTrait, SharedSecret as KemSharedSecretTrait,
};
use pqcrypto_traits::sign::{
    DetachedSignature as SignDetachedSignatureTrait, PublicKey as SignPublicKeyTrait,
    SecretKey as SignSecretKeyTrait,
};
use sha3::{Digest, Sha3_256};
use x25519_dalek::{EphemeralSecret, PublicKey as X25519PublicKey, StaticSecret};

use crate::{CryptoSuite, ProtocolSigningAlgorithm};

pub const MLDSA65_PUBLIC_KEY_BYTES: usize = mldsa65::public_key_bytes();
pub const MLDSA65_SECRET_KEY_BYTES: usize = mldsa65::secret_key_bytes();
pub const MLDSA65_SIGNATURE_MAX_BYTES: usize = mldsa65::signature_bytes();
pub const MLKEM768_PUBLIC_KEY_BYTES: usize = mlkem768::public_key_bytes();
pub const MLKEM768_SECRET_KEY_BYTES: usize = mlkem768::secret_key_bytes();
pub const MLKEM768_CIPHERTEXT_BYTES: usize = mlkem768::ciphertext_bytes();
pub const MLKEM768_SHARED_SECRET_BYTES: usize = mlkem768::shared_secret_bytes();
pub const X25519_PUBLIC_KEY_BYTES: usize = 32;
pub const X25519_SECRET_KEY_BYTES: usize = 32;
pub const XWING_PUBLIC_KEY_BYTES: usize = MLKEM768_PUBLIC_KEY_BYTES + X25519_PUBLIC_KEY_BYTES;
pub const XWING_SECRET_KEY_BYTES: usize = MLKEM768_SECRET_KEY_BYTES + X25519_SECRET_KEY_BYTES;
pub const XWING_CIPHERTEXT_BYTES: usize = MLKEM768_CIPHERTEXT_BYTES + X25519_PUBLIC_KEY_BYTES;
const XWING_LABEL: &[u8] = b"\\.//^\\";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RustPqcIdentityMaterial {
    pub signing_algorithm: ProtocolSigningAlgorithm,
    pub signing_public_key: Vec<u8>,
    pub signing_secret_key: Vec<u8>,
    pub mlkem768_public_key: Vec<u8>,
    pub mlkem768_secret_key: Vec<u8>,
    pub xwing_public_key: Vec<u8>,
    pub xwing_secret_key: Vec<u8>,
}

impl RustPqcIdentityMaterial {
    pub fn generate() -> Result<Self> {
        let (signing_public_key, signing_secret_key) = mldsa65_generate_keypair();
        let (mlkem768_public_key, mlkem768_secret_key) = mlkem768_generate_keypair();
        let (xwing_public_key, xwing_secret_key) = xwing_generate_keypair();
        Ok(Self {
            signing_algorithm: ProtocolSigningAlgorithm::MlDsa65,
            signing_public_key,
            signing_secret_key,
            mlkem768_public_key,
            mlkem768_secret_key,
            xwing_public_key,
            xwing_secret_key,
        })
    }

    pub fn public_key_for_suite(&self, suite: CryptoSuite) -> Option<&[u8]> {
        match suite.canonical_kem_suite().wire_id {
            0x0001 => Some(&self.xwing_public_key),
            0x0101 => Some(&self.mlkem768_public_key),
            _ => None,
        }
    }
}

pub fn mldsa65_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    let (public_key, secret_key) = mldsa65::keypair();
    (
        public_key.as_bytes().to_vec(),
        secret_key.as_bytes().to_vec(),
    )
}

pub fn mldsa65_sign_detached(message: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    let secret_key = mldsa65::SecretKey::from_bytes(secret_key)
        .map_err(|error| anyhow!("invalid ML-DSA-65 secret key: {error}"))?;
    Ok(mldsa65::detached_sign(message, &secret_key)
        .as_bytes()
        .to_vec())
}

pub fn mldsa65_verify_detached(message: &[u8], signature: &[u8], public_key: &[u8]) -> Result<()> {
    let signature = mldsa65::DetachedSignature::from_bytes(signature)
        .map_err(|error| anyhow!("invalid ML-DSA-65 signature: {error}"))?;
    let public_key = mldsa65::PublicKey::from_bytes(public_key)
        .map_err(|error| anyhow!("invalid ML-DSA-65 public key: {error}"))?;
    mldsa65::verify_detached_signature(&signature, message, &public_key)
        .map_err(|error| anyhow!("ML-DSA-65 signature verification failed: {error}"))
}

pub fn mlkem768_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    let (public_key, secret_key) = mlkem768::keypair();
    (
        public_key.as_bytes().to_vec(),
        secret_key.as_bytes().to_vec(),
    )
}

pub fn mlkem768_encapsulate(public_key: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let public_key = mlkem768::PublicKey::from_bytes(public_key)
        .map_err(|error| anyhow!("invalid ML-KEM-768 public key: {error}"))?;
    let (shared_secret, ciphertext) = mlkem768::encapsulate(&public_key);
    Ok((
        ciphertext.as_bytes().to_vec(),
        shared_secret.as_bytes().to_vec(),
    ))
}

pub fn mlkem768_decapsulate(ciphertext: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    let ciphertext = mlkem768::Ciphertext::from_bytes(ciphertext)
        .map_err(|error| anyhow!("invalid ML-KEM-768 ciphertext: {error}"))?;
    let secret_key = mlkem768::SecretKey::from_bytes(secret_key)
        .map_err(|error| anyhow!("invalid ML-KEM-768 secret key: {error}"))?;
    Ok(mlkem768::decapsulate(&ciphertext, &secret_key)
        .as_bytes()
        .to_vec())
}

pub fn xwing_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    let (mlkem_public_key, mlkem_secret_key) = mlkem768_generate_keypair();
    let x25519_secret_key = StaticSecret::random();
    let x25519_public_key = X25519PublicKey::from(&x25519_secret_key);
    let mut public_key = Vec::with_capacity(XWING_PUBLIC_KEY_BYTES);
    public_key.extend_from_slice(&mlkem_public_key);
    public_key.extend_from_slice(x25519_public_key.as_bytes());
    let mut secret_key = Vec::with_capacity(XWING_SECRET_KEY_BYTES);
    secret_key.extend_from_slice(&mlkem_secret_key);
    secret_key.extend_from_slice(x25519_secret_key.to_bytes().as_ref());
    (public_key, secret_key)
}

pub fn xwing_encapsulate(public_key: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    if public_key.len() != XWING_PUBLIC_KEY_BYTES {
        bail!(
            "invalid X-Wing public key length: expected {} bytes, got {}",
            XWING_PUBLIC_KEY_BYTES,
            public_key.len()
        );
    }
    let (mlkem_public_key, x25519_public_key) = public_key.split_at(MLKEM768_PUBLIC_KEY_BYTES);
    let (mlkem_ciphertext, mlkem_shared_secret) = mlkem768_encapsulate(mlkem_public_key)?;
    let ephemeral_secret = EphemeralSecret::random();
    let x25519_ciphertext = X25519PublicKey::from(&ephemeral_secret);
    let x25519_public_key: [u8; X25519_PUBLIC_KEY_BYTES] = x25519_public_key
        .try_into()
        .map_err(|_| anyhow!("invalid X-Wing X25519 public key length"))?;
    let x25519_shared_secret =
        ephemeral_secret.diffie_hellman(&X25519PublicKey::from(x25519_public_key));
    let combined = xwing_combiner(
        &mlkem_shared_secret,
        x25519_shared_secret.as_bytes(),
        x25519_ciphertext.as_bytes(),
        &x25519_public_key,
    );
    let mut ciphertext = Vec::with_capacity(XWING_CIPHERTEXT_BYTES);
    ciphertext.extend_from_slice(&mlkem_ciphertext);
    ciphertext.extend_from_slice(x25519_ciphertext.as_bytes());
    Ok((ciphertext, combined))
}

pub fn xwing_decapsulate(ciphertext: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    if ciphertext.len() != XWING_CIPHERTEXT_BYTES {
        bail!(
            "invalid X-Wing ciphertext length: expected {} bytes, got {}",
            XWING_CIPHERTEXT_BYTES,
            ciphertext.len()
        );
    }
    if secret_key.len() != XWING_SECRET_KEY_BYTES {
        bail!(
            "invalid X-Wing secret key length: expected {} bytes, got {}",
            XWING_SECRET_KEY_BYTES,
            secret_key.len()
        );
    }
    let (mlkem_secret_key, x25519_secret_key) = secret_key.split_at(MLKEM768_SECRET_KEY_BYTES);
    let (mlkem_ciphertext, x25519_ciphertext) = ciphertext.split_at(MLKEM768_CIPHERTEXT_BYTES);
    let mlkem_shared_secret = mlkem768_decapsulate(mlkem_ciphertext, mlkem_secret_key)?;
    let x25519_secret_key: [u8; X25519_SECRET_KEY_BYTES] = x25519_secret_key
        .try_into()
        .map_err(|_| anyhow!("invalid X-Wing X25519 secret key length"))?;
    let static_secret = StaticSecret::from(x25519_secret_key);
    let local_public_key = X25519PublicKey::from(&static_secret);
    let x25519_ciphertext: [u8; X25519_PUBLIC_KEY_BYTES] = x25519_ciphertext
        .try_into()
        .map_err(|_| anyhow!("invalid X-Wing X25519 ciphertext length"))?;
    let x25519_shared_secret =
        static_secret.diffie_hellman(&X25519PublicKey::from(x25519_ciphertext));
    Ok(xwing_combiner(
        &mlkem_shared_secret,
        x25519_shared_secret.as_bytes(),
        &x25519_ciphertext,
        local_public_key.as_bytes(),
    ))
}

fn xwing_combiner(
    mlkem_shared_secret: &[u8],
    x25519_shared_secret: &[u8],
    x25519_ciphertext: &[u8],
    x25519_public_key: &[u8],
) -> Vec<u8> {
    let mut hasher = Sha3_256::new();
    hasher.update(XWING_LABEL);
    hasher.update(mlkem_shared_secret);
    hasher.update(x25519_shared_secret);
    hasher.update(x25519_ciphertext);
    hasher.update(x25519_public_key);
    hasher.finalize().to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mldsa65_round_trip_sign_and_verify() -> Result<()> {
        let (public_key, secret_key) = mldsa65_generate_keypair();
        let message = b"rust-native-pqc-mldsa";
        let signature = mldsa65_sign_detached(message, &secret_key)?;
        mldsa65_verify_detached(message, &signature, &public_key)?;
        Ok(())
    }

    #[test]
    fn mlkem768_round_trip_encapsulation() -> Result<()> {
        let (public_key, secret_key) = mlkem768_generate_keypair();
        let (ciphertext, sender_secret) = mlkem768_encapsulate(&public_key)?;
        let receiver_secret = mlkem768_decapsulate(&ciphertext, &secret_key)?;
        assert_eq!(sender_secret, receiver_secret);
        Ok(())
    }

    #[test]
    fn xwing_round_trip_encapsulation() -> Result<()> {
        let (public_key, secret_key) = xwing_generate_keypair();
        let (ciphertext, sender_secret) = xwing_encapsulate(&public_key)?;
        let receiver_secret = xwing_decapsulate(&ciphertext, &secret_key)?;
        assert_eq!(sender_secret, receiver_secret);
        Ok(())
    }

    #[test]
    fn rust_pqc_identity_bundle_contains_expected_key_sizes() -> Result<()> {
        let identity = RustPqcIdentityMaterial::generate()?;
        assert_eq!(
            identity.signing_algorithm,
            ProtocolSigningAlgorithm::MlDsa65
        );
        assert_eq!(identity.signing_public_key.len(), MLDSA65_PUBLIC_KEY_BYTES);
        assert_eq!(identity.signing_secret_key.len(), MLDSA65_SECRET_KEY_BYTES);
        assert_eq!(
            identity.mlkem768_public_key.len(),
            MLKEM768_PUBLIC_KEY_BYTES
        );
        assert_eq!(
            identity.mlkem768_secret_key.len(),
            MLKEM768_SECRET_KEY_BYTES
        );
        assert_eq!(identity.xwing_public_key.len(), XWING_PUBLIC_KEY_BYTES);
        assert_eq!(identity.xwing_secret_key.len(), XWING_SECRET_KEY_BYTES);
        Ok(())
    }
}
