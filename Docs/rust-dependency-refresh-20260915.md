# Rust dependency refresh for the 0.1.5 release

The workspace was refreshed against the official crates.io stable releases on 2026-09-15. All 42 direct registry dependencies resolve to the verified latest stable version; the following 15 version requirements changed.

| Dependency | Previous requirement | Current requirement |
| --- | --- | --- |
| aes-gcm | 0.11.0 | 0.11.1 |
| async-trait | 0.1.91 | 0.1.92 |
| base64 | 0.23.0 | 0.23.1 |
| clap | 4.6.4 | 4.6.7 |
| futures-util | 0.3.33 | 0.3.34 |
| hpke | 0.14.0 | 0.14.1 |
| mdns-sd | 0.20.2 | 0.21.3 |
| rtc | 0.20.0 | 0.20.5 |
| reqwest | 0.13.4 | 0.13.5 |
| thiserror | 2.0.19 | 2.0.20 |
| time | 0.3.54 | 0.3.55 |
| uuid | 1.24.0 | 1.26.1 |
| webbrowser | 1.2.2 | 1.2.4 |
| webrtc | 0.20.0 | 0.20.5 |
| uniffi | 0.32.0 | 0.32.1 |

The complete workspace lockfile was then refreshed, including Rustls 0.23.45 for RUSTSEC-2026-0285. The unchanged `cargo audit --deny warnings` check reports zero vulnerabilities and zero warnings. The security fix is described in the [official Rustls 0.23.45 release](https://github.com/rustls/rustls/releases/tag/v%2F0.23.45).

Three transitive versions remain explicitly pinned by their parents: `cc =1.2.67` by the published Q-Periapt 0.1.5 native backend, `generic-array =0.14.7` by `crypto-common 0.1.7`, and `matchit =0.8.4` by `axum 0.8.9`. No override bypasses these contracts. The pinned Q-Periapt source remains `7ed1f96a7ec33732f02a989dd5a4669cdcce39ad`.

The local rtc patch is now based on the official 0.20.5 crate, SHA-256 `66355ae7cad547376873a2ee7968eee1e3727492a241c05bf511b01db4cef077`. Upstream still does not register selected peer-reflexive candidates in its statistics snapshot; the prior two-file fix is retained, and the real selected-route loopback test passes. See `rust/vendor/rtc/README-SKYBRIDGE.md` for the precise patch boundary.

The supported default workspace passed 719 tests with no ignored tests, strict Clippy, formatting, and the UniFFI CLI build check on the pinned Rust 1.94.0 toolchain. All 40 protocol-parity pairs passed; the parity checker and CLI release workflow contract tests passed 23 and 11 tests respectively.

The Rust `q-periapt` Cargo feature remains blocked by the existing compile-time guard because that legacy implementation is ABI1. The negative compilation probe confirmed the guard; it is not a claim that Rust ABI2 interoperation passed. Dependency maintenance does not enable or port that protocol implementation.

The same release change fixes an iOS test fixture race: non-timeout approval tests use the production default decision window, and only the timeout test injects 50 milliseconds. Production approval behavior and the assertions are unchanged. The local simulator test build passed, but test-host startup stalled and was stopped with logs retained and the owned simulator shut down. The new candidate must pass the original full iOS cloud suite and diagnostics before signing/publication.

This record describes dependency and regression validation. Package signing, installation, current-source physical acceptance, and publication remain separate release gates.
