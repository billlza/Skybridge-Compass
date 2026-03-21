use crate::models::UploadSession;
use crate::models::{RateLimit, RateLimitResult, User, VerificationCode};
use crate::oauth::{
    default_public_clients, revoked_refresh_token_retention, AuthorizationCodeRecord,
    PendingMfaSessionRecord, PublicClientRegistration,
};
use crate::supabase::SupabaseClient;
use chrono::{Duration, Utc};
use dashmap::DashMap;
use dashmap::DashMap as DM;
use reqwest::{redirect::Policy, Client, Url};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::sync::broadcast::Sender as BSender;
use tracing::warn;

/// Phone rate limit: max 10 codes per day
const PHONE_LIMIT: u32 = 10;
/// Device rate limit: max 20 codes per day
const DEVICE_LIMIT: u32 = 20;
/// Window duration in seconds (24 hours)
const WINDOW_SECONDS: i64 = 86400;

#[derive(Clone)]
pub struct AppState {
    pub users: Arc<DashMap<String, User>>,
    pub credentials: Arc<DashMap<String, String>>,
    pub codes: Arc<DashMap<String, VerificationCode>>,
    /// Phone number rate limits: phone -> RateLimit
    pub phone_rate_limits: Arc<DashMap<String, RateLimit>>,
    /// Device fingerprint rate limits: device_fp -> RateLimit
    pub device_rate_limits: Arc<DashMap<String, RateLimit>>,
    pub supabase: Arc<SupabaseClient>,
    pub upload_sessions: Arc<DashMap<String, UploadSession>>,
    pub upload_received: Arc<DashMap<String, DM<u64, u64>>>,
    pub ws_tx: Arc<broadcast::Sender<String>>,
    pub ws_topics: Arc<DashMap<String, BSender<String>>>,
    pub auth_tokens: Arc<DashMap<String, String>>,
    pub oauth_authorization_codes: Arc<DashMap<String, AuthorizationCodeRecord>>,
    pub oauth_pending_mfa_sessions: Arc<DashMap<String, PendingMfaSessionRecord>>,
    pub oauth_revoked_refresh_tokens: Arc<DashMap<String, chrono::DateTime<Utc>>>,
    pub oauth_public_clients: Arc<HashMap<String, PublicClientRegistration>>,
    pub oauth_dev_headless_authorize_enabled: bool,
    pub oauth_browser_mfa_code: Option<String>,
    pub nebula_issuer: String,
    pub auth_proxy_upstream: String,
    pub auth_proxy_public_host: String,
    pub auth_proxy_client: Client,
}

impl AppState {
    pub fn new() -> Self {
        let supabase_url = std::env::var("SUPABASE_URL")
            .unwrap_or_else(|_| "https://hloqytmhjludmuhwyyzb.supabase.co".to_string());
        let supabase_key = std::env::var("SUPABASE_ANON_KEY")
            .unwrap_or_else(|_| "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0".to_string());
        let supabase_service_role_key = std::env::var("SUPABASE_SERVICE_ROLE_KEY").ok();
        let nebula_issuer = std::env::var("NEBULA_ISSUER")
            .unwrap_or_else(|_| "http://127.0.0.1:3000".to_string())
            .trim_end_matches('/')
            .to_string();
        let oauth_dev_headless_authorize_enabled = matches!(
            std::env::var("NEBULA_ALLOW_DEV_HEADLESS_AUTHORIZE")
                .unwrap_or_else(|_| "false".to_string())
                .to_lowercase()
                .as_str(),
            "1" | "true" | "yes"
        );
        let oauth_public_clients = load_public_clients();
        let oauth_browser_mfa_code = std::env::var("NEBULA_BROWSER_MFA_CODE")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let auth_proxy_upstream = normalize_auth_proxy_upstream(
            std::env::var("NEBULA_AUTH_PROXY_UPSTREAM").ok(),
            "https://nebula-auth-jfnt.onrender.com",
        );
        let auth_proxy_public_host = std::env::var("NEBULA_AUTH_PROXY_PUBLIC_HOST")
            .unwrap_or_else(|_| "auth.nebula-technologies.net".to_string())
            .trim()
            .to_string();
        let auth_proxy_client = reqwest::Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .user_agent("skybridge-nebula-auth-proxy/1.0")
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());

        let (tx, _rx) = broadcast::channel::<String>(64);
        Self {
            users: Arc::new(DashMap::new()),
            credentials: Arc::new(DashMap::new()),
            codes: Arc::new(DashMap::new()),
            phone_rate_limits: Arc::new(DashMap::new()),
            device_rate_limits: Arc::new(DashMap::new()),
            supabase: Arc::new(SupabaseClient::new(
                supabase_url,
                supabase_key,
                supabase_service_role_key,
            )),
            upload_sessions: Arc::new(DashMap::new()),
            upload_received: Arc::new(DashMap::new()),
            ws_tx: Arc::new(tx),
            ws_topics: Arc::new(DashMap::new()),
            auth_tokens: Arc::new(DashMap::new()),
            oauth_authorization_codes: Arc::new(DashMap::new()),
            oauth_pending_mfa_sessions: Arc::new(DashMap::new()),
            oauth_revoked_refresh_tokens: Arc::new(DashMap::new()),
            oauth_public_clients: Arc::new(oauth_public_clients),
            oauth_dev_headless_authorize_enabled,
            oauth_browser_mfa_code,
            nebula_issuer,
            auth_proxy_upstream,
            auth_proxy_public_host,
            auth_proxy_client,
        }
    }

    /// Check phone rate limit using sliding window algorithm
    /// Returns RateLimitResult with detailed information
    pub fn check_phone_rate_limit(&self, phone: &str) -> RateLimitResult {
        self.check_rate_limit_internal(&self.phone_rate_limits, phone, PHONE_LIMIT)
    }

    /// Check device rate limit using sliding window algorithm
    /// Returns RateLimitResult with detailed information
    pub fn check_device_rate_limit(&self, device_fp: &str) -> RateLimitResult {
        self.check_rate_limit_internal(&self.device_rate_limits, device_fp, DEVICE_LIMIT)
    }

    /// Internal sliding window rate limit check
    fn check_rate_limit_internal(
        &self,
        limits: &DashMap<String, RateLimit>,
        key: &str,
        limit: u32,
    ) -> RateLimitResult {
        let now = Utc::now();
        let window_start = now - Duration::seconds(WINDOW_SECONDS);

        let mut entry = limits.entry(key.to_string()).or_insert_with(RateLimit::new);

        // Remove expired timestamps (sliding window cleanup)
        entry.timestamps.retain(|ts| *ts > window_start);

        let current_count = entry.timestamps.len() as u32;

        if current_count < limit {
            // Add new timestamp and allow
            entry.timestamps.push(now);
            RateLimitResult {
                allowed: true,
                current_count: current_count + 1,
                limit,
                reset_at: entry
                    .timestamps
                    .first()
                    .map(|ts| *ts + Duration::seconds(WINDOW_SECONDS)),
            }
        } else {
            // Rate limit exceeded
            let oldest = entry.timestamps.first().copied();
            RateLimitResult {
                allowed: false,
                current_count,
                limit,
                reset_at: oldest.map(|ts| ts + Duration::seconds(WINDOW_SECONDS)),
            }
        }
    }

    /// Legacy check_rate_limit for backward compatibility
    /// Returns true if allowed, false if rate limited
    pub fn check_rate_limit(&self, key: &str, limit: u32, window_seconds: i64) -> bool {
        let now = Utc::now();
        let window_start = now - Duration::seconds(window_seconds);

        // Determine which map to use based on key pattern
        // Phone numbers typically start with + or digits, device FPs are longer hex strings
        let limits = if key.len() > 32 {
            &self.device_rate_limits
        } else {
            &self.phone_rate_limits
        };

        let mut entry = limits.entry(key.to_string()).or_insert_with(RateLimit::new);

        // Remove expired timestamps
        entry.timestamps.retain(|ts| *ts > window_start);

        if (entry.timestamps.len() as u32) < limit {
            entry.timestamps.push(now);
            true
        } else {
            false
        }
    }

    /// Get current rate limit status without incrementing
    pub fn get_rate_limit_status(
        &self,
        phone: &str,
        device_fp: &str,
    ) -> (RateLimitResult, RateLimitResult) {
        let phone_result = self.peek_rate_limit(&self.phone_rate_limits, phone, PHONE_LIMIT);
        let device_result = self.peek_rate_limit(&self.device_rate_limits, device_fp, DEVICE_LIMIT);
        (phone_result, device_result)
    }

    /// Peek at rate limit without incrementing counter
    fn peek_rate_limit(
        &self,
        limits: &DashMap<String, RateLimit>,
        key: &str,
        limit: u32,
    ) -> RateLimitResult {
        let now = Utc::now();
        let window_start = now - Duration::seconds(WINDOW_SECONDS);

        if let Some(mut entry) = limits.get_mut(key) {
            entry.timestamps.retain(|ts| *ts > window_start);
            let current_count = entry.timestamps.len() as u32;
            RateLimitResult {
                allowed: current_count < limit,
                current_count,
                limit,
                reset_at: entry
                    .timestamps
                    .first()
                    .map(|ts| *ts + Duration::seconds(WINDOW_SECONDS)),
            }
        } else {
            RateLimitResult {
                allowed: true,
                current_count: 0,
                limit,
                reset_at: None,
            }
        }
    }

    /// Reset rate limits for a specific phone number (for testing)
    pub fn reset_phone_rate_limit(&self, phone: &str) {
        self.phone_rate_limits.remove(phone);
    }

    /// Reset rate limits for a specific device (for testing)
    pub fn reset_device_rate_limit(&self, device_fp: &str) {
        self.device_rate_limits.remove(device_fp);
    }

    /// Clean up expired rate limit entries (call periodically)
    pub fn cleanup_expired_rate_limits(&self) {
        let now = Utc::now();
        let window_start = now - Duration::seconds(WINDOW_SECONDS);

        // Cleanup phone limits
        self.phone_rate_limits.retain(|_, v| {
            v.timestamps.retain(|ts| *ts > window_start);
            !v.timestamps.is_empty()
        });

        // Cleanup device limits
        self.device_rate_limits.retain(|_, v| {
            v.timestamps.retain(|ts| *ts > window_start);
            !v.timestamps.is_empty()
        });
    }

    /// Clean up expired verification codes
    pub fn cleanup_expired_codes(&self) {
        self.codes.retain(|_, code| !code.is_expired());
    }

    /// Clean up all expired entries (rate limits and codes)
    pub fn cleanup_all_expired(&self) {
        self.cleanup_expired_rate_limits();
        self.cleanup_expired_codes();
        self.cleanup_expired_upload_sessions();
        self.cleanup_expired_oauth_artifacts();
    }

    /// Check if an upload session is expired (older than 30 minutes)
    pub fn is_upload_session_expired(&self, session_id: &str) -> Option<bool> {
        self.upload_sessions
            .get(session_id)
            .map(|session| Utc::now() - session.created_at > Duration::minutes(30))
    }

    /// Clean up expired upload sessions (older than 30 minutes)
    pub fn cleanup_expired_upload_sessions(&self) {
        let now = Utc::now();
        let expired_ids: Vec<String> = self
            .upload_sessions
            .iter()
            .filter(|entry| now - entry.created_at > Duration::minutes(30))
            .map(|entry| entry.id.clone())
            .collect();

        for id in expired_ids {
            self.upload_sessions.remove(&id);
            self.upload_received.remove(&id);
        }
    }

    pub fn cleanup_expired_oauth_artifacts(&self) {
        let now = Utc::now();
        self.oauth_authorization_codes
            .retain(|_, record| record.expires_at > now);
        self.oauth_pending_mfa_sessions
            .retain(|_, record| record.expires_at > now);

        let cutoff = now - revoked_refresh_token_retention();
        self.oauth_revoked_refresh_tokens
            .retain(|_, revoked_at| *revoked_at > cutoff);
    }
}

fn normalize_auth_proxy_upstream(configured: Option<String>, fallback: &str) -> String {
    let candidate = configured
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback);

    match Url::parse(candidate) {
        Ok(url) if matches!(url.scheme(), "http" | "https") && url.host_str().is_some() => {
            candidate.trim_end_matches('/').to_string()
        }
        _ => {
            warn!(
                "invalid NEBULA_AUTH_PROXY_UPSTREAM={:?}; falling back to {}",
                configured.as_deref(),
                fallback
            );
            fallback.trim_end_matches('/').to_string()
        }
    }
}

fn load_public_clients() -> HashMap<String, PublicClientRegistration> {
    match std::env::var("NEBULA_PUBLIC_CLIENTS_JSON") {
        Ok(raw) if !raw.trim().is_empty() => {
            match serde_json::from_str::<HashMap<String, PublicClientRegistration>>(&raw) {
                Ok(clients) => clients,
                Err(error) => {
                    tracing::warn!(
                        "Failed to parse NEBULA_PUBLIC_CLIENTS_JSON, using defaults: {}",
                        error
                    );
                    default_public_clients()
                }
            }
        }
        _ => default_public_clients(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn auth_proxy_upstream_accepts_https_urls() {
        let normalized = normalize_auth_proxy_upstream(
            Some("https://auth.nebula-technologies.net/".to_string()),
            "https://fallback.example.com",
        );
        assert_eq!(normalized, "https://auth.nebula-technologies.net");
    }

    #[test]
    fn auth_proxy_upstream_rejects_custom_scheme_urls() {
        let normalized = normalize_auth_proxy_upstream(
            Some("skybridge://auth/nebula?code=abc".to_string()),
            "https://fallback.example.com",
        );
        assert_eq!(normalized, "https://fallback.example.com");
    }

    #[test]
    fn auth_proxy_upstream_rejects_empty_values() {
        let normalized =
            normalize_auth_proxy_upstream(Some("   ".to_string()), "https://fallback.example.com");
        assert_eq!(normalized, "https://fallback.example.com");
    }

    #[test]
    fn test_phone_rate_limit_allows_under_limit() {
        let state = AppState::new();

        for i in 0..PHONE_LIMIT {
            let result = state.check_phone_rate_limit("+1234567890");
            assert!(result.allowed, "Request {} should be allowed", i + 1);
            assert_eq!(result.current_count, i + 1);
        }
    }

    #[test]
    fn test_phone_rate_limit_blocks_over_limit() {
        let state = AppState::new();

        // Fill up the limit
        for _ in 0..PHONE_LIMIT {
            state.check_phone_rate_limit("+1234567890");
        }

        // Next request should be blocked
        let result = state.check_phone_rate_limit("+1234567890");
        assert!(!result.allowed);
        assert_eq!(result.current_count, PHONE_LIMIT);
    }

    #[test]
    fn test_device_rate_limit_allows_under_limit() {
        let state = AppState::new();
        let device_fp = "abc123def456abc123def456abc123def456";

        for i in 0..DEVICE_LIMIT {
            let result = state.check_device_rate_limit(device_fp);
            assert!(result.allowed, "Request {} should be allowed", i + 1);
        }
    }

    #[test]
    fn test_device_rate_limit_blocks_over_limit() {
        let state = AppState::new();
        let device_fp = "abc123def456abc123def456abc123def456";

        // Fill up the limit
        for _ in 0..DEVICE_LIMIT {
            state.check_device_rate_limit(device_fp);
        }

        // Next request should be blocked
        let result = state.check_device_rate_limit(device_fp);
        assert!(!result.allowed);
        assert_eq!(result.current_count, DEVICE_LIMIT);
    }

    #[test]
    fn test_separate_phone_and_device_limits() {
        let state = AppState::new();
        let phone = "+1234567890";
        let device_fp = "abc123def456abc123def456abc123def456";

        // Fill phone limit
        for _ in 0..PHONE_LIMIT {
            state.check_phone_rate_limit(phone);
        }

        // Device should still be allowed
        let result = state.check_device_rate_limit(device_fp);
        assert!(result.allowed);

        // Phone should be blocked
        let result = state.check_phone_rate_limit(phone);
        assert!(!result.allowed);
    }

    #[test]
    fn test_reset_rate_limit() {
        let state = AppState::new();
        let phone = "+1234567890";

        // Fill limit
        for _ in 0..PHONE_LIMIT {
            state.check_phone_rate_limit(phone);
        }

        // Should be blocked
        assert!(!state.check_phone_rate_limit(phone).allowed);

        // Reset
        state.reset_phone_rate_limit(phone);

        // Should be allowed again
        assert!(state.check_phone_rate_limit(phone).allowed);
    }

    // ============================================================
    // Property-Based Tests
    // ============================================================

    /// Strategy for generating valid phone numbers
    fn phone_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex(r"\+[1-9][0-9]{9,14}").unwrap()
    }

    /// Strategy for generating device fingerprints (hex strings)
    fn device_fp_strategy() -> impl Strategy<Value = String> {
        prop::string::string_regex("[a-f0-9]{32,64}").unwrap()
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: skybridge-compass-web, Property 1: Rate Limiting Enforcement**
        /// *For any* phone number or device fingerprint, after reaching the daily limit
        /// (10 for phone, 20 for device), all subsequent verification code requests
        /// SHALL be rejected with 429 status.
        /// **Validates: Requirements 1.3, 8.1, 8.2**
        #[test]
        fn prop_phone_rate_limit_enforcement(phone in phone_strategy()) {
            let state = AppState::new();

            // Make exactly PHONE_LIMIT requests - all should be allowed
            for i in 0..PHONE_LIMIT {
                let result = state.check_phone_rate_limit(&phone);
                prop_assert!(result.allowed,
                    "Request {} should be allowed for phone {}", i + 1, phone);
                prop_assert_eq!(result.current_count, i + 1);
                prop_assert_eq!(result.limit, PHONE_LIMIT);
            }

            // Any additional requests should be blocked
            for _ in 0..5 {
                let result = state.check_phone_rate_limit(&phone);
                prop_assert!(!result.allowed,
                    "Request after limit should be blocked for phone {}", phone);
                prop_assert_eq!(result.current_count, PHONE_LIMIT);
            }
        }

        /// **Feature: skybridge-compass-web, Property 1: Rate Limiting Enforcement (Device)**
        /// **Validates: Requirements 1.3, 8.1, 8.2**
        #[test]
        fn prop_device_rate_limit_enforcement(device_fp in device_fp_strategy()) {
            let state = AppState::new();

            // Make exactly DEVICE_LIMIT requests - all should be allowed
            for i in 0..DEVICE_LIMIT {
                let result = state.check_device_rate_limit(&device_fp);
                prop_assert!(result.allowed,
                    "Request {} should be allowed for device {}", i + 1, device_fp);
                prop_assert_eq!(result.current_count, i + 1);
                prop_assert_eq!(result.limit, DEVICE_LIMIT);
            }

            // Any additional requests should be blocked
            for _ in 0..5 {
                let result = state.check_device_rate_limit(&device_fp);
                prop_assert!(!result.allowed,
                    "Request after limit should be blocked for device {}", device_fp);
                prop_assert_eq!(result.current_count, DEVICE_LIMIT);
            }
        }

        /// **Feature: skybridge-compass-web, Property 1: Rate Limiting Enforcement (Independence)**
        /// Phone and device limits are independent - exhausting one doesn't affect the other
        /// **Validates: Requirements 1.3, 8.1, 8.2**
        #[test]
        fn prop_rate_limits_are_independent(
            phone in phone_strategy(),
            device_fp in device_fp_strategy()
        ) {
            let state = AppState::new();

            // Exhaust phone limit
            for _ in 0..PHONE_LIMIT {
                state.check_phone_rate_limit(&phone);
            }

            // Phone should be blocked
            prop_assert!(!state.check_phone_rate_limit(&phone).allowed);

            // Device should still be allowed (independent counter)
            let device_result = state.check_device_rate_limit(&device_fp);
            prop_assert!(device_result.allowed,
                "Device limit should be independent of phone limit");
            prop_assert_eq!(device_result.current_count, 1);
        }

        /// **Feature: skybridge-compass-web, Property 1: Rate Limiting Enforcement (Multiple Keys)**
        /// Different phones/devices have independent limits
        /// **Validates: Requirements 1.3, 8.1, 8.2**
        #[test]
        fn prop_different_keys_have_independent_limits(
            phone1 in phone_strategy(),
            phone2 in phone_strategy()
        ) {
            prop_assume!(phone1 != phone2);

            let state = AppState::new();

            // Exhaust limit for phone1
            for _ in 0..PHONE_LIMIT {
                state.check_phone_rate_limit(&phone1);
            }

            // phone1 should be blocked
            prop_assert!(!state.check_phone_rate_limit(&phone1).allowed);

            // phone2 should still be allowed
            let result = state.check_phone_rate_limit(&phone2);
            prop_assert!(result.allowed,
                "Different phone numbers should have independent limits");
            prop_assert_eq!(result.current_count, 1);
        }

        /// **Feature: skybridge-compass-web, Property 1: Rate Limiting Enforcement (Count Accuracy)**
        /// The current_count accurately reflects the number of requests made
        /// **Validates: Requirements 1.3, 8.1, 8.2**
        #[test]
        fn prop_rate_limit_count_accuracy(
            phone in phone_strategy(),
            num_requests in 1u32..=PHONE_LIMIT
        ) {
            let state = AppState::new();

            for i in 0..num_requests {
                let result = state.check_phone_rate_limit(&phone);
                prop_assert_eq!(result.current_count, i + 1,
                    "Count should accurately reflect number of requests");
            }
        }
    }
}
