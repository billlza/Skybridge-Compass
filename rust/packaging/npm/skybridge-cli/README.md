# skybridge-cli

Thin npm wrapper for the signed Rust `skybridge` binary.

## Install surfaces

- macOS
  - supported through npm and Homebrew
- Linux
  - supported through npm
- Windows
  - supported through npm

## Environment overrides

- `SKYBRIDGE_NPM_BASE_URL`
  - override the release asset base URL
- `SKYBRIDGE_NPM_SKIP_DOWNLOAD=1`
  - skip downloading during `postinstall`
- `SKYBRIDGE_NPM_SKIP_CHECKSUM=1`
  - bypass `SHA256SUMS.txt` verification

## Release asset contract

The package expects a GitHub-style release layout:

- `skybridge-aarch64-apple-darwin.tar.gz`
- `skybridge-x86_64-apple-darwin.tar.gz`
- `skybridge-aarch64-unknown-linux-gnu.tar.gz`
- `skybridge-x86_64-unknown-linux-gnu.tar.gz`
- `skybridge-x86_64-pc-windows-msvc.zip`
- `SHA256SUMS.txt`
