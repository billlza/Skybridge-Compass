use crate::error::CoreError;
use p256::{ecdh::EphemeralSecret, elliptic_curve::sec1::ToEncodedPoint, PublicKey};
use std::sync::Mutex;

/// Encapsulates symmetric material derived during a session handshake.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionSecrets {
    pub shared_secret: Vec<u8>,
}

/// Stores ephemeral key material for a single handshake attempt.
pub struct KeyMaterial {
    pub public_key: Vec<u8>,
    secret: EphemeralSecret,
}

impl KeyMaterial {
    fn derive(&self, peer_public_key: &[u8]) -> Result<Vec<u8>, CoreError> {
        let peer_public =
            PublicKey::from_sec1_bytes(peer_public_key).map_err(|_| CoreError::InvalidCryptoKey)?;
        let shared = self.secret.diffie_hellman(&peer_public);
        Ok(shared.raw_secret_bytes().to_vec())
    }
}

/// Key exchange abstraction so algorithms (P-256 today, PQC later) can be swapped.
#[async_trait::async_trait(?Send)]
pub trait KeyExchangeProvider {
    async fn generate(&self) -> Result<KeyMaterial, CoreError>;
    async fn derive_shared(
        &self,
        key_material: &KeyMaterial,
        peer_public_key: &[u8],
    ) -> Result<Vec<u8>, CoreError>;
    fn algorithm(&self) -> &'static str;
}

/// Session-level crypto that owns identity validation and leverages a key exchange provider.
#[async_trait::async_trait(?Send)]
pub trait SessionCryptoProvider {
    async fn validate_device_identity(&self) -> Result<(), CoreError>;
    async fn begin_handshake(&self) -> Result<Vec<u8>, CoreError>;
    async fn finalize_handshake(&self, peer_public_key: &[u8])
        -> Result<SessionSecrets, CoreError>;
    fn local_public_key(&self) -> Option<Vec<u8>>;
    fn algorithm(&self) -> &'static str;
}

/// Extension point for post-quantum algorithms (e.g., ML-KEM families via HPKE).
/// Implementations can mirror `KeyExchangeProvider` for PQC key exchange without
/// altering the session-facing API.
#[async_trait::async_trait(?Send)]
pub trait PqcKeyExchangeProvider: KeyExchangeProvider {
    /// Returns the PQC algorithm family (e.g., ML-KEM, BIKE, HQC) when available.
    fn pqc_algorithm(&self) -> &'static str;
}

/// Default P-256 key exchange implementation.
pub struct P256KeyExchange;

#[async_trait::async_trait(?Send)]
impl KeyExchangeProvider for P256KeyExchange {
    async fn generate(&self) -> Result<KeyMaterial, CoreError> {
        let secret = EphemeralSecret::random(&mut rand_core::OsRng);
        let public_point = PublicKey::from(&secret);
        Ok(KeyMaterial {
            public_key: public_point.to_encoded_point(false).as_bytes().to_vec(),
            secret,
        })
    }

    async fn derive_shared(
        &self,
        key_material: &KeyMaterial,
        peer_public_key: &[u8],
    ) -> Result<Vec<u8>, CoreError> {
        key_material.derive(peer_public_key)
    }

    fn algorithm(&self) -> &'static str {
        "P-256"
    }
}

/// Session crypto backed by the default P-256 key exchange.
pub struct P256SessionCrypto<E: KeyExchangeProvider + Send + Sync> {
    exchange: E,
    local_key: Mutex<Option<KeyMaterial>>,
}

impl<E: KeyExchangeProvider + Send + Sync> P256SessionCrypto<E> {
    pub fn new(exchange: E) -> Self {
        Self {
            exchange,
            local_key: Mutex::new(None),
        }
    }
}

#[async_trait::async_trait(?Send)]
impl<E> SessionCryptoProvider for P256SessionCrypto<E>
where
    E: KeyExchangeProvider + Send + Sync,
{
    async fn validate_device_identity(&self) -> Result<(), CoreError> {
        // Placeholder for platform trust roots; succeed by default.
        Ok(())
    }

    async fn begin_handshake(&self) -> Result<Vec<u8>, CoreError> {
        let material = self.exchange.generate().await?;
        let public_key = material.public_key.clone();
        *self.local_key.lock().unwrap() = Some(material);
        Ok(public_key)
    }

    async fn finalize_handshake(
        &self,
        peer_public_key: &[u8],
    ) -> Result<SessionSecrets, CoreError> {
        let local = {
            let mut guard = self.local_key.lock().unwrap();
            guard.take().ok_or(CoreError::MissingCryptoMaterial)?
        };
        let shared = self.exchange.derive_shared(&local, peer_public_key).await?;
        *self.local_key.lock().unwrap() = Some(local);
        Ok(SessionSecrets {
            shared_secret: shared,
        })
    }

    fn local_public_key(&self) -> Option<Vec<u8>> {
        self.local_key
            .lock()
            .unwrap()
            .as_ref()
            .map(|m| m.public_key.clone())
    }

    fn algorithm(&self) -> &'static str {
        self.exchange.algorithm()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn p256_handshake_succeeds_and_matches_shared_secret() {
        let local_crypto = P256SessionCrypto::new(P256KeyExchange);
        let remote_crypto = P256SessionCrypto::new(P256KeyExchange);

        let local_pub = local_crypto.begin_handshake().await.unwrap();
        let remote_pub = remote_crypto.begin_handshake().await.unwrap();

        let local_shared = local_crypto
            .finalize_handshake(&remote_pub)
            .await
            .unwrap()
            .shared_secret;
        let remote_shared = remote_crypto
            .finalize_handshake(&local_pub)
            .await
            .unwrap()
            .shared_secret;

        assert_eq!(local_shared, remote_shared);
        assert!(!local_shared.is_empty());
    }

    #[tokio::test]
    async fn handshake_fails_with_invalid_peer_key() {
        let crypto = P256SessionCrypto::new(P256KeyExchange);
        crypto.begin_handshake().await.unwrap();

        let err = crypto
            .finalize_handshake(&[1, 2, 3])
            .await
            .expect_err("invalid key should fail");
        assert!(matches!(err, CoreError::InvalidCryptoKey));
    }

    #[tokio::test]
    async fn handshake_requires_local_material() {
        let crypto = P256SessionCrypto::new(P256KeyExchange);
        let err = crypto
            .finalize_handshake(&[0u8; 65])
            .await
            .expect_err("missing local key");
        assert!(matches!(err, CoreError::MissingCryptoMaterial));
    }
}
