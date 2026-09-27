# SkyBridge CLI 0.3.2 — control and result integrity

Date: 2026-09-13. Public CLI: 0.3.1 → 0.3.2. Windows Core diagnostic
companion: 0.1.0 → 0.1.1. Existing native runtimes and ADR-0003 remain authoritative.
This is a working-tree development iteration, not publication approval.

## Defect ledger

| ID | Failure condition and cause | Required evidence | Status |
| --- | --- | --- | --- |
| CLI-032-01 | Mac capture FPS/resolution advertised and implemented in the app, but rejected before IPC by the Rust mutation allowlist; mutation response also omits its deferred-effect note | Old rejection; new typed socket round trip; real installed app independently reads back both writes and restores originals | Fixed; live local settings proof passed. Effect is at next capture start, not current video proof |
| CLI-032-02 | Empty/missing installed-app method lists become a full enabled list; readiness uses compile-time constants; tests assert this false readiness | Empty, missing, partial and wrong-method cases; no mutation request sent without method support | Fixed; unsupported/unreported methods fail before mutation IPC; failed preflight exits nonzero |
| CLI-032-03 | Signaling/media doctor prints failing checks then exits successfully; wrapper tests accept the exit | Unreachable/rejected local endpoint gives nonzero exit and one complete structured failure; healthy control-plane fixture still succeeds | Fixed; signaling, media-lease and WebRTC media doctors gate required checks |
| CLI-032-04 | Windows status silently accepts missing, duplicate or unknown options and does not bind an evidence session filter | Strict parser negatives, mutually exclusive sources, matching and mismatching session hash tests | Fixed; parser and process regression tests pass |
| CLI-032-05 | Windows request history claims runtime binding without revalidating the current session/runtime/peer, including unfiltered queries | Per-record unbound reasons for expiry, missing/inactive session, replaced runtime and mismatched peer; preserve legal terminal history without writes | Fixed; the first overstrict repair hid expired history, independently reproduced and corrected before final validation |
| CLI-032-06 | Windows remote-desktop actions enqueue requests with no consumer; pending start can prevent stop without ever controlling the app | Default unsupported before registration; explicitly detached diagnostics remain request-only; cancellation/control not claimed | Default no-op success removed; explicit diagnostic registration remains. Real app control stays open as CLI-032-G1 |
| CLI-032-G1 | Windows has no app-owned CLI IPC; existing helper IPC is private app-to-helper transport | Implement and validate the genuine app-owned control adapter before declaring WinUI control | Open integration gap; not solved by a diagnostic queue |

## Validation boundaries

Use counterexamples that fail against the old implementation. Fixture tests
prove parsing/transport/contract behavior only. Live app acceptance must invoke
the installed app's real runtime, read state independently after the mutation,
and restore temporary settings; bind that evidence to its actual app build.
Do not promote that evidence to another app build or to cross-device media proof.

Windows portable-crate tests on macOS do not establish Windows OS/WinUI control.
An unsupported operation must fail honestly, but that is not the implementation
of the missing control path. Preserve this distinction in the final result.

No Linux or mobile implementation changes are part of this iteration. Do not
change persistent identity, pairing, permission policy or release gates. Retain
existing dirty changes, original failures and bounded retry evidence.

## Recorded result

See [validation and compatibility notes](cli-v0.3.2-validation.md) for commands,
test counts, counterexamples, installed-app identity and retained failed attempts.
This ledger closes the listed contract defects only; it does not claim complete
CLI command coverage, Windows live control, or release acceptance.

Follow-up: [0.3.3 Windows app adapter](cli-v0.3.3-windows-validation.md) implements
the app-owned IPC source for CLI-032-G1. Its first native build was rejected by
Windows Code Integrity; real Windows control acceptance remains open.
