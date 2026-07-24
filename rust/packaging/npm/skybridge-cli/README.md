# skybridge-cli

Thin npm wrapper for the signed Rust `skybridge` binary.

## Install surfaces

- macOS
  - Apple Silicon only
  - supported through npm and Homebrew
- Linux
  - supported through npm
- Windows
  - supported through npm

## Environment overrides

- `SKYBRIDGE_NPM_BASE_URL`
  - override the HTTPS release asset base URL

Every installation downloads and verifies `SHA256SUMS.txt`. Checksum verification
cannot be disabled, redirects are bounded, and HTTPS downgrade is rejected.

## Release asset contract

The package expects a GitHub-style release layout:

- `skybridge-aarch64-apple-darwin.tar.gz`
- `skybridge-aarch64-unknown-linux-gnu.tar.gz`
- `skybridge-x86_64-unknown-linux-gnu.tar.gz`
- `skybridge-x86_64-pc-windows-msvc.zip`
- `SHA256SUMS.txt`
