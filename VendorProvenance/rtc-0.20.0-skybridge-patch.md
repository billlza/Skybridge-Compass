# rust/vendor/rtc — provenance

- Upstream: crates.io `rtc` 0.20.0 (webrtc-rs sans-IO core)
- Obtained from: local cargo registry cache of the locked dependency
  (`index.crates.io` checkout of `rtc-0.20.0`), i.e. the exact bytes every
  prior `--locked` build compiled.
- Modifications: one stats-registration fix, marked `SKYBRIDGE PATCH` in
  `src/peer_connection/internal.rs` and `src/statistics/accumulator/mod.rs`.
  Rationale and retirement criteria: `rust/vendor/rtc/README-SKYBRIDGE.md`.
- Licenses: MIT OR Apache-2.0 (LICENSE-MIT / LICENSE-APACHE retained in the
  vendored tree).
- Wired via `[patch.crates-io]` in `rust/Cargo.toml`; the transitive `webrtc`
  0.20.0 dependency resolves to this same patched copy.
