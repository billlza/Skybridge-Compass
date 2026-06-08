# AGENTS.md — Skybridge-Compass (native core + Windows client)

## Scope
These instructions apply to the entire repository. More specific `AGENTS.md` files (if added later) override rules in their subtree.

## Environment facts
- Execution environment varies by runner. Some agents may only have Rust + `cargo`; the local Windows portability workspace also has PowerShell, .NET, and Windows tooling.
- If .NET SDK / WinUI / MSVC are unavailable, treat `windows/Skybridge.WinClient/` as text-only scaffolding and run the static PowerShell gates that do not require those tools.
- When Windows/.NET tooling is available, prefer the repository smoke scripts under `Scripts/` over ad hoc build commands.

## Rust (`core/skybridge-core/`)
- The Rust core must stay portable (no platform-specific APIs).
- Whenever you touch anything under `core/skybridge-core/`, you **must** run, in this order:
  ```bash
  cd core/skybridge-core
  cargo fmt --all -- --check
  cargo clippy --all-targets --all-features -- -D warnings
  cargo test --workspace
  ```
  All commands must pass before finishing the task.
- Use `cargo` only inside the crate (not at the repo root) unless there is a top-level workspace.

## Windows client (`windows/Skybridge.WinClient/`)
- Target WinUI 3 + .NET 10 with `net10.0-windows10.0.19041.0`, Windows App SDK `2.1.3`, and Windows SDK BuildTools `10.0.28000.1839`.
- Keep bindings ready for Rust FFI integration without moving Core transport, identity, pairing, or AppleNative routing policy into the Windows ViewModel layer.
- Run `Scripts/verify-windows-stack-freshness.ps1` after changing project stack declarations, package versions, or stack documentation.

## Web dashboard
- Do **not** modify `web-dashboard/` unless the task explicitly mentions it (e.g., React/TypeScript/frontend/web-dashboard).
