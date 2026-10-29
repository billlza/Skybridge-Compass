# CLI contract and architecture validation — 2026-09-13

Scope: the native-runtime decision in [ADR-0003](ADR-0003-Native-Runtimes-and-Operator-Contract.md),
CLI implementation identity, host capability reporting and explicit detached
file-request registration. Linux, signing/publication, Windows-native builds and
current-source physical interop/performance acceptance are outside this run.

## Source and changes

The public CLI working tree is based on `c418fe46bef89267ad4991a19c366ff17beaa609`;
the Windows Core working tree is based on `811ba8f71c1a8d19b5c579748f37e96a46855c6f`.
Both contained prior uncommitted work. Changes described here are working-tree
changes, not a frozen release. Android's inspected local source directory had no
Git metadata. Existing modifications and older validation records were retained.

- ADR-0001 v1.2 retains Kotlin Android protocol/runtime ownership. ADR-0003
  records decision precedence, native runtime ownership, CLI identity and
  conditions for pausing/reassessing the Kotlin architecture.
- CLI scope removes contradictory disabled/ungated descriptions and uses the
  current source plus installed-app capability negotiation.
- Android's earlier ADR gains the runtime amendment; the ABI2 status header now
  distinguishes its completed historical R4 host/emulator record from
  `source_apply_pending` and unverified physical/current-source acceptance.
- Both CLI implementations expose `operator_profile` schema 1 from one local
  constructor shared by version and capability output. The public CLI accepts
  `version --json` and omits Mac-only capabilities on other hosts.
- Windows diagnostic `file send` rejects the unsupported default completion
  path before registration. Explicit `--detach` preserves request registration.
  Windows architecture and acceptance-map descriptions include the migration.

## Executed verification

| Check | Actual result |
| --- | --- |
| `cargo fmt --manifest-path rust/Cargo.toml --all -- --check` | Passed |
| `cargo clippy --locked --offline --manifest-path rust/Cargo.toml -p skybridge --all-targets -- -D warnings` | Passed |
| `cargo test --locked --offline --manifest-path rust/Cargo.toml -p skybridge --all-targets --quiet` | 337 unit + 11 process/JSON integration tests passed; 0 failed/ignored |
| Windows crate: `cargo fmt --all -- --check`, then `cargo clippy --all-targets --all-features -- -D warnings`, then `cargo test --workspace` | All passed on macOS for the portable crate; 231 tests, 0 ignored |
| Both actual binaries: `version --json` and `capabilities --json`, launched outside their source directories | Each implementation's two profiles matched; common fields/completion values matched, implementation IDs and default implementation availability remained distinct |
| `python3 -B Scripts/check_protocol_parity.py` | 40 pairs matched the existing baseline; wire anchors consistent |
| `python3 -B -m unittest discover -s Scripts -p test_check_protocol_parity.py` | 23 passed |
| Android/Apple platform-contract fixture comparison | Byte-identical; SHA-256 `91b14b6922ff2fc7c65270eb3e57bf62f6be9f41c70790087e279a11b1655fea` |
| Independent Python standard-library recomputation of `q-abi2-session-kdf-v1.json` | Transcript hash, both directional keys and both Finished MACs matched: 5/5 |
| Changed-file whitespace and ADR local-link checks | Passed |

The Windows test suite comprises 138 unit, 67 CLI, 15 FFI, 6 ABI2, 3 state-machine
and 2 X25519 tests. Those tests run a portable crate on macOS; they are not a
Windows OS, WinUI or real-transfer acceptance claim.

## Failure history and corrections

1. The first public-CLI test attempt used `--offline` and could not fetch the
   locked `async-trait 0.1.91`. Re-running with network access downloaded the
   locked dependencies. No dependency upgrade was made; the existing dirty
   Cargo.lock predates this run.
2. The new identity process test failed against the old implementation because
   `operator_profile` was absent. It passed after the identity/parser changes.
3. The new Windows default-send regression failed against the old implementation:
   it returned exit 0 and left one pending, unverified request. The new path
   returned exit 2 without changing either absent or existing request registries.
4. A Windows test assertion was initially placed in a remote-desktop test;
   correcting its location restored the intended file-send test, followed by
   the complete required fmt/clippy/test sequence.
5. The first full public-CLI run found the new `operator_profile.rs` missing
   from the source catalog: 336 passed, 1 failed. Registering the source in the
   existing catalog fixed the omission; final fmt/clippy/all-target checks passed.

No assertion, evidence gate or warning level was weakened to obtain these results.

## Meaning and remaining gates

The architecture decision and the modified CLI contracts pass the checks above.
The parity baseline allows documented Apple implementation forks; its success
does not assert one shared implementation or full behavioral equivalence.

Current Android Kotlin/Gradle tests, real-device interop and comparative
throughput/latency/power measurements were not rerun. The source/fixture review
provides no evidence requiring a Kotlin-to-Rust rewrite and no universal
performance ranking between those languages.

Windows product-runtime connection, Android's missing app-side debug bridge,
and iOS app-owned automation integration remain separate implementation work.
The existing signed-app/real-peer release gates remain open until their own
candidate-bound evidence is produced. No app credentials, persistent trust,
device pairings or installed runtime were modified by this work.
