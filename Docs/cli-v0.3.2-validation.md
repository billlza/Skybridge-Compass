# CLI 0.3.2 / Windows diagnostic CLI 0.1.1 validation

Date: 2026-09-13. Development builds in existing dirty worktrees; no commit,
publication, signing or installation is claimed. The versions identify two
implementations under ADR-0003, not interchangeable binaries.

Public CLI base HEAD: `c418fe46bef89267ad4991a19c366ff17beaa609`.
Windows companion base HEAD: `811ba8f71c1a8d19b5c579748f37e96a46855c6f`.
Neither HEAD alone identifies these uncommitted builds. Relevant input hashes
are recorded in the [selected-source manifest](../Artifacts/cli-v0.3.2-7pcij3qw/selected-source-sha256.json);
that manifest is not a complete product candidate manifest.

## Behavior and compatibility

- Mac capture FPS and resolution now reach the existing app mutation handler.
  Every settings write must also agree with a separate settings snapshot;
  matching the mutation response alone cannot produce success. Capture settings
  retain `applies_at_next_capture_start`, including with the installed app that
  supplies that note only in its snapshot. A failed readback does not imply
  rollback; inspect state before deciding whether to retry.
- Installed-app method capabilities now govern mutation preflight. Missing/null
  lists mean unknown, an empty list means none enabled, and partial lists enable
  only the corresponding supported methods. No compile-time default fills the
  gap. A failed `crossnet preflight --json` now exits nonzero and writes its
  structured failure to stderr; callers must inspect exit status.
- Failed required checks in `doctor signaling`, `doctor media-lease` and
  `doctor webrtc-media` now exit nonzero. JSON failure is one stderr document
  containing `error.code=doctor_checks_failed` and the complete nested `report`.
  Healthy report output remains on stdout. `diagnose webrtc-media` remains a
  report command and is not the acceptance gate.
- Windows remote-desktop mutations default to
  `windows_remote_desktop_control_not_wired` with no request write. Only explicit
  `--detach` registers a diagnostic request; this cannot start, stop or configure
  a WinUI runtime. Existing request-only callers must opt in explicitly.
- Windows status rejects ambiguous/missing arguments and verifies a supplied
  session filter against the evidence's `SessionIdSha256`. Request history uses
  per-record current registry binding observations, not constant `true` values.
  Legal expired or orphaned records remain readable with a reason and
  `target_runtime_bound=false`; malformed registries still fail. A missing
  session entry is an observation; an unreadable/missing registry file is an
  error. Live request admission still requires a valid established session.

No external dependency versions were changed by this iteration. Existing
uncommitted dependency and product changes were preserved. Swift, Kotlin,
iOS and Linux product sources were not changed in this iteration.

## Counterexamples and retained failures

The old Mac allowlist rejected `remote_desktop.target_fps` before mutation IPC.
The new focused test failed with `setting_immutable` against that implementation.
The old empty/missing capability test also failed because the implementation
reported ready and enabled all six methods. An initial overly specific test
filter selected zero tests; it was rerun correctly and is not counted as a pass.

The old CLI's actual signaling doctor against `http://127.0.0.1:9` returned exit
0 while reporting eight failed checks. The current process returns nonzero,
empty stdout and one structured failure, retained in
[doctor-unreachable-result.json](../Artifacts/cli-v0.3.2-7pcij3qw/doctor-unreachable-result.json).

The first real Mac settings attempt exposed a second defect: the mutation
response omitted the capture effect note. It failed verification and restored
the settings. That original [failed receipt](../Artifacts/cli-v0.3.2-liyqz3g6/mac-settings-runtime-receipt.json)
and separate [failure context](../Artifacts/cli-v0.3.2-liyqz3g6/failure-context.json)
were preserved. The client was then repaired to obtain independent readback and
effect timing; the retry uses a separate artifact directory.

The first Windows binding repair rejected whole histories when a session
expired. A separate process reproduction showed legal terminal records becoming
unreadable solely after expiry. The final implementation preserves those records
and reports binding separately. A regression covers expired terminal history
mixed with healthy requests. Additional read-only process checks exercised
expiry, missing session entries and four corrupt registry cases, comparing the
registry bytes before and after all twelve queries.

## Installed Mac app acceptance

[Successful runtime receipt](../Artifacts/cli-v0.3.2-7pcij3qw/mac-settings-runtime-receipt.json):

| Operation | Original | Requested and independently observed | Restoration |
| --- | --- | --- | --- |
| Capture FPS | 60 | 30 | 60 |
| Capture resolution | auto | 1920x1080 | auto |
| Invalid FPS | 60 | 45 rejected without state change | Unchanged |

The installed app was idle before probing. Both writes explicitly apply at the
next capture start. App identity: `1.0.2+20260912183814`, executable SHA-256
`5be0422b84d1f5962f0d544b501c0cae3baf66893d00d7a2fedbe6d47c998e82`.
CLI 0.3.2 executable SHA-256:
`e5c1dcf65e11965d8a0c03c8e74cd61efec277d8a71e97419852ef406cc3d7ba`.

This proves real local app settings control and restoration for those exact
bytes. It does not prove active-stream FPS, cross-device media, file delivery,
all CLI mutations, or acceptance of another app build. The artifact contains
the [replay harness](../Artifacts/cli-v0.3.2-7pcij3qw/verify_mac_runtime.py), which
requires an idle app and uses a new result directory and final restoration.

## Executed checks

From the public CLI repository root:

```sh
cargo test --locked --offline --manifest-path rust/Cargo.toml -p skybridge-crossnet-client -p skybridge --all-targets --quiet
cargo fmt --manifest-path rust/Cargo.toml --all -- --check
cargo clippy --locked --offline --manifest-path rust/Cargo.toml -p skybridge -p skybridge-crossnet-client --all-targets -- -D warnings
cargo build --locked --offline --manifest-path rust/Cargo.toml -p skybridge --quiet
python3 -B Scripts/check_protocol_parity.py
python3 -B -m unittest discover -s Scripts -p test_check_protocol_parity.py
python3 rust/scripts/workspace_version.py --expect-tag skybridge-cli-v0.3.2
git diff --check -- rust Docs
```

Passed: 338 CLI unit tests, 11 CLI process tests and 28 client tests (**377**,
zero failed/ignored); format, strict Clippy and build passed. Protocol parity
checked **40 source pairs** against the baseline; **23 checker tests** passed.
Version validation returned 0.3.2. A [test summary](../Artifacts/cli-v0.3.2-7pcij3qw/public-cli-tests-summary.txt)
is retained; complete public test output was recorded locally in
`/var/folders/c7/2dhh484x7m7bg6qkx91_92lm0000gn/T/skybridge-cli-032-9ptrkv3n/cli-attempt-2.log`.

From the Windows repository's `core/skybridge-core`, in required order:

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --workspace
```

All passed: **236 tests** (138 unit, 72 CLI, 15 FFI, 6 ABI2, 3 state-machine,
2 X25519), zero failed/ignored. These outputs were observed in the task's command
results; no independent full Windows test log file was created. The tested
companion binary reports 0.1.1. Its executable SHA-256 is
`85b1ac75a5dd6b28172a50b2e6fc0c819c8f5782e0f446708012e7abe6623bd2`.
The crate executed on macOS; this is not a Windows executable acceptance result.
Relevant Windows source/document `git diff --check` passed.

## Unpassed and unexecuted gates

`pwsh -NoProfile -File Scripts/verify-windows-portability-acceptance-map.ps1`
failed: `Research evidence missing signal: current TDSC mac branch`. The checker
requires that literal historical phrase in `docs/windows-architecture.md`.
Re-running the same checker with both documents restored from the pre-iteration
snapshot in an isolated read-only view produced the identical failure. This is
a pre-existing documentation/checker mismatch, not a passed gate; the checker
was not weakened and the historical assertion was not reintroduced to make it
green. This broader documentation gate remains unresolved.

Native Windows build/WinUI execution, Windows device control, coverage measurement
against the repository's 90% threshold, full platform CI, signing/install/update,
and release approval were not run or established. In particular, there is still
no app-owned Windows operator IPC. Removing default request-only success does
not implement that missing control path. See open item CLI-032-G1 in the
[defect ledger](cli-v0.3.2-plan.md).
