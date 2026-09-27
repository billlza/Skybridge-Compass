# Public CLI 0.3.3 Windows app adapter — development validation

Date: 2026-09-13. Implementation changed; Windows native validation is incomplete.
This continues 0.3.2's investigation of non-controlling commands and false success.
The Windows Core diagnostic CLI remains 0.1.1 and is not substituted for the
public CLI.

## Implemented path

`skybridge app` selects an actual Windows App PID and verifies the pipe server
PID before sending bounded NDJSON. It then invokes the server owned by the
existing WinUI MainWindow. The handler reuses the window's SettingsService and
WindowsDeviceWorkspace. There is no new request registry or parallel runtime.

| Command | Claimed completion |
| --- | --- |
| `app instances` | Process discovery only; no pipe readiness claim |
| `app status` | Actual selected app's host/settings projection |
| `app settings` | Current appearance preference, window effect and stored value agree |
| `app settings set appearance.mode system/light/dark` | Existing UI setting applied, window theme observed, store reloaded, then a second CLI readback agrees |
| `app remote-desktop interfaces` | Current host interface choices, with opaque references |
| `app remote-desktop start --interface-ref …` | Existing host listener enabled, independently observed; no peer/first-frame proof |
| `app remote-desktop stop --generation …` | Exact-generation host cleanup completed and independently observed stopped |

The client refuses ambiguous App discovery, wrong pipe PID, protocol/request-ID
mismatch, malformed/oversized responses, missing method capabilities, contradictory
settings and unsuccessful host states. Default operations remain bounded to a
30-second command deadline; a possibly written mutation is never automatically
replayed. Explicit failure and unconfirmed outcome remain machine-readable.

Windows pipe creation uses an explicit current-user SID ACL, first-instance
ownership and native `PIPE_REJECT_REMOTE_CLIENTS`; same-account remote SMB access
must not become local operator access. The Windows native enforcement has not
been executed on this candidate. See the Windows repository's
`docs/windows-app-operator.md` for the protocol, command examples and native gates.

Live FPS/resolution setters remain unimplemented. The Windows settings properties
only persist preferences; actual capture configuration belongs to the authenticated
viewer transaction and matching acknowledgement. This iteration does not relabel
those preference writes as video control.

## Defects found and repaired during implementation

1. UI action wrappers can catch errors and return normally. The operator invokes
   the real service methods and checks results instead of trusting a UI Task's
   successful completion.
2. The first dispatcher implementation stopped waiting on timeout while its UI
   callback could later start a host. Queued cancellation now prevents execution;
   started commands retain ownership until actual work and cleanup complete.
   Start preparation receives the cancellation token and checks it before commit.
3. The first UI synchronization assigned the new status before calculating the
   connected/approval-notice transition. Both paths now share the state-application
   method, preserving the old status until transition calculation; retired host
   events cannot restore a stopped host's presentation.
4. An explicit settings save could race an older debounce snapshot. Both writes
   now hold the existing synchronization lock through snapshot and store access.
   A successful write echo cannot replace independent store readback.
   Untrusted/corrupt loaded settings cannot be implicitly recovered by an operator
   write; the App must resolve that state explicitly.
5. Initial Rust result validation accepted arbitrary host-state text and did not
   preflight each mutation. State consistency, exact capabilities and independent
   readback now gate success. The metadata check was extended for the Windows
   native-pipe proof requirement; it retains the existing Mac socket requirement.

These were source-review findings and regression targets. No claim is made that
the uncorrected Windows App was run to reproduce them on the physical desktop.

## Verification record

Evidence directory:
`Artifacts/windows-app-cli-sc0c_nx9`.

- The public CLI's format, strict Clippy, regression and Windows-target check
  results are recorded in the final verification section below.
- The managed ContractTests project compiled on macOS with warnings as errors.
  The full run with the current macOS Core produced 260 passing cases. Its Core
  binding and [full output](../Artifacts/windows-app-cli-sc0c_nx9/managed-full-tests-r2.log)
  are retained. This includes the six operator cases present in that build.
- After adding the shutdown regression and explicit native pipe creation,
  the project again compiled with zero warnings/errors and the
  [seven focused operator cases](../Artifacts/windows-app-cli-sc0c_nx9/managed-app-operator-final-r4.log)
  passed: malformed/duplicate envelope rejection, framing limits, independent
  stored-value readback, pipe recovery, queued cancellation, active cancellation
  ownership and shutdown cleanup. These overlap the full suite; do not sum the
  two counts as distinct tests. The Windows ACL/Win32 branch is not exercised by
  a macOS named-pipe test.
- Initial attempts are retained: the first pipe test exceeded macOS Unix-socket
  path length (test name shortened while retaining the full random UUID); the
  first full managed run lacked the Core dylib, then succeeded after building
  and copying the actual current macOS Core. No placeholder library was used.
- The first CLI full run had 348 passes and one metadata failure: a new pending
  Windows capability did not name its missing live proof. The retry preserves
  the failure and requires Windows-native pipe evidence rather than borrowing a
  Mac proof string.

The [current Windows operator source hashes](../Artifacts/windows-app-cli-sc0c_nx9/windows-final-selected-source.json)
identify selected files only, not a complete accepted product candidate.

### Final verification

Public CLI 0.3.3: **349 unit + 11 JSON process tests = 360**, all passed with
zero ignored. Format and strict Clippy passed. The unchanged Mac app client also
passed **28** regression tests. The [CLI command/result manifest](../Artifacts/windows-app-cli-sc0c_nx9/cli-validation-0.3.3-retry1.json)
contains exact commands and logs; [Mac client output](../Artifacts/windows-app-cli-sc0c_nx9/mac-crossnet-regression.log)
is separate. Workspace tag/version validation returned 0.3.3.

The complete Windows Rust target check **failed** on macOS: `ring` and
`aws-lc-sys` require Windows SDK C headers absent from the cross-toolchain. It did
not reach the full CLI. The [complete failure log](../Artifacts/windows-app-cli-sc0c_nx9/cli-windows-target-check-0.3.3.log)
is retained and cannot be called a successful Windows build.

The actual Windows-only client production modules separately passed strict
Clippy/typechecking for `x86_64-pc-windows-msvc` in an isolated dependency graph,
with direct references to the real source and no replacement implementations.
The [bounded typecheck record](../Artifacts/windows-app-cli-sc0c_nx9/cli-windows-adapter-typecheck-0.3.3-retry2.json)
includes source hashes and explicitly leaves full Windows build and runtime
verification false. The harness's two initial setup failures are also retained.

The managed RuntimeSmoke Windows-target project compiled on macOS with
`EnableWindowsTargeting=true`, warnings as errors and zero warnings/errors.
The initial command without that required cross-target flag failed NETSDK1100;
both attempts are retained. This is a managed compile result only: the
Windows-only native Core build target does not execute on macOS, and no Windows
runtime execution is established by this check. [Cross-build output](../Artifacts/windows-app-cli-sc0c_nx9/managed-runtime-smoke-cross-build.log).

## Actual Windows attempt and remaining blocker

The current SSH target was found from existing local records and LAN observations.
The connection succeeded with the previously pinned Windows host key. The remote
host reported Windows 10.0.26200, .NET SDK 10.0.302 in the existing user toolchain,
and an already running Skybridge.WinClient in desktop session 2.

The 519-file, independently hashed source snapshot was staged in a new directory.
The actual repository App build was invoked with warnings as errors, the real
NativeCore.targets and the locked dependency graph. It failed before managed
App compilation: Windows Code Integrity event **3077** rejected
`serde_core`'s `build-script-build.exe`; Cargo reported OS error **4551**.
The [native build log](../Artifacts/windows-app-cli-sc0c_nx9/windows-r1-build-app.log)
and [Code Integrity events](../Artifacts/windows-app-cli-sc0c_nx9/windows-r1-code-integrity-failure.json)
are preserved. This first source snapshot predates the later review fixes and
cannot validate the final source.

Read-only inspection found zero current-user certificates with both a private
key and code-signing EKU. No signing credential was created, no trust/security
policy was changed, and the native build target was not skipped. The installed
App was not replaced or used to pretend that the new endpoint already exists.

Before completion, this still needs a trusted Windows build and real desktop
execution: pipe identity/ACL/locality enforcement; settings write/readback and
restoration; existing-identity host start/stop; stale generation refusal; delayed
operation cancellation; and App shutdown with an active command. The broader
Windows documentation gate's pre-existing historical-phrase mismatch and the
90% coverage gate also remain unpassed for this development candidate. Signing,
installation, update, publication and cross-device media are not accepted.
