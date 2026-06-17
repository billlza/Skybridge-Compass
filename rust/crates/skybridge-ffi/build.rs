//! Build script for `skybridge-ffi`.
//!
//! Two jobs:
//!   1. Generate the C header (`include/skybridge_ffi.h`) from the C-ABI surface
//!      via cbindgen, so C/C++/C# (P/Invoke) consumers have an up-to-date,
//!      machine-generated interface.
//!   2. When the `uniffi-scaffolding` feature is on, run UniFFI's proc-macro
//!      setup so Kotlin/Swift bindings can be generated from the same crate.

use std::env;
use std::path::PathBuf;

fn main() {
    // ---- 1. cbindgen: emit the C header ----
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR set by cargo");
    let crate_dir = PathBuf::from(crate_dir);
    let config_path = crate_dir.join("cbindgen.toml");
    let header_path = crate_dir.join("include").join("skybridge_ffi.h");

    // Rebuild the header when the surface or config changes.
    println!("cargo:rerun-if-changed=src/c_abi.rs");
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    let config = cbindgen::Config::from_file(&config_path)
        .unwrap_or_else(|err| panic!("failed to read cbindgen.toml: {err}"));

    match cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
    {
        Ok(bindings) => {
            std::fs::create_dir_all(crate_dir.join("include"))
                .expect("create include/ dir for generated header");
            bindings.write_to_file(&header_path);
        }
        Err(cbindgen::Error::ParseSyntaxError { .. }) => {
            // A transient/partial parse (e.g. during an incremental edit) must
            // not fail the build; the header already on disk stays valid.
            println!(
                "cargo:warning=cbindgen parse error; keeping existing skybridge_ffi.h"
            );
        }
        Err(err) => {
            // Any other cbindgen failure is a hard error: a stale header is worse
            // than a loud failure for an ABI surface.
            panic!("cbindgen failed to generate skybridge_ffi.h: {err}");
        }
    }

    // ---- 2. UniFFI scaffolding (Kotlin/Swift) ----
    //
    // The UniFFI surface uses the proc-macro flavor (`#[uniffi::export]` +
    // `uniffi::setup_scaffolding!()` in `lib.rs`), so there is no `.udl` file to
    // compile here — the scaffolding is emitted by the proc-macros at compile
    // time. This build step only needs to ensure UniFFI's build feature is
    // linked, which the `[build-dependencies]` declaration already handles.
}
