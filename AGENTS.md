# AGENTS.md — Skybridge-Compass (native core + Windows client)

## Scope
These instructions apply to the entire repository. More specific `AGENTS.md` files (if added later) override rules in their subtree.

## Environment facts
- OS: Linux
- Available: Rust + `cargo`
- Not available: .NET SDK / WinUI / MSVC / other GUI toolchains
- Do **not** run Windows-only build tools here.

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
- Treat as text-only scaffolding; do **not** run `dotnet`/`msbuild` commands in this environment.
- Target WinUI 3 + .NET 9 (or `net8.0` if explicitly requested). Keep bindings ready for future Rust FFI integration.

## Web dashboard
- Do **not** modify `web-dashboard/` unless the task explicitly mentions it (e.g., React/TypeScript/frontend/web-dashboard).
