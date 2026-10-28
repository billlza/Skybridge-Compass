# ADR-0003: Native runtime ownership and the operator contract

**Status:** Accepted architecture and command contract; runtime and release acceptance remain separate

**Date:** 2026-09-13

**Scope:** macOS, Windows, Android, iOS/iPadOS; Linux is deferred for this workstream

**Related decisions:** [ADR-0001](ADR-0001-SkyBridge-Core-Transport-Matrix.md),
[ADR-0002](ADR-0002-Remote-Control-Authority-and-Sessions.md),
[CLI scope](cli-scope-v1.md), [core layering](CoreLayering.md)

## Context and decision precedence

Platform-specific implementations are intentional. Apple uses Swift and its
platform APIs; Windows has a Rust core and WinUI shell; Android has working
Kotlin protocol/runtime modules and native JNI providers. A common contract does
not require a common implementation language.

This decision supersedes ADR-0001 version 1.1's Android Rust-core mandate.
ADR-0001 version 1.2 incorporates the amendment. Android's accepted
`ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md` owns Kotlin runtime/module selection;
its decisions 6–7 about Q suite/auth profiles were superseded by
`ADR-2026-09-06-QPERIAPT-ABI2.md`. Android's
`ADR-2026-07-23-PEER-FAMILY-PROTOCOL-LANES.md` owns Android lane selection and
Apple-compatible behavior. ADR-0002 continues to own identity, local approval,
input ownership and exact-session isolation. None of these is superseded by CLI
or transport convenience.

Mac CLI scope contained both pre-implementation restrictions and later enabled
handlers. Commit `23841eed` (2026-08-26) introduced the session-plane update, but
left earlier disabled-state prose in the document. Current implementation status
must describe the current code and installed-app capability negotiation, while
old results remain tied to their original candidate. A later successful receipt
does not retrospectively turn a failed or unbound attempt into success.

## Runtime ownership

| Platform | Owner of app state, protocol and lifecycle | Operator integration |
| --- | --- | --- |
| macOS | Existing Swift app, Keychain, session and transport managers | Rust CLI through authenticated app-owned local IPC |
| Windows | Existing Rust Core and Windows app services | Public CLI adapter to the Windows product runtime when implemented; existing core diagnostic CLI remains explicitly diagnostic |
| Android | Existing Kotlin `shared`, `core`, discovery, transfer, remote-control and app modules; narrow native JNI providers | App-owned authorized actions; desktop ADB tooling is a development surface |
| iOS/iPadOS | Existing Swift app and shared Apple protocol products | App Intents/Shortcuts or an explicitly scoped app-owned action interface; no terminal-hosted runtime required |

Do not add a second Android SkyBridge Rust runtime just to share the CLI language.
An existing vendor library implemented in native code does not create a second
SkyBridge app runtime. Retain the JNI boundary required by the accepted provider.

CLI and future MCP adapters dispatch bounded control requests to the owner of
the selected runtime. They do not copy app credentials, create parallel trust
stores or substitute a headless session for the GUI session the user selected.
Mobile actions obey platform lifecycle and permission restrictions. Xcode and
ADB are development/validation tools, not prerequisites for the intended novice
user experience. App Intents does not automatically give an arbitrary external
agent permission to operate the app; client integration and authorization are
separate work.

## Public CLI and diagnostic compatibility

The `rust/` workspace is the canonical public `skybridge` CLI distribution for
macOS and Windows. It already has a Windows compilation lane. Do not replace
Windows native services with the headless Rust agent to claim GUI integration.

The Windows repository's `core/skybridge-core` CLI is an independently built
protocol-diagnostic interface. Its existing binary name is retained for local
scripts; it must not be silently substituted for the public CLI archive or
installed over that command. Naming/package migration requires its own consumer
inventory. This decision does not publish, install or rename existing binaries.

Both implementations expose the same additive `operator_profile` object in
`version --json` and `capabilities --json`:

| Field | Meaning |
| --- | --- |
| `schema_version` | `1`, the profile schema only |
| `implementation_id` | `skybridge-cli` or `skybridge-windows-core-cli` |
| `role` | `product_operator` or `protocol_diagnostics` |
| `host_platform` | Executable target OS (the operator host), independent of the diagnosed peer |
| `app_runtime_control` | `mac_app_runtime`, `windows_app_runtime` or `unsupported`, describing the compiled adapter rather than live readiness |
| `file_send.default_completion` | `verified_receipt` |
| `file_send.default_implemented` | Whether this implementation has the default completion path; not live health or release acceptance |
| `file_send.detached_completion` | `request_registered` |

Existing per-command JSON schema versions remain scoped to their own payloads.
The profile does not assert that every legacy command result is one unified
schema. Consumers first identify the implementation/profile, then inspect
capabilities, runtime readiness and the command-specific result. An older binary
without a profile requires an explicit legacy adapter; its name or a zero exit
code cannot establish the new completion contract.

The public CLI only advertises app-bound commands compiled for its host. On
non-macOS builds, Mac-only `crossnet` capabilities are absent. Unsupported
Windows GUI/mobile operations stay explicit; no fallback to another runtime.

## Completion, cancellation and errors

- Default `file send` succeeds only after a receiver receipt matches the exact
  authenticated transfer, byte count and SHA-256. Request registration is an
  intermediate state.
- `file send --detach` explicitly requests registration-only semantics. Its
  successful exit does not prove agent observation, transfer start or completion.
- The Windows diagnostic CLI cannot wait for a live receipt. Default `file send`
  therefore fails with `windows_file_transfer_completion_not_wired` **before**
  registering a request. `--detach` preserves its existing request-only function.
  Scripts that deliberately registered requests must add `--detach`; scripts
  requiring a completed transfer must use an implemented runtime path.
- Parameter, permission, identity and schema failures remain failures. Waiting
  has a bounded deadline; retries require operation ownership/idempotency, and
  timeout alone does not prove cancellation or permit a duplicate transfer.
- Approval requests, queued operations, applied mutations and verified results
  must stay distinguishable. A mutation must use the existing app/runtime auth
  and read-back boundary. CLI registration does not bypass local approval.
- Keep existing v1 JSON stream conventions documented: the public CLI currently
  emits successful result JSON to stdout and structured failure JSON to stderr;
  progress is not a result. Any future stream/envelope migration needs explicit
  versioning and consumer tests, not silent reformatting.

## 0.3.2 / Windows diagnostic 0.1.1 amendment

Installed-app capabilities are authoritative: unreported and explicitly empty
method lists do not enable mutations. A setting mutation must also match a fresh,
independent app snapshot; effect timing is part of the result. Doctor commands
return nonzero for failed checks while preserving the full diagnostic report.

Windows diagnostic remote-desktop start/stop/set commands require `--detach`
for request registration. Their default fails before registration because no
consumer applies the request to WinUI. Detached stop is not runtime cancellation.
Status options and evidence session filters are validated rather than ignored.
Request history reports each record's current registry binding separately from
its historical result; an expired/replaced session must not appear currently
bound, and legitimate archived records remain readable. Schema and path errors
remain failures. Registration and execution still require strict live admission.

## Public CLI 0.3.3 Windows app adapter

The Windows public CLI adds `app instances/status/settings` and
`app remote-desktop interfaces/start/stop`. Its PID-bound local pipe dispatches
into the existing WinUI MainWindow, SettingsService and WindowsDeviceWorkspace.
Only implemented methods are advertised; `appearance.mode` confirms both the
window effect and persisted readback. Host start is listener readiness; stop
requires the exact host generation and actual cleanup. Incoming peer approval
and input ownership remain app-owned. No live FPS/resolution setter is claimed.

The server serializes actual operations, including cancellation cleanup, and
cancels queued UI actions before they can execute. A client timeout does not
release a started operation's ownership or authorize an automatic replay.
The Windows pipe has a current-user SID ACL and rejects remote pipe clients.
The CLI verifies the server PID before writing. Full protocol details and the
implementation/acceptance distinction are in the Windows repository's
`docs/windows-app-operator.md`.

The Windows Core diagnostic CLI remains diagnostic. The missing app-adapter
source path is now implemented, but native build, real pipe exchange and desktop
runtime acceptance remain pending after a Code Integrity 3077 build rejection.
An accepted architecture decision cannot turn that failed execution gate green.

## Performance and compatibility decision

Keep control requests out of media/transfer hot paths. Do not carry full video
frames or file contents through command-result JSON, duplicate codecs, or add a
per-frame subprocess/IPC round trip. Reuse each runtime's existing streaming,
backpressure, buffer ownership and cancellation mechanisms.

Kotlin is retained because the accepted implementation already has concrete
wire, KDF, receipt and lifecycle contracts. This is a maintainability and boundary
decision, not a claim that Kotlin is universally faster. Android's official
[JNI guidance](https://developer.android.com/ndk/guides/jni-tips) recommends
minimizing marshalling and unnecessary cross-language asynchronous communication.
Apple's [App Intents](https://developer.apple.com/documentation/appintents)
provides an app-owned action integration route.

Pause expansion of the Kotlin route and reassess the responsible boundary if:

1. A reproducible failure of accepted cross-platform wire/security requirements
   cannot be repaired within the existing Kotlin/JNI architecture without
   weakening identity, authorization, integrity or compatibility.
2. Controlled tests using fixed candidates, devices, networks and workloads
   establish that unacceptable throughput, tail latency, power, memory or JNI
   lifecycle behavior is caused by that architectural boundary and cannot be
   addressed locally. Compare against the same agreed budgets and baseline.
3. Interoperability requires maintaining incompatible mandatory protocol lanes
   or relaxing security assertions.

Retain failed cases and compare bounded alternatives, including a targeted
shared/native component, before deciding on a full rewrite. A missing CLI bridge,
an isolated bug, an obsolete suite or an unexecuted device matrix is not evidence
that the implementation language caused an architectural failure.

## Acceptance and current limits

Architecture conformance passes for a named scope when the decision is coherent,
the implementation follows it, and its relevant executable contracts pass.
Platform differences allowed here are not failures. That acceptance does not
substitute for signed installation, current-source device interop or release.

The 2026-09-13 review found matching Android/Apple platform-contract fixture
bytes and matching ABI2 KDF/Finished constructions. Recorded Android-to-Mac file
receipts cover a specific older candidate and direction. Current Kotlin tests,
the complete current-source physical matrix and comparative performance were
not re-run as part of that read-only architecture assessment.

Current CLI gaps remain explicit: Windows diagnostic `connect` is not wired to
the product runtime; Android's desktop debug bridge client has no corresponding
server located in the inspected Android source tree; iOS has no Rust CLI runtime
control target. These are integration work, not permission to report completion.

Validate the profile from both executables, compare its common fields, and run
the command tests on each implementation. A default Windows send must fail
without changing the registry; explicit detached registration must retain its
truthful receipt/observation flags. Preserve Mac app IPC regression tests and
Apple protocol parity. Linux requires separate acceptance when resumed.
