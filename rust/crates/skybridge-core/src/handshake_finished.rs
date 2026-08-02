use anyhow::{Result, anyhow};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;

pub(crate) const FINISHED_I2R_INFO_PREFIX: &[u8] = b"SkyBridge-FINISHED|I2R|";
pub(crate) const FINISHED_R2I_INFO_PREFIX: &[u8] = b"SkyBridge-FINISHED|R2I|";

type HmacSha256 = Hmac<Sha256>;

/// Derive and authenticate a Finished transcript using the Apple wire contract.
///
/// The transcript hash is intentionally present in both the HKDF info and the
/// HMAC input. Omitting it from either position produces a different protocol.
pub(crate) fn derive_finished_mac(
    base_key: &[u8],
    info_prefix: &[u8],
    transcript_hash: &[u8],
) -> Result<[u8; 32]> {
    let hmac = initialized_finished_hmac(base_key, info_prefix, transcript_hash)?;
    let tag = hmac.finalize().into_bytes();
    let mut mac = [0u8; 32];
    mac.copy_from_slice(&tag);
    Ok(mac)
}

/// Verify a Finished MAC without a timing-dependent byte comparison.
pub(crate) fn verify_finished_mac(
    base_key: &[u8],
    info_prefix: &[u8],
    transcript_hash: &[u8],
    received_mac: &[u8],
) -> Result<bool> {
    let hmac = initialized_finished_hmac(base_key, info_prefix, transcript_hash)?;
    Ok(hmac.verify_slice(received_mac).is_ok())
}

fn initialized_finished_hmac(
    base_key: &[u8],
    info_prefix: &[u8],
    transcript_hash: &[u8],
) -> Result<HmacSha256> {
    let hkdf = Hkdf::<Sha256>::new(None, base_key);
    let mut mac_key = [0u8; 32];
    let mut info = Vec::with_capacity(info_prefix.len() + transcript_hash.len());
    info.extend_from_slice(info_prefix);
    info.extend_from_slice(transcript_hash);
    hkdf.expand(&info, &mut mac_key)
        .map_err(|_| anyhow!("failed to derive Finished MAC key"))?;

    let mut hmac = <HmacSha256 as Mac>::new_from_slice(&mac_key)
        .map_err(|error| anyhow!("failed to construct Finished HMAC: {error}"))?;
    hmac.update(transcript_hash);
    Ok(hmac)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finished_mac_matches_swift_fixed_vectors_for_both_directions() -> Result<()> {
        let base_key = [0x11; 32];
        let transcript_hash = [0x33; 32];

        let responder_to_initiator =
            derive_finished_mac(&base_key, FINISHED_R2I_INFO_PREFIX, &transcript_hash)?;
        assert_eq!(
            responder_to_initiator,
            [
                0xda, 0x64, 0xc0, 0x72, 0x2e, 0x6e, 0x87, 0xfc, 0x0c, 0x86, 0xa6, 0x30, 0xcf, 0x2b,
                0xfe, 0xa5, 0xaf, 0xdb, 0xeb, 0x41, 0xeb, 0x39, 0xef, 0x25, 0xe4, 0xe5, 0x6d, 0x63,
                0xe1, 0xa4, 0x20, 0x70,
            ]
        );

        let initiator_to_responder =
            derive_finished_mac(&base_key, FINISHED_I2R_INFO_PREFIX, &transcript_hash)?;
        assert_eq!(
            initiator_to_responder,
            [
                0xdd, 0x39, 0x99, 0xf5, 0x5e, 0xe6, 0xc7, 0x8c, 0x3c, 0x22, 0x08, 0x6b, 0xe5, 0x51,
                0x55, 0xd7, 0xc1, 0x10, 0x6a, 0xc0, 0x77, 0xb0, 0x49, 0x84, 0xa7, 0x60, 0x34, 0xdd,
                0x42, 0x92, 0xff, 0xa6,
            ]
        );
        assert_ne!(responder_to_initiator, initiator_to_responder);
        Ok(())
    }

    #[test]
    fn finished_mac_binds_the_transcript_in_hkdf_info_and_hmac_input() -> Result<()> {
        let base_key = [0x5a; 32];
        let transcript_hash = [0xa5; 32];
        let expected = derive_finished_mac(&base_key, FINISHED_R2I_INFO_PREFIX, &transcript_hash)?;
        assert!(verify_finished_mac(
            &base_key,
            FINISHED_R2I_INFO_PREFIX,
            &transcript_hash,
            &expected,
        )?);

        let mut tampered_transcript_hash = transcript_hash;
        tampered_transcript_hash[0] ^= 0x01;
        let tampered = derive_finished_mac(
            &base_key,
            FINISHED_R2I_INFO_PREFIX,
            &tampered_transcript_hash,
        )?;

        assert_ne!(expected, tampered);
        assert!(!verify_finished_mac(
            &base_key,
            FINISHED_R2I_INFO_PREFIX,
            &tampered_transcript_hash,
            &expected,
        )?);
        Ok(())
    }
}
