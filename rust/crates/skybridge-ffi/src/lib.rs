//! # skybridge-ffi — outward FFI surface for the portable SkyBridge core
//!
//! This crate is the keystone that lets **non-Rust** clients (Windows C#/.NET,
//! Android Kotlin, Linux C/C++) *drive* the shared, OS-portable
//! [`skybridge-core`] secure-transport stack instead of each platform
//! reimplementing the SkyBridge protocol. It directly answers the
//! "generalize beyond Apple" critique by making the framework genuinely
//! language-agnostic from one Rust core.
//!
//! It deliberately exposes only the surface that is *already real and
//! OS-portable today*:
//!
//! - **Identity / init** — generate a PQC device identity (ML-DSA-65 signing +
//!   ML-KEM-768 / X-Wing KEM material) and read back its public keys.
//! - **Downgrade policy** — construct a [`skybridge_core::PolicyGate`], select a
//!   [`skybridge_core::DowngradePolicy`], and authorize/deny PQC→Classic
//!   downgrades, receiving the auditable [`skybridge_core::DowngradeEvent`].
//! - **mDNS discovery** — start/stop a live `_skybridge._tcp` browse driven by a
//!   crate-owned Tokio runtime, with results delivered to a callback.
//! - **File-transfer frame codec** — encode/decode the binary `SBF1` file frames
//!   carried inside the encrypted control channel.
//! - **Event subscription** — discovery / handshake-state / downgrade events via
//!   registered callbacks.
//!
//! It does **not** expose remote-desktop capture/inject — that is a separate,
//! platform-native `PlatformAdapter` concern and is out of scope here.
//!
//! ## Two coordinated binding surfaces
//!
//! 1. [`c_abi`] — a hand-written, panic-safe **C ABI** (`extern "C"`) for
//!    C/C++/C# P/Invoke. cbindgen generates `include/skybridge_ffi.h` from it.
//! 2. [`uniffi_api`] — a **UniFFI** (proc-macro) surface for Kotlin (Android) and
//!    Swift, generated from a single Rust definition.
//!
//! Both are thin wrappers over `skybridge-core`; the core's public API and its
//! inward `apple-platform-ffi` feature are untouched.

pub mod c_abi;

#[cfg(feature = "uniffi-scaffolding")]
pub mod uniffi_api;

// Emit the UniFFI scaffolding for the proc-macro surface. Must be invoked once,
// at crate root, when the UniFFI feature is enabled.
#[cfg(feature = "uniffi-scaffolding")]
uniffi::setup_scaffolding!("skybridge_ffi");

// Re-export the C-ABI symbols at the crate root so cbindgen (which parses the
// crate root) sees them, and so the `extern "C"` functions are exported from the
// cdylib/staticlib.
pub use c_abi::*;
