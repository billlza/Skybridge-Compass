use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, KeyInit},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, Utc};
use rand::{RngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::{error::AppError, models::SupabaseUser};

pub const CLI_CLIENT_ID: &str = "skybridge_compass_cli";
pub const PENDING_SESSION_TTL_MINUTES: i64 = 10;
pub const APPROVED_CODE_TTL_MINUTES: i64 = 2;

pub fn validate_cli_login_request(
    client_id: &str,
    redirect_uri: &str,
    code_challenge: &str,
    state: &str,
) -> Result<Url, AppError> {
    if client_id.trim() != CLI_CLIENT_ID {
        return Err(AppError::bad_request(
            "INVALID_CLIENT_ID",
            "unsupported cli client id",
        ));
    }
    if code_challenge.trim().is_empty() {
        return Err(AppError::bad_request(
            "INVALID_CODE_CHALLENGE",
            "code_challenge is required",
        ));
    }
    if state.trim().is_empty() {
        return Err(AppError::bad_request("INVALID_STATE", "state is required"));
    }
    validate_loopback_redirect_uri(redirect_uri)
}

pub fn validate_loopback_redirect_uri(redirect_uri: &str) -> Result<Url, AppError> {
    let parsed = Url::parse(redirect_uri).map_err(|_| {
        AppError::bad_request("INVALID_REDIRECT_URI", "redirect_uri must be a valid URL")
    })?;

    if parsed.scheme() != "http" {
        return Err(AppError::bad_request(
            "INVALID_REDIRECT_URI",
            "redirect_uri must use http loopback",
        ));
    }

    let Some(host) = parsed.host_str() else {
        return Err(AppError::bad_request(
            "INVALID_REDIRECT_URI",
            "redirect_uri host is required",
        ));
    };

    if host != "127.0.0.1" && !host.eq_ignore_ascii_case("localhost") {
        return Err(AppError::bad_request(
            "INVALID_REDIRECT_URI",
            "redirect_uri must target localhost or 127.0.0.1",
        ));
    }

    if parsed.port().is_none() {
        return Err(AppError::bad_request(
            "INVALID_REDIRECT_URI",
            "redirect_uri must include an explicit port",
        ));
    }

    if parsed.fragment().is_some() || !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(AppError::bad_request(
            "INVALID_REDIRECT_URI",
            "redirect_uri may not include credentials or fragments",
        ));
    }

    Ok(parsed)
}

pub fn pending_session_expiry() -> DateTime<Utc> {
    Utc::now() + Duration::minutes(PENDING_SESSION_TTL_MINUTES)
}

pub fn approved_code_expiry() -> DateTime<Utc> {
    Utc::now() + Duration::minutes(APPROVED_CODE_TTL_MINUTES)
}

pub fn generate_auth_code() -> String {
    let mut random = [0_u8; 32];
    OsRng.fill_bytes(&mut random);
    URL_SAFE_NO_PAD.encode(random)
}

pub fn hash_secret(secret: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(secret.as_bytes());
    URL_SAFE_NO_PAD.encode(digest.finalize())
}

pub fn code_challenge_from_verifier(code_verifier: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(code_verifier.as_bytes());
    URL_SAFE_NO_PAD.encode(digest.finalize())
}

pub fn build_browser_url(public_site_url: &str, session_id: Uuid) -> Result<String, AppError> {
    let mut url = Url::parse(public_site_url.trim_end_matches('/')).map_err(|_| {
        AppError::internal("PUBLIC_SITE_URL is not a valid absolute URL")
    })?;
    url.set_path("/auth/cli");
    url.set_query(Some(&format!("session={session_id}")));
    Ok(url.to_string())
}

pub fn display_name_from_supabase_user(user: &SupabaseUser) -> String {
    for key in ["display_name", "full_name", "name", "preferred_username"] {
        if let Some(value) = user.user_metadata.get(key).and_then(|item| item.as_str()) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
    }

    user.email
        .clone()
        .or_else(|| user.phone.clone())
        .unwrap_or_else(|| "SkyBridge User".to_string())
}

pub fn encrypt_secret(key_material: &str, plaintext: &str) -> Result<String, AppError> {
    let key_bytes = decode_encryption_key(key_material)?;
    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|_| AppError::internal("invalid CLI_LOGIN_ENCRYPTION_KEY"))?;

    let mut nonce_bytes = [0_u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|_| AppError::internal("failed to encrypt cli login token envelope"))?;

    let mut envelope = nonce_bytes.to_vec();
    envelope.extend_from_slice(&ciphertext);
    Ok(URL_SAFE_NO_PAD.encode(envelope))
}

pub fn decrypt_secret(key_material: &str, encoded: &str) -> Result<String, AppError> {
    let key_bytes = decode_encryption_key(key_material)?;
    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|_| AppError::internal("invalid CLI_LOGIN_ENCRYPTION_KEY"))?;

    let envelope = URL_SAFE_NO_PAD
        .decode(encoded.as_bytes())
        .map_err(|_| AppError::internal("stored cli login token envelope is invalid"))?;

    if envelope.len() <= 12 {
        return Err(AppError::internal(
            "stored cli login token envelope is truncated",
        ));
    }

    let (nonce_bytes, ciphertext) = envelope.split_at(12);
    let nonce = Nonce::from_slice(nonce_bytes);
    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| AppError::internal("failed to decrypt cli login token envelope"))?;

    String::from_utf8(plaintext)
        .map_err(|_| AppError::internal("decrypted cli login token envelope is not utf-8"))
}

fn decode_encryption_key(key_material: &str) -> Result<[u8; 32], AppError> {
    let trimmed = key_material.trim();
    if trimmed.is_empty() {
        return Err(AppError::internal(
            "CLI_LOGIN_ENCRYPTION_KEY is not configured",
        ));
    }

    let decoded = if trimmed.len() == 64 && trimmed.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        decode_hex_32(trimmed)?
    } else {
        let decoded = URL_SAFE_NO_PAD
            .decode(trimmed.as_bytes())
            .map_err(|_| AppError::internal("CLI_LOGIN_ENCRYPTION_KEY must be base64url or hex"))?;

        if decoded.len() != 32 {
            return Err(AppError::internal(
                "CLI_LOGIN_ENCRYPTION_KEY must decode to exactly 32 bytes",
            ));
        }

        let mut array = [0_u8; 32];
        array.copy_from_slice(&decoded);
        array
    };

    Ok(decoded)
}

fn decode_hex_32(input: &str) -> Result<[u8; 32], AppError> {
    let mut bytes = [0_u8; 32];
    for (index, chunk) in input.as_bytes().chunks_exact(2).enumerate() {
        bytes[index] = (hex_nibble(chunk[0])? << 4) | hex_nibble(chunk[1])?;
    }
    Ok(bytes)
}

fn hex_nibble(byte: u8) -> Result<u8, AppError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(AppError::internal(
            "CLI_LOGIN_ENCRYPTION_KEY contains invalid hex",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_loopback_redirect_uri() {
        assert!(validate_loopback_redirect_uri("http://127.0.0.1:8080/callback").is_ok());
        assert!(validate_loopback_redirect_uri("http://localhost:8080/callback").is_ok());
        assert!(validate_loopback_redirect_uri("https://127.0.0.1:8080/callback").is_err());
        assert!(validate_loopback_redirect_uri("http://example.com:8080/callback").is_err());
    }

    #[test]
    fn encrypt_roundtrip_works() {
        let key = URL_SAFE_NO_PAD.encode([7_u8; 32]);
        let encrypted = encrypt_secret(&key, "refresh-token").unwrap();
        let decrypted = decrypt_secret(&key, &encrypted).unwrap();
        assert_eq!(decrypted, "refresh-token");
    }
}
