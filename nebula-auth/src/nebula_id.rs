use chrono::{Datelike, Local};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const PREFIX: &str = "NEBULA";
const EPOCH_MILLIS: u64 = 1_735_689_600_000; // 2025-01-01 00:00:00 UTC (ms)

// Bit layout (64-bit):
// [Timestamp: 41 bits | Datacenter: 5 bits | Worker: 5 bits | Sequence: 12 bits]
const SEQUENCE_BITS: u64 = 12;
const WORKER_BITS: u64 = 5;
const DATACENTER_BITS: u64 = 5;

const MAX_SEQUENCE: u64 = (1 << SEQUENCE_BITS) - 1;

const WORKER_SHIFT: u64 = SEQUENCE_BITS;
const DATACENTER_SHIFT: u64 = SEQUENCE_BITS + WORKER_BITS;
const TIMESTAMP_SHIFT: u64 = SEQUENCE_BITS + WORKER_BITS + DATACENTER_BITS;

#[derive(Default)]
struct GeneratorState {
    last_timestamp: u64,
    sequence: u64,
}

pub struct NebulaIdGenerator {
    datacenter_id: u64,
    worker_id: u64,
    state: Mutex<GeneratorState>,
}

impl NebulaIdGenerator {
    pub fn new(datacenter_id: u64, worker_id: u64) -> Self {
        Self {
            datacenter_id,
            worker_id,
            state: Mutex::new(GeneratorState::default()),
        }
    }

    pub fn generate_user_registration_id(&self) -> String {
        self.generate_id()
    }

    fn generate_id(&self) -> String {
        let mut state = self
            .state
            .lock()
            .expect("nebula id generator lock poisoned");

        let mut timestamp = Self::now_millis();

        // Web/back-end should not crash on clock skew: clamp to last timestamp.
        if timestamp < state.last_timestamp {
            timestamp = state.last_timestamp;
        }

        if timestamp == state.last_timestamp {
            state.sequence = (state.sequence + 1) & MAX_SEQUENCE;
            if state.sequence == 0 {
                timestamp = Self::wait_next_millis(timestamp);
            }
        } else {
            state.sequence = 0;
        }

        state.last_timestamp = timestamp;

        let adjusted = timestamp.saturating_sub(EPOCH_MILLIS);
        let raw_id = (adjusted << TIMESTAMP_SHIFT)
            | (self.datacenter_id << DATACENTER_SHIFT)
            | (self.worker_id << WORKER_SHIFT)
            | state.sequence;

        let year = Local::now().year();
        let base36 = fixed_base36_upper(raw_id);
        format!("{PREFIX}-{year}-{base36}")
    }

    fn now_millis() -> u64 {
        let dur = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        dur.as_millis() as u64
    }

    fn wait_next_millis(last_timestamp: u64) -> u64 {
        let mut ts = Self::now_millis();
        while ts <= last_timestamp {
            ts = Self::now_millis();
        }
        ts
    }
}

fn base36_upper(mut value: u64) -> String {
    const ALPHABET: &[u8; 36] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

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

fn fixed_base36_upper(raw_id: u64) -> String {
    // Match macOS/iOS Swift behavior:
    // `String(rawId, radix: 36).uppercased().padding(toLength: 12, withPad: "0", startingAt: 0)`
    // - Right-pads with '0' to 12
    // - Truncates to 12
    let mut base36 = base36_upper(raw_id);
    if base36.len() < 12 {
        base36.push_str(&"0".repeat(12 - base36.len()));
    }
    if base36.len() > 12 {
        base36.truncate(12);
    }
    base36
}

static SHARED: OnceLock<NebulaIdGenerator> = OnceLock::new();

pub fn generate_user_registration_id() -> String {
    SHARED
        .get_or_init(|| NebulaIdGenerator::new(1, 1))
        .generate_user_registration_id()
}
