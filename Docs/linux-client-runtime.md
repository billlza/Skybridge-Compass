# Linux client runtime

The public Linux client is the `rust/` workspace's `skybridge` binary. The
native agent owns its identity, state, session admission and file-transfer
receipts. `skybridge tui` presents those existing operations interactively;
it does not create another credential store or emulate a running Mac app.

## Implemented surface

| Operation | Linux behavior |
| --- | --- |
| Guided terminal | `tui` offers agent lifecycle, account status/login, discovery, connection codes, sessions, file send/approval/history, diagnostics and logs. Mutations require an explicit `yes`; cancelled inputs do not dispatch. |
| Agent run | Foreground native runtime, exclusive state lock, existing SIGINT/SIGTERM cleanup. `--no-discovery-scan` disables background browsing; scan interval/window have bounded options. |
| Agent status | `agent status --json` succeeds only for the current lock-bound, healthy, fresh runtime. It exposes the runtime `instance_id` and PID. |
| Agent stop | Linux pidfd binds SIGTERM and exit observation to one process. `--instance-id` rejects a replacement runtime. Requires Linux 5.10+; no numeric-PID fallback, escalation or automatic retry. A degraded but fresh, correctly bound runtime can be stopped. |
| Discovery | Existing bounded `mdns-sd` browsing. Advertisements are unverified candidates and do not authorize a connection. |
| Sessions / files | Existing native signaling/WebRTC and authenticated file protocol. File send waits for a matching receipt unless `--detach` is explicit. Inbound file decisions remain agent-owned. |
| User service | `rust/packaging/linux/skybridge-agent.service` runs the same binary as a systemd user service. A running service process alone does not prove a healthy agent. |

Examples (use the same state directory for every command):

```sh
skybridge --state-dir /path/to/private-state agent run --no-discovery-scan
skybridge --state-dir /path/to/private-state agent status --json
skybridge --state-dir /path/to/private-state tui
skybridge --state-dir /path/to/private-state agent stop --instance-id INSTANCE --json
```

`agent stop` reports `process_exited` separately from `cleanup_verified`.
It cannot collect the exit status of an unrelated process, and does not claim
that all session cleanup succeeded just because the process exited. Inspect
the agent log for cleanup failures. A timeout is a failed command whose SIGTERM
may still be in progress. It never authorizes stopping a newer incarnation.

For a desktop machine, place the binary at `~/.local/bin/skybridge`, copy the
provided unit into `~/.config/systemd/user/`, and run `systemctl --user
daemon-reload` followed by `systemctl --user enable --now skybridge-agent`.
If the binary lives elsewhere, edit `ExecStart` to its actual absolute path.
Optional service environment belongs in `~/.config/skybridge/agent.env` with
owner-only permissions. The state directory and protocol identity are shared
with normal CLI commands. Use `agent status --json` to check readiness and
`systemctl --user stop skybridge-agent` for a service-managed stop. Do not start
a persistent user service on a shared HPC login node: use the scheduler there.

## Toolchain and dependencies

Checked on 2026-11-11: Rust stable 1.99.1 is pinned in `rust-toolchain.toml` and
both CLI workflows. The workspace uses the Rust 2024 edition, resolver 3 and
Rust 1.99 minimum metadata. The 43 direct registry dependencies (including the
Linux-only rustix 1.1.6 process API) match their latest non-yanked stable versions
at the check time. The checked-in lockfile remains authoritative for builds.

Three transitive constraints still prevent newer compatible releases:

| Locked dependency | Owning constraint |
| --- | --- |
| cc 1.2.67 | The pinned optional Q-Periapt source requires `=1.2.67` in q-periapt-mlkem-native-sys as part of its qualification inputs. Cargo resolves optional path manifests too. |
| generic-array 0.14.7 | crypto-common 0.1.7 pins `=0.14.7`. |
| matchit 0.8.4 | axum 0.8.9 pins `=0.8.4`. |

The Q-Periapt feature remains default-off with its existing ABI compatibility
gate. This update does not bypass its security qualification or enable an
unsupported feature combination. Existing rtc and askama_derive vendor patches
are retained. Rust 1.99 Clippy changes are handled in source, not suppressed.

## Verification and boundaries

The packaging workflow defines native Ubuntu x86_64 and ARM64 jobs. Each runs
workspace tests, strict Clippy, formatting, dependency audit, FFI binding
generation and release contracts. Both the packaging and release workflows run
`rust/scripts/verify_linux_runtime.py` against the **extracted release binary**.
The result includes its SHA-256 and the executable's version/profile, plus the
specific checks performed. A failed rerun overwrites any stale success receipt.

The runtime check uses real processes and a pseudoterminal. It covers exclusive
startup, permissions, live status, explicit menu cancellation, SIGTERM cleanup,
stale health, identity-preserving restart, stale-incarnation stop rejection,
degraded-runtime shutdown and foreground-menu SIGINT handling. It uses private
temporary state and does not contact a production account backend.

The following Mac capabilities are **not implemented by this change**:

- A Linux desktop application, screen capture/encoding/viewing, remote keyboard
  and mouse authority, or native audio capture/playback.
- Mac's app-owned `crossnet-control/1` settings, trust, handshake and USB
  management surfaces. Making their parser visible would not supply a Linux
  owner for those operations.
- The ADR-0001 native Linux Avahi/QUIC path. Existing discovery and WebRTC
  transport are not evidence of that separate transport implementation.
- Current-source Linux-to-Mac file/media/USB interoperability and device
  acceptance. Local protocol tests and same-node WebRTC loopback do not prove it.

NCC can run GUI programs via X11 forwarding and `srun --x11`, as documented in
its [internal cheatsheet](http://ncc.clients.dur.ac.uk/cheatsheet/#running-an-interactive-matlab-job-with-gui).
A batch job without DISPLAY does not establish that an account lacks graphical
access. An X11-forwarded application is also distinct from a Linux compositor,
an attached audio device, USB hardware or a validated SkyBridge desktop backend.
NCC acceptance records must identify the actual node, kernel, source snapshot,
binary and tested boundary; graphical or media claims need their own evidence.
