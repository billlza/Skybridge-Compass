//! Utility functions for the Sinan backend

use rand::{distributions::Alphanumeric, Rng};
use regex::Regex;

/// Generate a 6-digit verification code
pub fn generate_verification_code() -> String {
    let mut rng = rand::thread_rng();
    rng.gen_range(100000..999999).to_string()
}

/// Generate a hard-to-guess public Nebula ID.
pub fn generate_nebula_id() -> String {
    let suffix: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .map(char::from)
        .filter(|c| c.is_ascii_alphanumeric())
        .take(10)
        .collect::<String>()
        .to_uppercase();

    format!("NB{}", suffix)
}

/// Validate email format
pub fn is_valid_email(email: &str) -> bool {
    let email_regex = Regex::new(r"^[^\s@]+@[^\s@]+\.[^\s@]+$").unwrap();
    email_regex.is_match(email)
}

/// Validate Chinese phone number format
pub fn is_valid_phone(phone: &str) -> bool {
    let phone_regex = Regex::new(r"^1[3-9]\d{9}$").unwrap();
    phone_regex.is_match(phone)
}

/// Validate 6-digit verification code format
pub fn is_valid_code(code: &str) -> bool {
    let code_regex = Regex::new(r"^\d{6}$").unwrap();
    code_regex.is_match(code)
}

/// Validate custom user ID format
pub fn is_valid_user_id(user_id: &str) -> bool {
    let id_regex = Regex::new(r"^[a-zA-Z0-9_\u4e00-\u9fff-]+$").unwrap();
    id_regex.is_match(user_id) && user_id.len() >= 3 && user_id.len() <= 30
}

/// Mask contact value for privacy
pub fn mask_contact(contact_type: &str, value: &str) -> String {
    match contact_type {
        "email" => mask_email(value),
        "phone" => mask_phone(value),
        _ => value.to_string(),
    }
}

/// Mask email address (e.g., "ab***@example.com")
pub fn mask_email(email: &str) -> String {
    if let Some(at_pos) = email.find('@') {
        let (local, domain) = email.split_at(at_pos);
        if local.len() >= 2 {
            format!("{}***{}", &local[..2], domain)
        } else {
            format!("{}***{}", local, domain)
        }
    } else {
        email.to_string()
    }
}

/// Mask phone number (e.g., "138****5678")
pub fn mask_phone(phone: &str) -> String {
    if phone.len() >= 11 {
        format!("{}****{}", &phone[..3], &phone[7..])
    } else {
        phone.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_email() {
        assert!(is_valid_email("test@example.com"));
        assert!(is_valid_email("user.name@domain.co.uk"));
        assert!(!is_valid_email("invalid"));
        assert!(!is_valid_email("@nodomain.com"));
    }

    #[test]
    fn test_valid_phone() {
        assert!(is_valid_phone("13812345678"));
        assert!(is_valid_phone("19912345678"));
        assert!(!is_valid_phone("12345678901")); // invalid prefix
        assert!(!is_valid_phone("138123456")); // too short
    }

    #[test]
    fn test_mask_email() {
        assert_eq!(mask_email("test@example.com"), "te***@example.com");
        assert_eq!(mask_email("a@b.com"), "a***@b.com");
    }

    #[test]
    fn test_mask_phone() {
        assert_eq!(mask_phone("13812345678"), "138****5678");
    }

    #[test]
    fn test_verification_code() {
        let code = generate_verification_code();
        assert!(code.len() == 6);
        assert!(code.chars().all(|c| c.is_ascii_digit()));
    }
}



