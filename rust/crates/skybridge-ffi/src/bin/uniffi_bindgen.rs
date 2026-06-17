//! In-tree UniFFI binding generator.
//!
//! UniFFI ships its CLI as a library so each project pins one matching version.
//! This thin binary exposes it so bindings can be generated without a separate
//! `uniffi-bindgen` install (which may not be on PATH in CI).
//!
//! Example (run after `cargo build -p skybridge-ffi`):
//!
//! ```text
//! cargo run -p skybridge-ffi --features uniffi-cli --bin uniffi-bindgen -- \
//!     generate --library target/debug/libskybridge_ffi.dylib \
//!     --language kotlin --out-dir target/bindings/kotlin
//!
//! cargo run -p skybridge-ffi --features uniffi-cli --bin uniffi-bindgen -- \
//!     generate --library target/debug/libskybridge_ffi.dylib \
//!     --language swift --out-dir target/bindings/swift
//! ```

fn main() {
    uniffi::uniffi_bindgen_main()
}
