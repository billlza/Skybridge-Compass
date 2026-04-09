//! NebulaID Generator
//!
//! Implements a Snowflake-based distributed ID system compatible with
//! macOS and Android SkyBridge implementations.
//!
//! ## ID Format
//! `NEBULA-{year}-{base36_id}`
//! Example: `NEBULA-2025-A1B2C3D4E5F6`
//!
//! ## Bit Structure (64-bit)
//! ```text
//! [Timestamp: 41 bits | Datacenter: 5 bits | Worker: 5 bits | Sequence: 12 bits]
//! ```

use chrono::{Datelike, Local};
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

/// Epoch start: 2025-01-01 00:00:00 UTC
const EPOCH_MILLIS: u64 = 1735689600000;

/// Bit allocations
const DATACENTER_BITS: u8 = 5;
const WORKER_BITS: u8 = 5;
const SEQUENCE_BITS: u8 = 12;

/// Maximum values
const MAX_DATACENTER_ID: u64 = (1 << DATACENTER_BITS) - 1; // 31
const MAX_WORKER_ID: u64 = (1 << WORKER_BITS) - 1; // 31
const MAX_SEQUENCE: u64 = (1 << SEQUENCE_BITS) - 1; // 4095

/// Bit shifts
const WORKER_SHIFT: u8 = SEQUENCE_BITS;
const DATACENTER_SHIFT: u8 = SEQUENCE_BITS + WORKER_BITS;
const TIMESTAMP_SHIFT: u8 = SEQUENCE_BITS + WORKER_BITS + DATACENTER_BITS;

/// Errors that can occur during NebulaID generation
#[derive(Debug, Error)]
pub enum NebulaIdError {
    /// Clock moved backwards
    #[error("Clock moved backwards: last={last}, current={current}")]
    ClockMovedBackwards { last: u64, current: u64 },

    /// Invalid datacenter ID
    #[error("Invalid datacenter ID: {0} (max: {MAX_DATACENTER_ID})")]
    InvalidDatacenterId(u64),

    /// Invalid worker ID
    #[error("Invalid worker ID: {0} (max: {MAX_WORKER_ID})")]
    InvalidWorkerId(u64),

    /// Invalid NebulaID format
    #[error("Invalid NebulaID format: {0}")]
    InvalidFormat(String),

    /// Sequence overflow (too many IDs in same millisecond)
    #[error("Sequence overflow - too many IDs generated in the same millisecond")]
    SequenceOverflow,
}

/// A parsed NebulaID
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NebulaId {
    /// Raw 64-bit ID value
    pub raw: u64,
    /// Year component
    pub year: u16,
    /// Base36 encoded string (12 characters)
    pub base36: String,
    /// Full formatted ID
    pub formatted: String,
}

impl NebulaId {
    /// Create a new NebulaID from raw value and year
    pub fn new(raw: u64, year: u16) -> Self {
        let base36 = Self::encode_base36(raw);
        let formatted = format!("NEBULA-{}-{}", year, base36);
        Self {
            raw,
            year,
            base36,
            formatted,
        }
    }

    /// Parse a NebulaID from its formatted string
    pub fn parse(s: &str) -> Result<Self, NebulaIdError> {
        let parts: Vec<&str> = s.split('-').collect();
        if parts.len() != 3 || parts[0] != "NEBULA" {
            return Err(NebulaIdError::InvalidFormat(s.to_string()));
        }

        let year: u16 = parts[1]
            .parse()
            .map_err(|_| NebulaIdError::InvalidFormat(s.to_string()))?;

        let base36 = parts[2];
        let raw = Self::decode_base36(base36)
            .ok_or_else(|| NebulaIdError::InvalidFormat(s.to_string()))?;

        Ok(Self {
            raw,
            year,
            base36: base36.to_string(),
            formatted: s.to_string(),
        })
    }

    /// Validate a NebulaID string
    pub fn is_valid(s: &str) -> bool {
        Self::parse(s).is_ok()
    }

    /// Extract timestamp from ID (milliseconds since epoch)
    pub fn timestamp(&self) -> u64 {
        (self.raw >> TIMESTAMP_SHIFT) + EPOCH_MILLIS
    }

    /// Extract datacenter ID
    pub fn datacenter_id(&self) -> u64 {
        (self.raw >> DATACENTER_SHIFT) & MAX_DATACENTER_ID
    }

    /// Extract worker ID
    pub fn worker_id(&self) -> u64 {
        (self.raw >> WORKER_SHIFT) & MAX_WORKER_ID
    }

    /// Extract sequence number
    pub fn sequence(&self) -> u64 {
        self.raw & MAX_SEQUENCE
    }

    /// Encode a 64-bit value to base36 (12 characters, padded)
    fn encode_base36(value: u64) -> String {
        const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

        fn base36_upper(mut value: u64) -> String {
            if value == 0 {
                return "0".to_string();
            }
            let mut out = Vec::new();
            while value > 0 {
                out.push(ALPHABET[(value % 36) as usize] as char);
                value /= 36;
            }
            out.iter().rev().collect()
        }

        // Match macOS/iOS Swift behavior:
        // `String(rawId, radix: 36).uppercased().padding(toLength: 12, withPad: "0", startingAt: 0)`
        let mut base36 = base36_upper(value);
        if base36.len() < 12 {
            base36.push_str(&"0".repeat(12 - base36.len()));
        }
        if base36.len() > 12 {
            base36.truncate(12);
        }
        base36
    }

    /// Decode a base36 string to 64-bit value
    fn decode_base36(s: &str) -> Option<u64> {
        let mut result: u64 = 0;
        for c in s.chars() {
            let digit = match c {
                '0'..='9' => c as u64 - '0' as u64,
                'A'..='Z' => c as u64 - 'A' as u64 + 10,
                'a'..='z' => c as u64 - 'a' as u64 + 10,
                _ => return None,
            };
            result = result.checked_mul(36)?.checked_add(digit)?;
        }
        Some(result)
    }
}

impl std::fmt::Display for NebulaId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.formatted)
    }
}

impl serde::Serialize for NebulaId {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.formatted)
    }
}

impl<'de> serde::Deserialize<'de> for NebulaId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        NebulaId::parse(&s).map_err(serde::de::Error::custom)
    }
}

/// Internal state for ID generation
struct GeneratorState {
    last_timestamp: u64,
    sequence: u64,
}

/// NebulaID Generator
///
/// Thread-safe Snowflake-based ID generator compatible with macOS/Android.
#[derive(Clone)]
pub struct NebulaIdGenerator {
    datacenter_id: u64,
    worker_id: u64,
    state: Arc<Mutex<GeneratorState>>,
}

impl NebulaIdGenerator {
    /// Create a new generator with datacenter and worker IDs
    pub fn new(datacenter_id: u64, worker_id: u64) -> Result<Self, NebulaIdError> {
        if datacenter_id > MAX_DATACENTER_ID {
            return Err(NebulaIdError::InvalidDatacenterId(datacenter_id));
        }
        if worker_id > MAX_WORKER_ID {
            return Err(NebulaIdError::InvalidWorkerId(worker_id));
        }

        Ok(Self {
            datacenter_id,
            worker_id,
            state: Arc::new(Mutex::new(GeneratorState {
                last_timestamp: 0,
                sequence: 0,
            })),
        })
    }

    /// Create a generator with automatic IDs based on machine characteristics
    pub fn auto() -> Result<Self, NebulaIdError> {
        // Use hash of hostname for datacenter ID
        let hostname = hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "unknown".to_string());

        let datacenter_id = {
            use sha2::{Digest, Sha256};
            let mut hasher = Sha256::new();
            hasher.update(hostname.as_bytes());
            let result = hasher.finalize();
            (result[0] as u64) % (MAX_DATACENTER_ID + 1)
        };

        // Use process ID for worker ID
        let worker_id = std::process::id() as u64 % (MAX_WORKER_ID + 1);

        Self::new(datacenter_id, worker_id)
    }

    /// Get current timestamp in milliseconds
    fn current_timestamp() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("Time went backwards")
            .as_millis() as u64
    }

    /// Wait until next millisecond
    fn wait_next_millis(last_timestamp: u64) -> u64 {
        let mut timestamp = Self::current_timestamp();
        while timestamp <= last_timestamp {
            std::hint::spin_loop();
            timestamp = Self::current_timestamp();
        }
        timestamp
    }

    /// Generate a new NebulaID
    pub fn generate(&self) -> Result<NebulaId, NebulaIdError> {
        let mut state = self.state.lock();
        let mut timestamp = Self::current_timestamp();

        // Handle clock going backwards
        if timestamp < state.last_timestamp {
            return Err(NebulaIdError::ClockMovedBackwards {
                last: state.last_timestamp,
                current: timestamp,
            });
        }

        if timestamp == state.last_timestamp {
            // Same millisecond - increment sequence
            state.sequence = (state.sequence + 1) & MAX_SEQUENCE;
            if state.sequence == 0 {
                // Sequence overflow - wait for next millisecond
                timestamp = Self::wait_next_millis(state.last_timestamp);
            }
        } else {
            // New millisecond - reset sequence
            state.sequence = 0;
        }

        state.last_timestamp = timestamp;

        // Build the 64-bit ID
        let raw = ((timestamp - EPOCH_MILLIS) << TIMESTAMP_SHIFT)
            | (self.datacenter_id << DATACENTER_SHIFT)
            | (self.worker_id << WORKER_SHIFT)
            | state.sequence;

        // Match macOS/iOS behavior: year component comes from the local calendar.
        let year = Local::now().year() as u16;

        Ok(NebulaId::new(raw, year))
    }

    /// Generate a user registration ID
    pub fn generate_user_registration_id(&self) -> Result<NebulaId, NebulaIdError> {
        self.generate()
    }

    /// Generate a session ID
    pub fn generate_session_id(&self) -> Result<NebulaId, NebulaIdError> {
        self.generate()
    }

    /// Generate a company/organization ID
    pub fn generate_company_id(&self) -> Result<NebulaId, NebulaIdError> {
        self.generate()
    }

    /// Generate a device ID
    pub fn generate_device_id(&self) -> Result<NebulaId, NebulaIdError> {
        self.generate()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_id() {
        let generator = NebulaIdGenerator::new(1, 1).unwrap();
        let id = generator.generate().unwrap();

        assert!(id.formatted.starts_with("NEBULA-"));
        assert_eq!(id.base36.len(), 12);
    }

    #[test]
    fn test_parse_id() {
        let generator = NebulaIdGenerator::new(1, 1).unwrap();
        let id = generator.generate().unwrap();

        let parsed = NebulaId::parse(&id.formatted).unwrap();
        assert_eq!(parsed.raw, id.raw);
    }

    #[test]
    fn test_uniqueness() {
        let generator = NebulaIdGenerator::new(1, 1).unwrap();
        let ids: Vec<NebulaId> = (0..1000).map(|_| generator.generate().unwrap()).collect();

        let unique: std::collections::HashSet<_> = ids.iter().map(|id| id.raw).collect();
        assert_eq!(unique.len(), 1000);
    }

    #[test]
    fn test_extract_components() {
        let generator = NebulaIdGenerator::new(5, 10).unwrap();
        let id = generator.generate().unwrap();

        assert_eq!(id.datacenter_id(), 5);
        assert_eq!(id.worker_id(), 10);
    }

    #[test]
    fn test_invalid_ids() {
        assert!(NebulaIdGenerator::new(32, 0).is_err()); // datacenter too high
        assert!(NebulaIdGenerator::new(0, 32).is_err()); // worker too high
    }

    #[test]
    fn test_base36_roundtrip() {
        let original: u64 = 0x123456789ABCDEF0;
        let encoded = NebulaId::encode_base36(original);
        let decoded = NebulaId::decode_base36(&encoded).unwrap();
        assert_eq!(original, decoded);
    }
}
