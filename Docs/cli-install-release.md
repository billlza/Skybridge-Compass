# CLI Install and Release

## Distribution Policy

Rust binaries remain the source of truth.
Package managers must download the exact same signed release artifacts instead of rebuilding the protocol core.

Supported install surfaces for v1:

- macOS
  - Apple Silicon only
  - signed official binary archive
  - Homebrew formula
  - npm wrapper
- Linux
  - signed official binary archive
  - npm wrapper
- Windows
  - signed official binary archive / zip
  - npm wrapper

The npm wrapper is a thin downloader / launcher only.
It must not become the only delivery path for the protocol core.

## Current Rust Workspace

The headless workspace lives under `rust/`.

Local build and test:

```bash
cargo test --manifest-path rust/Cargo.toml
cargo run --manifest-path rust/Cargo.toml -p skybridge -- version
```

Current runtime configuration comes from environment variables:

- Nebula OAuth
  - `NEBULA_BASE_URL`
  - `NEBULA_CLIENT_ID`
  - optional `SKYBRIDGE_OAUTH_REDIRECT_URI`
- SkyBridge signaling/control plane
  - `SKYBRIDGE_SIGNALING_SERVER_URL`
  - optional `SKYBRIDGE_CLIENT_API_KEY`
  - optional `SKYBRIDGE_TENANT_ID`

## State Directory Layout

The agent owns one state root:

- `identity/device.json`
- `identity/protocol-signing-key.json`
- `identity/auth-session.json`
- `runtime/health.json`
- `runtime/sessions.json`
- `logs/agent.log`

Every persisted file carries a schema version.

## Local Protection Rules

- state directories are created with restricted permissions
- sensitive values must not be written to ordinary logs
- incompatible schema versions are a migration event, not a silent best effort

## Release Checklist

- build `skybridge` for supported targets
- publish checksums
- publish support matrix
- publish minimum compatible service/backend version
- verify clean install on macOS, Linux, and Windows
- verify upgrade from previous state schema
- verify uninstall guidance does not leave sensitive identity material behind

## Release Asset Contract

Release assets should use one stable naming contract so Homebrew and npm can consume the same binaries:

- `skybridge-aarch64-apple-darwin.tar.gz`
- `skybridge-aarch64-unknown-linux-gnu.tar.gz`
- `skybridge-x86_64-unknown-linux-gnu.tar.gz`
- `skybridge-x86_64-pc-windows-msvc.zip`
- `SHA256SUMS.txt`

Archive contract:

- archive root contains exactly one runnable CLI binary named `skybridge` or `skybridge.exe`
- the binary must print the same `skybridge version` payload regardless of install surface
- package-manager installers must verify checksums before exposing the binary

The release tag should stay stable:

- `skybridge-cli-v<version>`

## Homebrew Expectations

The Homebrew install and the raw binary install must produce the same:

- binary versions
- state directory layout
- schema versions
- default CLI behavior

If they diverge, the release is blocked.

Repository assets:

- formula template
  - `rust/packaging/homebrew/skybridge.rb.template`
- formula render helper
  - `rust/scripts/render_homebrew_formula.sh`
- release asset assembler
  - `rust/scripts/assemble_release_assets.sh`
- single-target archive builder
  - `rust/scripts/build_release_artifact.sh`
- npm staging helper
  - `rust/scripts/prepare_npm_package.py`
- workspace version reader
  - `rust/scripts/workspace_version.py`

## Rollback

Every release candidate must have a rehearsed rollback:

- previous binary still available
- previous Homebrew formula tap or version reference available
- local state migration strategy documented
- incompatible migration guarded before release

## Supported Matrix For v1

Release target:

- macOS
- Linux
- Windows via npm wrapper + binary archive

Repository assets:

- npm wrapper package
  - `rust/packaging/npm/skybridge-cli/`

The npm package downloads the matching platform archive during `postinstall`, verifies `SHA256SUMS.txt`, and then launches the installed binary through a thin `bin/skybridge.js` shim.

Optional Homebrew tap publisher:

- `rust/scripts/publish_homebrew_formula.sh`
- release workflow activates it only when these are configured:
  - `HOMEBREW_TAP_GITHUB_TOKEN` secret
  - `HOMEBREW_TAP_REPOSITORY` repository variable
  - optional `HOMEBREW_TAP_FORMULA_PATH` repository variable
  - optional `HOMEBREW_TAP_BRANCH` repository variable

## CI Workflows

- packaging validation
  - `.github/workflows/skybridge-cli-packaging.yml`
  - runs on push / pull request
  - checks Rust formatting, session tests, CLI compile, npm wrapper script syntax, single-target release build, npm staging, and Homebrew formula rendering
- release build
  - `.github/workflows/skybridge-cli-release.yml`
  - `workflow_dispatch` performs a dry-run artifact build and uploads the assembled release bundle as a workflow artifact
  - pushing a `skybridge-cli-v<version>` tag performs the full release flow:
    - builds all supported release archives
    - writes `SHA256SUMS.txt`
    - writes `release-manifest.json`
    - renders `skybridge.rb`
    - packs the npm wrapper tarball
    - uploads assets to the GitHub release
    - publishes the npm wrapper if `NPM_TOKEN` is configured
    - publishes the Homebrew formula into the configured tap if the tap secret/variables are configured
