use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Serialize, Clone)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub device_type: String, // mobile, tablet, laptop, desktop
    pub ip: String,
    pub status: String, // online, offline
    pub last_seen: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct SystemStats {
    pub cpu_usage: u8,
    pub memory_usage: u8,
    pub storage_usage: u8,
    pub network_quality: u8,
    pub temperature: u8,
    pub upload_speed: u32,   // Mbps
    pub download_speed: u32, // Mbps
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub enum LoginMethod {
    Apple,
    Nebula,
    Phone,
    Email,
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub method: LoginMethod,
    pub identifier: String,       // phone, email, username
    pub password: Option<String>, // for Nebula/Email
    pub code: Option<String>,     // for Phone/MFA
    pub device_fingerprint: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    #[allow(dead_code)]
    pub method: LoginMethod,
    pub identifier: String,
    #[allow(dead_code)]
    pub password: Option<String>,
    pub code: String, // Verification code is required
    #[allow(dead_code)]
    pub device_fingerprint: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SendCodeRequest {
    pub identifier: String,
    #[allow(dead_code)]
    pub method: LoginMethod, // Phone or Email
    pub device_fingerprint: String,
}

#[derive(Debug, Deserialize)]
pub struct VerifyCodeRequest {
    pub identifier: String,
    pub code: String,
    #[allow(dead_code)]
    pub device_fingerprint: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct User {
    pub id: Uuid,
    pub username: String,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>, // Added avatar_url
    pub created_at: DateTime<Utc>,
}

/// Verification code with expiration and attempt tracking
#[derive(Debug, Clone)]
pub struct VerificationCode {
    pub code: String,
    pub expires_at: DateTime<Utc>,
    pub attempts: u32,
    pub max_attempts: u32,
    pub created_at: DateTime<Utc>,
}

impl VerificationCode {
    /// Create a new verification code with 5-minute expiration and max 5 attempts
    pub fn new(code: String) -> Self {
        let now = Utc::now();
        Self {
            code,
            expires_at: now + chrono::Duration::minutes(5),
            attempts: 0,
            max_attempts: 5,
            created_at: now,
        }
    }

    /// Check if the code has expired
    pub fn is_expired(&self) -> bool {
        Utc::now() > self.expires_at
    }

    /// Check if max attempts have been exceeded
    pub fn is_locked(&self) -> bool {
        self.attempts >= self.max_attempts
    }

    /// Increment attempt counter and return whether verification can proceed
    pub fn record_attempt(&mut self) -> bool {
        self.attempts += 1;
        !self.is_locked()
    }

    /// Verify the code, returning result and updating attempt count
    pub fn verify(&mut self, input_code: &str) -> VerificationResult {
        if self.is_expired() {
            return VerificationResult::Expired;
        }
        if self.is_locked() {
            return VerificationResult::Locked;
        }

        self.attempts += 1;

        if self.code == input_code {
            VerificationResult::Valid
        } else if self.is_locked() {
            VerificationResult::Locked
        } else {
            VerificationResult::Invalid {
                attempts_remaining: self.max_attempts - self.attempts,
            }
        }
    }

    /// Get remaining time until expiration in seconds
    pub fn remaining_seconds(&self) -> i64 {
        let remaining = self.expires_at.signed_duration_since(Utc::now());
        remaining.num_seconds().max(0)
    }
}

/// Result of verification code check
#[derive(Debug, Clone, PartialEq)]
pub enum VerificationResult {
    Valid,
    Invalid { attempts_remaining: u32 },
    Expired,
    Locked,
}

/// Rate limit entry using sliding window algorithm
/// Stores timestamps of each request within the window
#[derive(Debug, Clone)]
pub struct RateLimit {
    /// Timestamps of requests within the current window
    pub timestamps: Vec<DateTime<Utc>>,
}

impl RateLimit {
    pub fn new() -> Self {
        Self {
            timestamps: Vec::new(),
        }
    }
}

impl Default for RateLimit {
    fn default() -> Self {
        Self::new()
    }
}

/// Rate limit type for distinguishing phone vs device limits
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RateLimitType {
    Phone,
    Device,
}

/// Result of rate limit check
#[derive(Debug, Clone)]
pub struct RateLimitResult {
    pub allowed: bool,
    pub current_count: u32,
    pub limit: u32,
    pub reset_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub token: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requires_email_verification: Option<bool>,
    pub user: User,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub error: String,
    pub message: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct UploadSessionStart {
    pub file_name: String,
    pub total_size: u64,
    pub sha256: Option<String>,
}

/// Upload session expiration time in minutes
pub const UPLOAD_SESSION_EXPIRATION_MINUTES: i64 = 30;

#[derive(Debug, Serialize, Clone)]
pub struct UploadSession {
    pub id: String,
    pub file_name: String,
    pub total_size: u64,
    pub sha256: Option<String>,
    pub out_path: String,
    pub created_at: DateTime<Utc>,
}

impl UploadSession {
    /// Check if the upload session has expired (older than 30 minutes)
    pub fn is_expired(&self) -> bool {
        Utc::now() - self.created_at > chrono::Duration::minutes(UPLOAD_SESSION_EXPIRATION_MINUTES)
    }

    /// Get remaining time until expiration in seconds
    pub fn remaining_seconds(&self) -> i64 {
        let expires_at =
            self.created_at + chrono::Duration::minutes(UPLOAD_SESSION_EXPIRATION_MINUTES);
        let remaining = expires_at.signed_duration_since(Utc::now());
        remaining.num_seconds().max(0)
    }
}

#[derive(Debug, Serialize)]
pub struct UploadSessionStatus {
    pub id: String,
    pub uploaded_bytes: u64,
    pub total_size: u64,
    pub received_offsets: Vec<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use proptest::prelude::*;

    /// Strategy for generating 6-digit verification codes
    fn code_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex("[0-9]{6}").unwrap()
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: skybridge-compass-web, Property 2: Verification Code Expiration**
        /// *For any* verification code, it SHALL be valid for authentication within 5 minutes
        /// of generation and SHALL be rejected after expiration.
        /// **Validates: Requirements 1.4**
        #[test]
        fn prop_verification_code_valid_within_5_minutes(code in code_strategy()) {
            let vc = VerificationCode::new(code.clone());

            // Code should not be expired immediately after creation
            prop_assert!(!vc.is_expired(), "Code should not be expired immediately");

            // Verify the code is valid
            let mut vc_clone = vc.clone();
            let result = vc_clone.verify(&code);
            prop_assert_eq!(result, VerificationResult::Valid,
                "Valid code should be accepted within expiration window");
        }

        /// **Feature: skybridge-compass-web, Property 2: Verification Code Expiration**
        /// Code should be rejected after expiration
        /// **Validates: Requirements 1.4**
        #[test]
        fn prop_verification_code_rejected_after_expiration(code in code_strategy()) {
            let mut vc = VerificationCode::new(code.clone());

            // Manually set expiration to the past
            vc.expires_at = Utc::now() - Duration::seconds(1);

            // Code should be expired
            prop_assert!(vc.is_expired(), "Code should be expired after expiration time");

            // Verification should fail with Expired result
            let result = vc.verify(&code);
            prop_assert_eq!(result, VerificationResult::Expired,
                "Expired code should return Expired result");
        }

        /// **Feature: skybridge-compass-web, Property 2: Verification Code Expiration**
        /// Wrong code should be rejected with attempt tracking
        /// **Validates: Requirements 1.4**
        #[test]
        fn prop_wrong_code_rejected_with_attempts(
            correct_code in code_strategy(),
            wrong_code in code_strategy()
        ) {
            prop_assume!(correct_code != wrong_code);

            let mut vc = VerificationCode::new(correct_code);

            // Wrong code should be rejected
            let result = vc.verify(&wrong_code);
            match result {
                VerificationResult::Invalid { attempts_remaining } => {
                    prop_assert!(attempts_remaining < 5,
                        "Attempts remaining should decrease after failed attempt");
                }
                _ => prop_assert!(false, "Wrong code should return Invalid result"),
            }
        }

        /// **Feature: skybridge-compass-web, Property 2: Verification Code Expiration**
        /// Code should be locked after max attempts
        /// **Validates: Requirements 1.4**
        #[test]
        fn prop_code_locked_after_max_attempts(
            correct_code in code_strategy(),
            wrong_code in code_strategy()
        ) {
            prop_assume!(correct_code != wrong_code);

            let mut vc = VerificationCode::new(correct_code.clone());

            // Make max_attempts wrong attempts
            for i in 0..vc.max_attempts {
                let result = vc.verify(&wrong_code);
                if i < vc.max_attempts - 1 {
                    match result {
                        VerificationResult::Invalid { .. } => {}
                        _ => prop_assert!(false, "Should return Invalid before max attempts"),
                    }
                } else {
                    prop_assert_eq!(result, VerificationResult::Locked,
                        "Should return Locked after max attempts");
                }
            }

            // Even correct code should be rejected when locked
            let result = vc.verify(&correct_code);
            prop_assert_eq!(result, VerificationResult::Locked,
                "Locked code should reject even correct input");
        }

        /// **Feature: skybridge-compass-web, Property 2: Verification Code Expiration**
        /// Expiration time should be exactly 5 minutes from creation
        /// **Validates: Requirements 1.4**
        #[test]
        fn prop_expiration_time_is_5_minutes(code in code_strategy()) {
            let before = Utc::now();
            let vc = VerificationCode::new(code);
            let after = Utc::now();

            // Expiration should be approximately 5 minutes (300 seconds) from creation
            let expected_min = before + Duration::minutes(5);
            let expected_max = after + Duration::minutes(5);

            prop_assert!(vc.expires_at >= expected_min && vc.expires_at <= expected_max,
                "Expiration should be 5 minutes from creation");
        }
    }

    // Unit tests
    #[test]
    fn test_verification_code_new() {
        let vc = VerificationCode::new("123456".to_string());
        assert_eq!(vc.code, "123456");
        assert_eq!(vc.attempts, 0);
        assert_eq!(vc.max_attempts, 5);
        assert!(!vc.is_expired());
        assert!(!vc.is_locked());
    }

    #[test]
    fn test_verification_code_verify_correct() {
        let mut vc = VerificationCode::new("123456".to_string());
        let result = vc.verify("123456");
        assert_eq!(result, VerificationResult::Valid);
    }

    #[test]
    fn test_verification_code_verify_wrong() {
        let mut vc = VerificationCode::new("123456".to_string());
        let result = vc.verify("654321");
        match result {
            VerificationResult::Invalid { attempts_remaining } => {
                assert_eq!(attempts_remaining, 4);
            }
            _ => panic!("Expected Invalid result"),
        }
    }

    #[test]
    fn test_verification_code_expired() {
        let mut vc = VerificationCode::new("123456".to_string());
        vc.expires_at = Utc::now() - Duration::seconds(1);

        assert!(vc.is_expired());
        let result = vc.verify("123456");
        assert_eq!(result, VerificationResult::Expired);
    }

    #[test]
    fn test_verification_code_locked() {
        let mut vc = VerificationCode::new("123456".to_string());

        // Make 5 wrong attempts
        for _ in 0..5 {
            vc.verify("000000");
        }

        assert!(vc.is_locked());
        let result = vc.verify("123456");
        assert_eq!(result, VerificationResult::Locked);
    }

    // ============================================================
    // Upload Session Tests
    // ============================================================

    /// **Feature: skybridge-compass-web, Property 7: Upload Session Expiration**
    /// *For any* upload session older than 30 minutes, chunk upload requests SHALL be rejected.
    /// **Validates: Requirements 3.7**
    #[test]
    fn test_upload_session_not_expired_initially() {
        let session = UploadSession {
            id: "test-session".to_string(),
            file_name: "test.txt".to_string(),
            total_size: 1000,
            sha256: None,
            out_path: "/tmp/test.txt".to_string(),
            created_at: Utc::now(),
        };

        assert!(
            !session.is_expired(),
            "Session should not be expired immediately after creation"
        );
        assert!(
            session.remaining_seconds() > 0,
            "Should have remaining time"
        );
    }

    /// **Feature: skybridge-compass-web, Property 7: Upload Session Expiration**
    /// **Validates: Requirements 3.7**
    #[test]
    fn test_upload_session_expired_after_30_minutes() {
        let session = UploadSession {
            id: "test-session".to_string(),
            file_name: "test.txt".to_string(),
            total_size: 1000,
            sha256: None,
            out_path: "/tmp/test.txt".to_string(),
            created_at: Utc::now() - Duration::minutes(31),
        };

        assert!(
            session.is_expired(),
            "Session should be expired after 31 minutes"
        );
        assert_eq!(
            session.remaining_seconds(),
            0,
            "Should have no remaining time"
        );
    }

    /// **Feature: skybridge-compass-web, Property 7: Upload Session Expiration**
    /// Session at exactly 30 minutes should still be valid
    /// **Validates: Requirements 3.7**
    #[test]
    fn test_upload_session_at_boundary() {
        let session = UploadSession {
            id: "test-session".to_string(),
            file_name: "test.txt".to_string(),
            total_size: 1000,
            sha256: None,
            out_path: "/tmp/test.txt".to_string(),
            created_at: Utc::now() - Duration::minutes(30) + Duration::seconds(1),
        };

        assert!(
            !session.is_expired(),
            "Session should not be expired at 29:59"
        );
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: skybridge-compass-web, Property 7: Upload Session Expiration**
        /// Sessions created within 30 minutes should not be expired
        /// **Validates: Requirements 3.7**
        #[test]
        fn prop_session_valid_within_30_minutes(minutes_ago in 0i64..30) {
            let session = UploadSession {
                id: "test-session".to_string(),
                file_name: "test.txt".to_string(),
                total_size: 1000,
                sha256: None,
                out_path: "/tmp/test.txt".to_string(),
                created_at: Utc::now() - Duration::minutes(minutes_ago),
            };

            prop_assert!(!session.is_expired(),
                "Session created {} minutes ago should not be expired", minutes_ago);
        }

        /// **Feature: skybridge-compass-web, Property 7: Upload Session Expiration**
        /// Sessions created more than 30 minutes ago should be expired
        /// **Validates: Requirements 3.7**
        #[test]
        fn prop_session_expired_after_30_minutes(minutes_ago in 31i64..1000) {
            let session = UploadSession {
                id: "test-session".to_string(),
                file_name: "test.txt".to_string(),
                total_size: 1000,
                sha256: None,
                out_path: "/tmp/test.txt".to_string(),
                created_at: Utc::now() - Duration::minutes(minutes_ago),
            };

            prop_assert!(session.is_expired(),
                "Session created {} minutes ago should be expired", minutes_ago);
        }
    }
}
