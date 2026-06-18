//! Post-quantum cryptography providers for SkyBridge `Win <-> other` peers.
//!
//! This module makes the PQC suites declared in [`crate::suite`] real:
//!
//! * **ML-KEM-768** (FIPS 203) — the pure post-quantum KEM behind
//!   [`CryptoSuite::MlKem768MlDsa65`].
//! * **X-Wing** (X25519 + ML-KEM-768, the IETF `draft-connolly-cfrg-xwing-kem`
//!   hybrid) — behind the preferred [`CryptoSuite::XWingHybrid`]. A hybrid stays
//!   secure as long as *either* primitive holds, so a future break of ML-KEM
//!   degrades to classical X25519 rather than to nothing.
//! * **ML-DSA-65** (FIPS 204) — post-quantum signatures for handshake
//!   authentication (the `SkyBridge-A` / `SkyBridge-B` domains used by the Apple
//!   peer), replacing classical ECDSA on the PQC path.
//!
//! All implementations are pure Rust (`ml-kem`, `x-wing`, `ml-dsa`), so the
//! crate keeps building offline/hermetically with no `liboqs`/C toolchain.
//!
//! ## KEM vs. ECDH
//!
//! The classic [`crate::crypto`] path is ECDH-symmetric: both peers generate a
//! keypair, swap public keys, and each derives the same secret. A KEM is
//! asymmetric:
//!
//! 1. the **initiator** generates a keypair and sends its *encapsulation key*;
//! 2. the **responder** encapsulates a fresh secret to that key, obtaining a
//!    *ciphertext* (sent back) and the shared secret;
//! 3. the **initiator** decapsulates the ciphertext with its private key to
//!    recover the identical shared secret.
//!
//! The recovered shared secret is fed into the *same* HKDF-SHA256 → AES-256-GCM
//! session layer ([`crate::crypto::SessionSecrets`]) as the classic path, so
//! frame sealing is byte-identical regardless of the negotiated suite.

use crate::crypto::SessionSecrets;
use crate::error::CoreError;
use crate::suite::CryptoSuite;

use ml_kem::{
    Ciphertext as MlKemCiphertext, Decapsulate, Encapsulate, EncapsulationKey as MlKemEncapKey,
    Kem as _, Key as MlKemKey, KeyExport, MlKem768,
};
use std::sync::Mutex;
use zeroize::{Zeroize, Zeroizing};

/// Size in bytes of a serialized ML-KEM-768 encapsulation key.
pub const ML_KEM_768_ENCAPSULATION_KEY_LEN: usize = 1184;
/// Size in bytes of a serialized ML-KEM-768 ciphertext.
pub const ML_KEM_768_CIPHERTEXT_LEN: usize = 1088;
/// Size in bytes of a serialized X-Wing encapsulation key.
pub const X_WING_ENCAPSULATION_KEY_LEN: usize = x_wing::ENCAPSULATION_KEY_SIZE;
/// Size in bytes of a serialized X-Wing ciphertext.
pub const X_WING_CIPHERTEXT_LEN: usize = x_wing::CIPHERTEXT_SIZE;

/// An initiator's KEM keypair. The public encapsulation key is serialized for
/// the wire; the private decapsulation key stays typed inside this struct and
/// is never serialized, and is zeroized on drop by the underlying crate.
pub struct KemKeyPair {
    /// Serialized encapsulation (public) key to publish to the peer.
    pub encapsulation_key: Vec<u8>,
    private: KemPrivateKey,
}

impl KemKeyPair {
    /// The serialized encapsulation (public) key bytes.
    pub fn encapsulation_key(&self) -> &[u8] {
        &self.encapsulation_key
    }
}

/// Algorithm-tagged private decapsulation key. Boxed to keep [`KemKeyPair`]
/// small and `Send`/`Sync` regardless of which concrete key type it holds.
enum KemPrivateKey {
    MlKem768(Box<ml_kem::DecapsulationKey<MlKem768>>),
    XWing(Box<x_wing::DecapsulationKey>),
}

/// Output of responder-side encapsulation: the ciphertext to return to the
/// initiator plus the locally-derived shared secret. The secret is held in a
/// `Zeroizing` buffer wiped on drop; the crate-returned KEM secret is also
/// explicitly zeroized at the source after being copied here (the `ml-kem` /
/// `x-wing` `SharedKey = Array<u8, U32>` is NOT zeroized on drop, since `u8`
/// has no `ZeroizeOnDrop`).
pub struct KemEncapsulation {
    /// Serialized ciphertext to send back to the initiator.
    pub ciphertext: Vec<u8>,
    /// Shared secret derived by the responder (wiped on drop).
    pub shared_secret: Zeroizing<Vec<u8>>,
}

/// A key-encapsulation-mechanism provider (ML-KEM-768 or X-Wing hybrid).
///
/// `dyn`-safe so a negotiated suite can be turned into a provider at runtime via
/// [`kem_provider_for_suite`].
pub trait KemProvider {
    /// Human-readable algorithm label.
    fn algorithm(&self) -> &'static str;
    /// The [`CryptoSuite`] this provider backs.
    fn suite(&self) -> CryptoSuite;
    /// Initiator: generate a fresh keypair.
    fn generate(&self) -> Result<KemKeyPair, CoreError>;
    /// Responder: encapsulate a fresh shared secret to `peer_encapsulation_key`.
    fn encapsulate(&self, peer_encapsulation_key: &[u8]) -> Result<KemEncapsulation, CoreError>;
    /// Initiator: decapsulate `ciphertext` with `key_pair` to recover the secret.
    fn decapsulate(
        &self,
        key_pair: &KemKeyPair,
        ciphertext: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, CoreError>;
}

/// ML-KEM-768 (FIPS 203) key encapsulation.
pub struct MlKem768Kem;

impl KemProvider for MlKem768Kem {
    fn algorithm(&self) -> &'static str {
        "ML-KEM-768"
    }

    fn suite(&self) -> CryptoSuite {
        CryptoSuite::MlKem768MlDsa65
    }

    fn generate(&self) -> Result<KemKeyPair, CoreError> {
        let (dk, ek) = MlKem768::generate_keypair();
        Ok(KemKeyPair {
            encapsulation_key: ek.to_bytes().to_vec(),
            private: KemPrivateKey::MlKem768(Box::new(dk)),
        })
    }

    fn encapsulate(&self, peer_encapsulation_key: &[u8]) -> Result<KemEncapsulation, CoreError> {
        let key = MlKemKey::<MlKemEncapKey<MlKem768>>::try_from(peer_encapsulation_key)
            .map_err(|_| CoreError::InvalidCryptoKey)?;
        let ek = MlKemEncapKey::<MlKem768>::new(&key).map_err(|_| CoreError::InvalidCryptoKey)?;
        let (ct, mut ss) = ek.encapsulate();
        let shared_secret = Zeroizing::new(ss.to_vec());
        ss.zeroize(); // wipe the crate-returned Array (not ZeroizeOnDrop for u8)
        Ok(KemEncapsulation {
            ciphertext: ct.to_vec(),
            shared_secret,
        })
    }

    fn decapsulate(
        &self,
        key_pair: &KemKeyPair,
        ciphertext: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, CoreError> {
        let KemPrivateKey::MlKem768(dk) = &key_pair.private else {
            return Err(CoreError::CryptoHandshake(
                "key pair algorithm does not match ML-KEM-768 provider".into(),
            ));
        };
        let ct = MlKemCiphertext::<MlKem768>::try_from(ciphertext)
            .map_err(|_| CoreError::Decrypt("ML-KEM-768 ciphertext length mismatch".into()))?;
        let mut ss = dk.decapsulate(&ct);
        let shared = Zeroizing::new(ss.to_vec());
        ss.zeroize();
        Ok(shared)
    }
}

/// X-Wing (X25519 + ML-KEM-768) hybrid key encapsulation.
pub struct XWingHybridKem;

impl KemProvider for XWingHybridKem {
    fn algorithm(&self) -> &'static str {
        "X-Wing(X25519+ML-KEM-768)"
    }

    fn suite(&self) -> CryptoSuite {
        CryptoSuite::XWingHybrid
    }

    fn generate(&self) -> Result<KemKeyPair, CoreError> {
        let (sk, pk) = x_wing::XWingKem::generate_keypair();
        Ok(KemKeyPair {
            encapsulation_key: pk.to_bytes().to_vec(),
            private: KemPrivateKey::XWing(Box::new(sk)),
        })
    }

    fn encapsulate(&self, peer_encapsulation_key: &[u8]) -> Result<KemEncapsulation, CoreError> {
        let pk = x_wing::EncapsulationKey::try_from(peer_encapsulation_key)
            .map_err(|_| CoreError::InvalidCryptoKey)?;
        let (ct, mut ss) = pk.encapsulate();
        let shared_secret = Zeroizing::new(ss.to_vec());
        ss.zeroize(); // wipe the crate-returned Array (not ZeroizeOnDrop for u8)
        Ok(KemEncapsulation {
            ciphertext: ct.to_vec(),
            shared_secret,
        })
    }

    fn decapsulate(
        &self,
        key_pair: &KemKeyPair,
        ciphertext: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, CoreError> {
        let KemPrivateKey::XWing(sk) = &key_pair.private else {
            return Err(CoreError::CryptoHandshake(
                "key pair algorithm does not match X-Wing provider".into(),
            ));
        };
        let ct = x_wing::Ciphertext::try_from(ciphertext)
            .map_err(|_| CoreError::Decrypt("X-Wing ciphertext length mismatch".into()))?;
        let mut ss = sk.decapsulate(&ct);
        let shared = Zeroizing::new(ss.to_vec());
        ss.zeroize();
        Ok(shared)
    }
}

/// Resolves a negotiated [`CryptoSuite`] to its KEM provider, if it is a
/// post-quantum suite. Classic suites (`X25519Ed25519`, `P256Ecdsa`) return
/// `None` because they use the ECDH path in [`crate::crypto`].
pub fn kem_provider_for_suite(suite: CryptoSuite) -> Option<Box<dyn KemProvider>> {
    match suite {
        CryptoSuite::XWingHybrid => Some(Box::new(XWingHybridKem)),
        CryptoSuite::MlKem768MlDsa65 => Some(Box::new(MlKem768Kem)),
        CryptoSuite::X25519Ed25519 | CryptoSuite::P256Ecdsa => None,
    }
}

/// Drives a KEM handshake for one role and yields the AEAD-ready
/// [`SessionSecrets`]. The same provider type is used by both peers; only the
/// methods invoked differ (initiator: [`Self::begin`] then
/// [`Self::complete_initiator`]; responder: [`Self::respond`]).
pub struct KemSession {
    provider: Box<dyn KemProvider>,
    pending: Mutex<Option<KemKeyPair>>,
}

impl KemSession {
    /// Creates a session for the given KEM provider.
    pub fn new(provider: Box<dyn KemProvider>) -> Self {
        Self {
            provider,
            pending: Mutex::new(None),
        }
    }

    /// Convenience constructor from a negotiated suite. Returns `None` for
    /// classic suites that do not use a KEM.
    pub fn for_suite(suite: CryptoSuite) -> Option<Self> {
        kem_provider_for_suite(suite).map(Self::new)
    }

    /// The algorithm label of the underlying provider.
    pub fn algorithm(&self) -> &'static str {
        self.provider.algorithm()
    }

    /// Initiator step 1: generate a keypair, retain the private half, and return
    /// the encapsulation key bytes to send to the responder.
    pub fn begin(&self) -> Result<Vec<u8>, CoreError> {
        let key_pair = self.provider.generate()?;
        let encapsulation_key = key_pair.encapsulation_key.clone();
        *self.pending.lock().unwrap() = Some(key_pair);
        Ok(encapsulation_key)
    }

    /// Responder: encapsulate to the initiator's encapsulation key, returning the
    /// ciphertext to send back plus the derived session secrets.
    pub fn respond(
        &self,
        peer_encapsulation_key: &[u8],
    ) -> Result<(Vec<u8>, SessionSecrets), CoreError> {
        let encapsulation = self.provider.encapsulate(peer_encapsulation_key)?;
        let secrets = SessionSecrets::new(&encapsulation.shared_secret, self.provider.suite())?;
        Ok((encapsulation.ciphertext, secrets))
    }

    /// Initiator step 2: decapsulate the responder's ciphertext with the keypair
    /// retained by [`Self::begin`], yielding the matching session secrets.
    pub fn complete_initiator(&self, ciphertext: &[u8]) -> Result<SessionSecrets, CoreError> {
        let key_pair = self
            .pending
            .lock()
            .unwrap()
            .take()
            .ok_or(CoreError::MissingCryptoMaterial)?;
        let shared = self.provider.decapsulate(&key_pair, ciphertext)?;
        SessionSecrets::new(&shared, self.provider.suite())
    }
}

// ---------------------------------------------------------------------------
// ML-DSA-65 (FIPS 204) signatures
// ---------------------------------------------------------------------------

/// FIPS 204 ML-DSA context string for the initiator's handshake transcript
/// signature (mirrors the Apple peer's `SkyBridge-A` domain).
pub const ML_DSA_CONTEXT_INITIATOR: &[u8] = b"SkyBridge-A";
/// FIPS 204 ML-DSA context string for the responder's handshake transcript
/// signature (mirrors the Apple peer's `SkyBridge-B` domain).
pub const ML_DSA_CONTEXT_RESPONDER: &[u8] = b"SkyBridge-B";

/// An ML-DSA-65 signing identity. Holds the secret signing key (zeroized on
/// drop) and can export its verifying (public) key for the peer.
pub struct MlDsa65Identity {
    signing_key: ml_dsa::SigningKey<ml_dsa::MlDsa65>,
}

impl MlDsa65Identity {
    /// Generates a fresh ML-DSA-65 signing identity using OS entropy.
    pub fn generate() -> Self {
        use ml_dsa::Generate as _;
        Self {
            signing_key: ml_dsa::SigningKey::<ml_dsa::MlDsa65>::generate(),
        }
    }

    /// The serialized verifying (public) key to publish to the peer.
    pub fn verifying_key_bytes(&self) -> Vec<u8> {
        use ml_dsa::signature::Keypair as _;
        self.signing_key.verifying_key().encode().to_vec()
    }

    /// Deterministically signs `message` under the FIPS 204 `context` domain.
    pub fn sign(&self, message: &[u8], context: &[u8]) -> Result<Vec<u8>, CoreError> {
        let signature = self
            .signing_key
            .expanded_key()
            .sign_deterministic(message, context)
            .map_err(|e| CoreError::Crypto(format!("ML-DSA-65 sign failed: {e}")))?;
        Ok(signature.encode().to_vec())
    }
}

/// Verifies an ML-DSA-65 `signature` over `message` under `context` against the
/// serialized `verifying_key`. Returns `Ok(true)` on a valid signature,
/// `Ok(false)` on a well-formed-but-invalid signature, and `Err` if either the
/// verifying key or signature bytes are malformed.
pub fn verify_ml_dsa65(
    verifying_key: &[u8],
    message: &[u8],
    context: &[u8],
    signature: &[u8],
) -> Result<bool, CoreError> {
    use ml_dsa::{EncodedSignature, EncodedVerifyingKey, MlDsa65, Signature, VerifyingKey};

    let vk_encoded = EncodedVerifyingKey::<MlDsa65>::try_from(verifying_key)
        .map_err(|_| CoreError::InvalidCryptoKey)?;
    let vk = VerifyingKey::<MlDsa65>::decode(&vk_encoded);

    let sig_encoded = EncodedSignature::<MlDsa65>::try_from(signature)
        .map_err(|_| CoreError::Crypto("ML-DSA-65 signature length mismatch".into()))?;
    let Some(sig) = Signature::<MlDsa65>::decode(&sig_encoded) else {
        return Ok(false);
    };

    Ok(vk.verify_with_context(message, context, &sig))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::suite::{
        negotiate_suite, CryptoProviderCapabilities, CryptoSuiteAudit, CryptoSuitePolicy,
    };

    fn kem_handshake_yields_matching_secret(provider_a: Box<dyn KemProvider>, suite: CryptoSuite) {
        let provider_b = kem_provider_for_suite(suite).unwrap();
        let initiator = KemSession::new(provider_a);
        let responder = KemSession::new(provider_b);

        // Initiator publishes its encapsulation key.
        let encapsulation_key = initiator.begin().unwrap();

        // Responder encapsulates to it.
        let (ciphertext, responder_secrets) = responder.respond(&encapsulation_key).unwrap();

        // Initiator decapsulates the returned ciphertext.
        let initiator_secrets = initiator.complete_initiator(&ciphertext).unwrap();

        // Both sides reach the identical AEAD secret; prove it end-to-end by
        // sealing on one side and opening on the other.
        let payload = b"post-quantum payload";
        let sealed = responder_secrets.seal(payload).unwrap();
        let opened = initiator_secrets.open(&sealed).unwrap();
        assert_eq!(opened, payload);

        let sealed_back = initiator_secrets.seal(payload).unwrap();
        let opened_back = responder_secrets.open(&sealed_back).unwrap();
        assert_eq!(opened_back, payload);
    }

    #[test]
    fn ml_kem_768_handshake_roundtrip() {
        kem_handshake_yields_matching_secret(Box::new(MlKem768Kem), CryptoSuite::MlKem768MlDsa65);
    }

    #[test]
    fn x_wing_hybrid_handshake_roundtrip() {
        kem_handshake_yields_matching_secret(Box::new(XWingHybridKem), CryptoSuite::XWingHybrid);
    }

    #[test]
    fn ml_kem_encapsulation_key_and_ciphertext_sizes() {
        let kp = MlKem768Kem.generate().unwrap();
        assert_eq!(
            kp.encapsulation_key().len(),
            ML_KEM_768_ENCAPSULATION_KEY_LEN
        );
        let enc = MlKem768Kem.encapsulate(kp.encapsulation_key()).unwrap();
        assert_eq!(enc.ciphertext.len(), ML_KEM_768_CIPHERTEXT_LEN);
        assert_eq!(enc.shared_secret.len(), 32);
    }

    #[test]
    fn x_wing_encapsulation_key_and_ciphertext_sizes() {
        let kp = XWingHybridKem.generate().unwrap();
        assert_eq!(kp.encapsulation_key().len(), X_WING_ENCAPSULATION_KEY_LEN);
        let enc = XWingHybridKem.encapsulate(kp.encapsulation_key()).unwrap();
        assert_eq!(enc.ciphertext.len(), X_WING_CIPHERTEXT_LEN);
        assert_eq!(enc.shared_secret.len(), 32);
    }

    #[test]
    fn encapsulate_rejects_malformed_peer_key() {
        // `matches!` rather than `expect_err` so `KemEncapsulation` need not derive
        // `Debug` (it holds the shared secret).
        assert!(matches!(
            MlKem768Kem.encapsulate(&[0u8; 8]),
            Err(CoreError::InvalidCryptoKey)
        ));
        assert!(matches!(
            XWingHybridKem.encapsulate(&[0u8; 8]),
            Err(CoreError::InvalidCryptoKey)
        ));
    }

    #[test]
    fn decapsulate_rejects_wrong_length_ciphertext() {
        let kp = MlKem768Kem.generate().unwrap();
        let err = MlKem768Kem
            .decapsulate(&kp, &[0u8; 10])
            .expect_err("short ciphertext must be rejected");
        assert!(matches!(err, CoreError::Decrypt(_)));
    }

    #[test]
    fn decapsulate_rejects_mismatched_provider() {
        // An X-Wing keypair handed to the ML-KEM provider must fail closed.
        let xwing_kp = XWingHybridKem.generate().unwrap();
        let err = MlKem768Kem
            .decapsulate(&xwing_kp, &[0u8; ML_KEM_768_CIPHERTEXT_LEN])
            .expect_err("provider/key mismatch must be rejected");
        assert!(matches!(err, CoreError::CryptoHandshake(_)));
    }

    #[test]
    fn ml_kem_corrupt_ciphertext_yields_divergent_secret() {
        // ML-KEM is IND-CCA: a tampered ciphertext does not error, it implicitly
        // rejects by producing a DIFFERENT shared secret, so the AEAD open fails.
        let initiator = KemSession::new(Box::new(MlKem768Kem));
        let responder = KemSession::new(Box::new(MlKem768Kem));
        let ek = initiator.begin().unwrap();
        let (mut ciphertext, responder_secrets) = responder.respond(&ek).unwrap();
        ciphertext[0] ^= 0xFF;
        let initiator_secrets = initiator.complete_initiator(&ciphertext).unwrap();

        let sealed = responder_secrets.seal(b"secret").unwrap();
        assert!(
            initiator_secrets.open(&sealed).is_err(),
            "divergent secret must fail AEAD authentication"
        );
    }

    #[test]
    fn x_wing_corrupt_ciphertext_yields_divergent_secret() {
        // X-Wing is the PREFERRED suite; its decapsulate combines ML-KEM implicit
        // rejection (ct_m, bytes 0..1088) with X25519 (ct_x, bytes 1088..1120) via
        // a SHA3-256 combiner. Corrupting EITHER half must yield a divergent secret
        // so the AEAD open fails (no error, no silent acceptance).
        for flip_at in [0usize, X_WING_CIPHERTEXT_LEN - 1] {
            let initiator = KemSession::new(Box::new(XWingHybridKem));
            let responder = KemSession::new(Box::new(XWingHybridKem));
            let ek = initiator.begin().unwrap();
            let (mut ciphertext, responder_secrets) = responder.respond(&ek).unwrap();
            ciphertext[flip_at] ^= 0xFF;
            let initiator_secrets = initiator.complete_initiator(&ciphertext).unwrap();

            let sealed = responder_secrets.seal(b"secret").unwrap();
            assert!(
                initiator_secrets.open(&sealed).is_err(),
                "divergent secret (flip at {flip_at}) must fail AEAD authentication"
            );
        }
    }

    #[test]
    fn ml_dsa65_sign_verify_roundtrip() {
        let identity = MlDsa65Identity::generate();
        let vk = identity.verifying_key_bytes();
        let message = b"handshake transcript";
        let signature = identity.sign(message, ML_DSA_CONTEXT_INITIATOR).unwrap();

        assert!(verify_ml_dsa65(&vk, message, ML_DSA_CONTEXT_INITIATOR, &signature).unwrap());
    }

    #[test]
    fn ml_dsa65_rejects_tampered_message_signature_and_context() {
        let identity = MlDsa65Identity::generate();
        let vk = identity.verifying_key_bytes();
        let message = b"handshake transcript";
        let signature = identity.sign(message, ML_DSA_CONTEXT_INITIATOR).unwrap();

        // Tampered message.
        assert!(!verify_ml_dsa65(
            &vk,
            b"different transcript",
            ML_DSA_CONTEXT_INITIATOR,
            &signature
        )
        .unwrap());
        // Wrong domain context (responder vs initiator).
        assert!(!verify_ml_dsa65(&vk, message, ML_DSA_CONTEXT_RESPONDER, &signature).unwrap());
        // Tampered signature.
        let mut bad_sig = signature.clone();
        bad_sig[0] ^= 0xFF;
        assert!(!verify_ml_dsa65(&vk, message, ML_DSA_CONTEXT_INITIATOR, &bad_sig).unwrap());
    }

    #[test]
    fn ml_dsa65_rejects_wrong_signer() {
        let signer = MlDsa65Identity::generate();
        let imposter = MlDsa65Identity::generate();
        let message = b"handshake transcript";
        let signature = signer.sign(message, ML_DSA_CONTEXT_INITIATOR).unwrap();

        assert!(!verify_ml_dsa65(
            &imposter.verifying_key_bytes(),
            message,
            ML_DSA_CONTEXT_INITIATOR,
            &signature
        )
        .unwrap());
    }

    #[test]
    fn ml_dsa65_verify_rejects_malformed_inputs() {
        let identity = MlDsa65Identity::generate();
        let vk = identity.verifying_key_bytes();
        let sig = identity.sign(b"m", ML_DSA_CONTEXT_INITIATOR).unwrap();

        assert!(matches!(
            verify_ml_dsa65(&[0u8; 4], b"m", ML_DSA_CONTEXT_INITIATOR, &sig),
            Err(CoreError::InvalidCryptoKey)
        ));
        assert!(matches!(
            verify_ml_dsa65(&vk, b"m", ML_DSA_CONTEXT_INITIATOR, &[0u8; 4]),
            Err(CoreError::Crypto(_))
        ));
    }

    #[test]
    fn negotiation_with_native_pqc_capabilities_selects_x_wing_under_strict_policy() {
        // With real providers compiled in, strict-PQC negotiation must land on
        // the hybrid suite (and the downgrade gate stays intact elsewhere).
        let selected = negotiate_suite(
            CryptoProviderCapabilities::with_native_pqc(),
            &[
                CryptoSuite::P256Ecdsa.wire_id(),
                CryptoSuite::MlKem768MlDsa65.wire_id(),
                CryptoSuite::XWingHybrid.wire_id(),
            ],
            CryptoSuitePolicy::strict_pqc(),
        )
        .expect("a mutual PQC suite");
        assert_eq!(selected.suite, CryptoSuite::XWingHybrid);
        assert_eq!(selected.audit, CryptoSuiteAudit::HybridPqcPreferred);
        assert!(kem_provider_for_suite(selected.suite).is_some());
    }
}
