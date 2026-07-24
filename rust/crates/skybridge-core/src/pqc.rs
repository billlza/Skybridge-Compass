use anyhow::{Result, anyhow, bail};
use fips203::{
    ml_kem_768,
    traits::{Decaps, Encaps, KeyGen as KemKeyGen, SerDes as KemSerDes},
};
use fips204::{
    ml_dsa_65, ml_dsa_87,
    traits::{KeyGen as DsaKeyGen, SerDes as DsaSerDes, Signer, Verifier},
};
use sha3::{Digest, Sha3_256};
use x25519_dalek::{EphemeralSecret, PublicKey as X25519PublicKey, StaticSecret};

use crate::{CryptoSuite, ProtocolSigningAlgorithm};

// FIPS 203/204 expanded encodings already persisted by SkyBridge identities
// and exchanged with Apple peers. The replacement provider accepts these exact
// fixed-size forms, so the migration does not rotate keys or alter the wire contract.
pub const MLDSA65_PUBLIC_KEY_BYTES: usize = ml_dsa_65::PK_LEN;
pub const MLDSA65_SECRET_KEY_BYTES: usize = ml_dsa_65::SK_LEN;
pub const MLDSA65_SIGNATURE_MAX_BYTES: usize = ml_dsa_65::SIG_LEN;
pub const MLDSA87_PUBLIC_KEY_BYTES: usize = ml_dsa_87::PK_LEN;
pub const MLDSA87_SECRET_KEY_BYTES: usize = ml_dsa_87::SK_LEN;
pub const MLDSA87_SIGNATURE_MAX_BYTES: usize = ml_dsa_87::SIG_LEN;
pub const MLKEM768_PUBLIC_KEY_BYTES: usize = ml_kem_768::EK_LEN;
pub const MLKEM768_SECRET_KEY_BYTES: usize = ml_kem_768::DK_LEN;
pub const MLKEM768_CIPHERTEXT_BYTES: usize = ml_kem_768::CT_LEN;
pub const MLKEM768_SHARED_SECRET_BYTES: usize = fips203::SSK_LEN;
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
    /// EXPERIMENTAL, DEFAULT-OFF (`q-periapt` feature): public half of the
    /// Q-Periapt ContextBound hybrid KEM identity (`pk_pq || pk_trad`).
    #[cfg(feature = "q-periapt")]
    pub qperiapt_public_key: Vec<u8>,
    /// EXPERIMENTAL, DEFAULT-OFF (`q-periapt` feature): secret half of the
    /// Q-Periapt ContextBound hybrid KEM identity (`sk_pq || sk_trad`).
    #[cfg(feature = "q-periapt")]
    pub qperiapt_secret_key: Vec<u8>,
}

impl RustPqcIdentityMaterial {
    pub fn generate() -> Result<Self> {
        Self::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa65)
    }

    pub fn generate_for_algorithm(signing_algorithm: ProtocolSigningAlgorithm) -> Result<Self> {
        let (signing_public_key, signing_secret_key) = mldsa_generate_keypair(signing_algorithm)?;
        let (mlkem768_public_key, mlkem768_secret_key) = mlkem768_generate_keypair();
        let (xwing_public_key, xwing_secret_key) = xwing_generate_keypair();
        #[cfg(feature = "q-periapt")]
        let (qperiapt_public_key, qperiapt_secret_key) = qperiapt_contextbound_generate_keypair();
        Ok(Self {
            signing_algorithm,
            signing_public_key,
            signing_secret_key,
            mlkem768_public_key,
            mlkem768_secret_key,
            xwing_public_key,
            xwing_secret_key,
            #[cfg(feature = "q-periapt")]
            qperiapt_public_key,
            #[cfg(feature = "q-periapt")]
            qperiapt_secret_key,
        })
    }

    pub fn public_key_for_suite(&self, suite: CryptoSuite) -> Option<&[u8]> {
        match suite.canonical_kem_suite().wire_id {
            0x0001 => Some(&self.xwing_public_key),
            0x0101 => Some(&self.mlkem768_public_key),
            #[cfg(feature = "q-periapt")]
            0x0011 => Some(&self.qperiapt_public_key),
            _ => None,
        }
    }
}

pub fn mldsa65_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    let mut seed = cryptographic_randomness("ML-DSA-65 key generation");
    let (public_key, secret_key) = ml_dsa_65::KG::keygen_from_seed(&seed);
    seed.fill(0);
    (
        public_key.into_bytes().to_vec(),
        secret_key.into_bytes().to_vec(),
    )
}

pub fn mldsa87_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    let mut seed = cryptographic_randomness("ML-DSA-87 key generation");
    let (public_key, secret_key) = ml_dsa_87::KG::keygen_from_seed(&seed);
    seed.fill(0);
    (
        public_key.into_bytes().to_vec(),
        secret_key.into_bytes().to_vec(),
    )
}

pub fn mldsa_generate_keypair(algorithm: ProtocolSigningAlgorithm) -> Result<(Vec<u8>, Vec<u8>)> {
    match algorithm {
        ProtocolSigningAlgorithm::MlDsa65 => Ok(mldsa65_generate_keypair()),
        ProtocolSigningAlgorithm::MlDsa87 => Ok(mldsa87_generate_keypair()),
        ProtocolSigningAlgorithm::Ed25519 => {
            bail!("Ed25519 is not an ML-DSA signing algorithm")
        }
    }
}

pub fn mldsa65_sign_detached(message: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    let encoded: [u8; MLDSA65_SECRET_KEY_BYTES] = secret_key.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-DSA-65 secret key length: expected {MLDSA65_SECRET_KEY_BYTES} bytes, got {}",
            secret_key.len()
        )
    })?;
    let signing_key = ml_dsa_65::PrivateKey::try_from_bytes(encoded)
        .map_err(|error| anyhow!("invalid ML-DSA-65 secret key: {error}"))?;
    let mut randomness = cryptographic_randomness("ML-DSA-65 signing");
    let signature = signing_key
        .try_sign_with_seed(&randomness, message, &[])
        .map_err(|error| anyhow!("ML-DSA-65 signing failed: {error}"));
    randomness.fill(0);
    Ok(signature?.to_vec())
}

pub fn mldsa65_verify_detached(message: &[u8], signature: &[u8], public_key: &[u8]) -> Result<()> {
    let signature: [u8; MLDSA65_SIGNATURE_MAX_BYTES] = signature.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-DSA-65 signature length: expected {MLDSA65_SIGNATURE_MAX_BYTES} bytes, got {}",
            signature.len()
        )
    })?;
    let public_key: [u8; MLDSA65_PUBLIC_KEY_BYTES] = public_key.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-DSA-65 public key length: expected {MLDSA65_PUBLIC_KEY_BYTES} bytes, got {}",
            public_key.len()
        )
    })?;
    let public_key = ml_dsa_65::PublicKey::try_from_bytes(public_key)
        .map_err(|error| anyhow!("invalid ML-DSA-65 public key: {error}"))?;
    if public_key.verify(message, &signature, &[]) {
        Ok(())
    } else {
        bail!("ML-DSA-65 signature verification failed")
    }
}

pub fn mldsa87_sign_detached(message: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    let encoded: [u8; MLDSA87_SECRET_KEY_BYTES] = secret_key.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-DSA-87 secret key length: expected {MLDSA87_SECRET_KEY_BYTES} bytes, got {}",
            secret_key.len()
        )
    })?;
    let signing_key = ml_dsa_87::PrivateKey::try_from_bytes(encoded)
        .map_err(|error| anyhow!("invalid ML-DSA-87 secret key: {error}"))?;
    let mut randomness = cryptographic_randomness("ML-DSA-87 signing");
    let signature = signing_key
        .try_sign_with_seed(&randomness, message, &[])
        .map_err(|error| anyhow!("ML-DSA-87 signing failed: {error}"));
    randomness.fill(0);
    Ok(signature?.to_vec())
}

pub fn mldsa87_verify_detached(message: &[u8], signature: &[u8], public_key: &[u8]) -> Result<()> {
    let signature: [u8; MLDSA87_SIGNATURE_MAX_BYTES] = signature.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-DSA-87 signature length: expected {MLDSA87_SIGNATURE_MAX_BYTES} bytes, got {}",
            signature.len()
        )
    })?;
    let public_key: [u8; MLDSA87_PUBLIC_KEY_BYTES] = public_key.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-DSA-87 public key length: expected {MLDSA87_PUBLIC_KEY_BYTES} bytes, got {}",
            public_key.len()
        )
    })?;
    let public_key = ml_dsa_87::PublicKey::try_from_bytes(public_key)
        .map_err(|error| anyhow!("invalid ML-DSA-87 public key: {error}"))?;
    if public_key.verify(message, &signature, &[]) {
        Ok(())
    } else {
        bail!("ML-DSA-87 signature verification failed")
    }
}

pub fn mldsa_sign_detached(
    algorithm: ProtocolSigningAlgorithm,
    message: &[u8],
    secret_key: &[u8],
) -> Result<Vec<u8>> {
    match algorithm {
        ProtocolSigningAlgorithm::MlDsa65 => mldsa65_sign_detached(message, secret_key),
        ProtocolSigningAlgorithm::MlDsa87 => mldsa87_sign_detached(message, secret_key),
        ProtocolSigningAlgorithm::Ed25519 => {
            bail!("Ed25519 is not supported by the PQC signature provider")
        }
    }
}

pub fn mldsa_verify_detached(
    algorithm: ProtocolSigningAlgorithm,
    message: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> Result<()> {
    match algorithm {
        ProtocolSigningAlgorithm::MlDsa65 => {
            mldsa65_verify_detached(message, signature, public_key)
        }
        ProtocolSigningAlgorithm::MlDsa87 => {
            mldsa87_verify_detached(message, signature, public_key)
        }
        ProtocolSigningAlgorithm::Ed25519 => {
            bail!("Ed25519 is not supported by the PQC signature provider")
        }
    }
}

pub const fn mldsa_secret_key_bytes(algorithm: ProtocolSigningAlgorithm) -> Option<usize> {
    match algorithm {
        ProtocolSigningAlgorithm::MlDsa65 => Some(MLDSA65_SECRET_KEY_BYTES),
        ProtocolSigningAlgorithm::MlDsa87 => Some(MLDSA87_SECRET_KEY_BYTES),
        ProtocolSigningAlgorithm::Ed25519 => None,
    }
}

pub fn mlkem768_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    let mut seed = cryptographic_randomness::<64>("ML-KEM-768 key generation");
    let d = seed[..32]
        .try_into()
        .expect("fixed-size ML-KEM seed prefix");
    let z = seed[32..]
        .try_into()
        .expect("fixed-size ML-KEM seed suffix");
    let (public_key, secret_key) = ml_kem_768::KG::keygen_from_seed(d, z);
    seed.fill(0);
    (
        public_key.into_bytes().to_vec(),
        secret_key.into_bytes().to_vec(),
    )
}

pub fn mlkem768_encapsulate(public_key: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let public_key: [u8; MLKEM768_PUBLIC_KEY_BYTES] = public_key.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-KEM-768 public key length: expected {MLKEM768_PUBLIC_KEY_BYTES} bytes, got {}",
            public_key.len()
        )
    })?;
    let public_key = ml_kem_768::EncapsKey::try_from_bytes(public_key)
        .map_err(|error| anyhow!("invalid ML-KEM-768 public key: {error}"))?;
    let mut randomness = cryptographic_randomness("ML-KEM-768 encapsulation");
    let (shared_secret, ciphertext) = public_key.encaps_from_seed(&randomness);
    randomness.fill(0);
    Ok((
        ciphertext.into_bytes().to_vec(),
        shared_secret.into_bytes().to_vec(),
    ))
}

pub fn mlkem768_decapsulate(ciphertext: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    let ciphertext: [u8; MLKEM768_CIPHERTEXT_BYTES] = ciphertext.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-KEM-768 ciphertext length: expected {MLKEM768_CIPHERTEXT_BYTES} bytes, got {}",
            ciphertext.len()
        )
    })?;
    let secret_key: [u8; MLKEM768_SECRET_KEY_BYTES] = secret_key.try_into().map_err(|_| {
        anyhow!(
            "invalid ML-KEM-768 secret key length: expected {MLKEM768_SECRET_KEY_BYTES} bytes, got {}",
            secret_key.len()
        )
    })?;
    let ciphertext = ml_kem_768::CipherText::try_from_bytes(ciphertext)
        .map_err(|error| anyhow!("invalid ML-KEM-768 ciphertext: {error}"))?;
    let secret_key = ml_kem_768::DecapsKey::try_from_bytes(secret_key)
        .map_err(|error| anyhow!("invalid ML-KEM-768 secret key: {error}"))?;
    Ok(secret_key
        .try_decaps(&ciphertext)
        .map_err(|error| anyhow!("ML-KEM-768 decapsulation failed: {error}"))?
        .into_bytes()
        .to_vec())
}

fn cryptographic_randomness<const N: usize>(operation: &str) -> [u8; N] {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes)
        .unwrap_or_else(|error| panic!("OS CSPRNG failed during {operation}: {error}"));
    bytes
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

// ===========================================================================
// EXPERIMENTAL, DEFAULT-OFF: Q-Periapt ContextBound hybrid KEM (wire_id 0x0011)
// ===========================================================================
//
// Gated behind the `q-periapt` Cargo feature. When the feature is off, none of
// this compiles and the shipping handshake path (X-Wing 0x0001 / ML-KEM-768
// 0x0101) is byte-for-byte unchanged.
//
// This mirrors the verified Q-Periapt reference provider: the `ML-KEM-768 +
// X25519` PQ/T hybrid driven through `q-periapt-kem::HybridKem` with
// `Profile::ContextBound`. Key/ciphertext layouts and the X25519 / ML-KEM
// public-key recovery (offset 1152) match that reference, whose round-trip is
// tested. The keypair / ciphertext / shared-secret shapes follow the X-Wing
// free-function convention: `generate -> (public, secret)`, `encapsulate ->
// (ciphertext, shared_secret)`, `decapsulate -> shared_secret`.
#[cfg(feature = "q-periapt")]
mod qperiapt {
    use anyhow::{Result, anyhow, bail};
    use q_periapt_backends::{
        ML_KEM_768_CT_LEN, ML_KEM_768_KEYGEN_SEED_LEN, ML_KEM_768_PK_LEN, ML_KEM_768_SK_LEN,
        MlKem768, Sha3_256Xof, X25519, X25519_LEN,
    };
    use q_periapt_core::Profile;
    use q_periapt_kem::HybridKem;

    /// private = sk_pq || sk_trad
    pub(super) const QPERIAPT_SECRET_KEY_BYTES: usize = ML_KEM_768_SK_LEN + X25519_LEN;
    /// public  = pk_pq || pk_trad
    pub(super) const QPERIAPT_PUBLIC_KEY_BYTES: usize = ML_KEM_768_PK_LEN + X25519_LEN;
    /// ciphertext = ct_pq || ct_trad
    pub(super) const QPERIAPT_CIPHERTEXT_BYTES: usize = ML_KEM_768_CT_LEN + X25519_LEN;

    /// Canonical suite id bound first-class by the `ContextBound` combiner.
    const SUITE_ID: &[u8] = b"ML-KEM-768+X25519";
    /// Agility/policy version bound first-class by the `ContextBound` combiner.
    const POLICY_VERSION: u32 = 1;
    /// Fixed per-call binding context. `ContextBound` REQUIRES a non-empty
    /// context, identical on both peers and available *before* encapsulation. We
    /// use a fixed protocol label (NOT the transcript hash: that depends on the
    /// ciphertext, which would be circular).
    const KEM_CONTEXT: &[u8] = b"skybridge-qperiapt/v1";

    /// ML-KEM-768 dk layout (FIPS 203 §7.1, k = 3):
    ///   dk = dk_PKE (384*k = 1152) || ek (1184) || H(ek) (32) || z (32)
    /// so the 1184-byte encapsulation key ek begins at offset 1152. This offset
    /// is verified to round-trip in the reference experiment crate.
    const DK_PKE_LEN: usize = 1152;

    fn hybrid() -> Result<HybridKem<'static, MlKem768, X25519, Sha3_256Xof>> {
        static PQ: MlKem768 = MlKem768;
        static TRAD: X25519 = X25519;
        HybridKem::<MlKem768, X25519, Sha3_256Xof>::new(
            &PQ,
            &TRAD,
            Profile::ContextBound,
            SUITE_ID,
            POLICY_VERSION,
        )
        .map_err(|error| anyhow!("Q-Periapt HybridKem::new failed: {error}"))
    }

    fn x25519_pk_from_sk(sk_trad: &[u8]) -> Result<[u8; X25519_LEN]> {
        let scalar: [u8; X25519_LEN] = sk_trad
            .try_into()
            .map_err(|_| anyhow!("invalid Q-Periapt X25519 secret key length"))?;
        let (_sk, pk) = X25519::generate(scalar);
        Ok(pk)
    }

    fn mlkem_pk_from_sk(sk_pq: &[u8]) -> Result<[u8; ML_KEM_768_PK_LEN]> {
        if sk_pq.len() != ML_KEM_768_SK_LEN {
            bail!(
                "invalid Q-Periapt ML-KEM-768 secret key length: expected {}, got {}",
                ML_KEM_768_SK_LEN,
                sk_pq.len()
            );
        }
        let ek = &sk_pq[DK_PKE_LEN..DK_PKE_LEN + ML_KEM_768_PK_LEN];
        ek.try_into()
            .map_err(|_| anyhow!("failed to slice Q-Periapt ML-KEM encapsulation key"))
    }

    /// Generate a Q-Periapt ContextBound keypair, returning `(public, secret)` to
    /// match the X-Wing free-function convention.
    pub(super) fn generate_keypair() -> (Vec<u8>, Vec<u8>) {
        let mut pq_seed = [0u8; ML_KEM_768_KEYGEN_SEED_LEN];
        getrandom::fill(&mut pq_seed).expect("getrandom failed for Q-Periapt ML-KEM seed");
        let (sk_pq, pk_pq) = MlKem768::generate(pq_seed);

        let mut trad_scalar = [0u8; X25519_LEN];
        getrandom::fill(&mut trad_scalar).expect("getrandom failed for Q-Periapt X25519 scalar");
        let (sk_trad, pk_trad) = X25519::generate(trad_scalar);

        let mut public_key = Vec::with_capacity(QPERIAPT_PUBLIC_KEY_BYTES);
        public_key.extend_from_slice(&pk_pq);
        public_key.extend_from_slice(&pk_trad);

        let mut secret_key = Vec::with_capacity(QPERIAPT_SECRET_KEY_BYTES);
        secret_key.extend_from_slice(&sk_pq);
        secret_key.extend_from_slice(&sk_trad);

        (public_key, secret_key)
    }

    /// Encapsulate to a Q-Periapt public key, returning `(ciphertext, shared_secret)`.
    pub(super) fn encapsulate(public_key: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
        if public_key.len() != QPERIAPT_PUBLIC_KEY_BYTES {
            bail!(
                "invalid Q-Periapt public key length: expected {} bytes, got {}",
                QPERIAPT_PUBLIC_KEY_BYTES,
                public_key.len()
            );
        }
        let (pk_pq, pk_trad) = public_key.split_at(ML_KEM_768_PK_LEN);

        let mut rand_pq = [0u8; 32];
        let mut rand_trad = [0u8; 32];
        getrandom::fill(&mut rand_pq)
            .map_err(|error| anyhow!("getrandom failed for Q-Periapt PQ coins: {error}"))?;
        getrandom::fill(&mut rand_trad)
            .map_err(|error| anyhow!("getrandom failed for Q-Periapt trad coins: {error}"))?;

        let mut ct_pq = [0u8; ML_KEM_768_CT_LEN];
        let mut ct_trad = [0u8; X25519_LEN];

        let kem = hybrid()?;
        let secret = kem
            .encapsulate(
                pk_pq,
                pk_trad,
                KEM_CONTEXT,
                &rand_pq,
                &rand_trad,
                &mut ct_pq,
                &mut ct_trad,
            )
            .map_err(|error| anyhow!("Q-Periapt encapsulate failed: {error}"))?;

        let mut ciphertext = Vec::with_capacity(QPERIAPT_CIPHERTEXT_BYTES);
        ciphertext.extend_from_slice(&ct_pq);
        ciphertext.extend_from_slice(&ct_trad);

        Ok((ciphertext, secret.as_bytes().to_vec()))
    }

    /// Decapsulate a Q-Periapt ciphertext with a secret key, returning the shared
    /// secret. The receiver does not carry the peer public key separately, so the
    /// public halves are recomputed from the private halves (matches the X-Wing
    /// path and the verified reference).
    pub(super) fn decapsulate(ciphertext: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
        if ciphertext.len() != QPERIAPT_CIPHERTEXT_BYTES {
            bail!(
                "invalid Q-Periapt ciphertext length: expected {} bytes, got {}",
                QPERIAPT_CIPHERTEXT_BYTES,
                ciphertext.len()
            );
        }
        if secret_key.len() != QPERIAPT_SECRET_KEY_BYTES {
            bail!(
                "invalid Q-Periapt secret key length: expected {} bytes, got {}",
                QPERIAPT_SECRET_KEY_BYTES,
                secret_key.len()
            );
        }
        let (sk_pq, sk_trad) = secret_key.split_at(ML_KEM_768_SK_LEN);
        let (ct_pq, ct_trad) = ciphertext.split_at(ML_KEM_768_CT_LEN);

        let pk_pq = mlkem_pk_from_sk(sk_pq)?;
        let pk_trad = x25519_pk_from_sk(sk_trad)?;

        let kem = hybrid()?;
        let secret = kem
            .decapsulate(
                sk_pq,
                ct_pq,
                &pk_pq,
                sk_trad,
                ct_trad,
                &pk_trad,
                KEM_CONTEXT,
            )
            .map_err(|error| anyhow!("Q-Periapt decapsulate failed: {error}"))?;

        Ok(secret.as_bytes().to_vec())
    }
}

/// EXPERIMENTAL, DEFAULT-OFF (`q-periapt` feature): generate a Q-Periapt
/// ContextBound hybrid KEM keypair, returning `(public, secret)` to match the
/// X-Wing free-function convention used by [`RustPqcIdentityMaterial`].
#[cfg(feature = "q-periapt")]
pub fn qperiapt_contextbound_generate_keypair() -> (Vec<u8>, Vec<u8>) {
    qperiapt::generate_keypair()
}

/// EXPERIMENTAL, DEFAULT-OFF (`q-periapt` feature): encapsulate to a Q-Periapt
/// public key, returning `(ciphertext, shared_secret)` (same `Result` shape as
/// [`mlkem768_encapsulate`] / [`xwing_encapsulate`]).
#[cfg(feature = "q-periapt")]
pub fn qperiapt_contextbound_encapsulate(public_key: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    qperiapt::encapsulate(public_key)
}

/// EXPERIMENTAL, DEFAULT-OFF (`q-periapt` feature): decapsulate a Q-Periapt
/// ciphertext with a secret key, returning the shared secret.
#[cfg(feature = "q-periapt")]
pub fn qperiapt_contextbound_decapsulate(ciphertext: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    qperiapt::decapsulate(ciphertext, secret_key)
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
    fn mldsa87_round_trip_uses_exact_fips204_sizes() -> Result<()> {
        let (public_key, secret_key) = mldsa87_generate_keypair();
        assert_eq!(public_key.len(), 2_592);
        assert_eq!(secret_key.len(), 4_896);
        let message = b"rust-native-pqc-mldsa87";
        let signature = mldsa87_sign_detached(message, &secret_key)?;
        assert_eq!(signature.len(), 4_627);
        mldsa87_verify_detached(message, &signature, &public_key)?;
        assert!(mldsa65_verify_detached(message, &signature, &public_key).is_err());
        Ok(())
    }

    #[test]
    fn rust_pqc_identity_can_bind_mldsa87_without_algorithm_fallback() -> Result<()> {
        let identity =
            RustPqcIdentityMaterial::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa87)?;
        assert_eq!(
            identity.signing_algorithm,
            ProtocolSigningAlgorithm::MlDsa87
        );
        assert_eq!(identity.signing_public_key.len(), MLDSA87_PUBLIC_KEY_BYTES);
        assert_eq!(identity.signing_secret_key.len(), MLDSA87_SECRET_KEY_BYTES);
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

    #[cfg(feature = "q-periapt")]
    #[test]
    fn qperiapt_contextbound_round_trip_encapsulation() -> Result<()> {
        let (public_key, secret_key) = qperiapt_contextbound_generate_keypair();
        let (ciphertext, sender_secret) = qperiapt_contextbound_encapsulate(&public_key)?;
        let receiver_secret = qperiapt_contextbound_decapsulate(&ciphertext, &secret_key)?;
        assert_eq!(sender_secret, receiver_secret);
        assert_eq!(sender_secret.len(), 32);
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
