# SkyBridge Compass Ubuntu

> Portability branch snapshot: `Bill/ubuntu-portability`
>
> Branch-specific references:
> - [BUILD.md](BUILD.md)
> - [STATUS.md](STATUS.md)
> - [PORTABILITY_IMPORT.md](PORTABILITY_IMPORT.md)

A cross-platform P2P file transfer and remote desktop application for Ubuntu Linux, compatible with SkyBridge Compass on macOS and Android.

## Features

- **Cross-platform device discovery** via mDNS/Bonjour
- **Secure P2P connections** with post-quantum cryptography support
- **File transfer** with resumption, compression, and multi-threading
- **Remote desktop** via VNC protocol
- **Unified login** compatible with macOS/Android apps

## Architecture

```
SkyBridge Compass Ubuntu/
├── skybridge-core/       # Core library
│   ├── auth/            # Authentication & NebulaID generation
│   ├── crypto/          # Cryptographic providers (Ed25519, ML-DSA-65, X25519, ML-KEM, AES-GCM)
│   ├── discovery/       # mDNS device discovery
│   ├── p2p/             # P2P connection & handshake protocol
│   ├── transfer/        # File transfer engine
│   └── remote/          # Remote desktop (VNC)
├── skybridge-ui/        # GTK4/Adwaita UI components
└── skybridge-app/       # Main application
```

## Requirements

- Ubuntu 22.04+ or compatible Linux distribution
- Rust 1.92+
- GTK4 4.14+
- libadwaita 1.5+

### System Dependencies

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y \
  build-essential cmake pkg-config curl git \
  libgtk-4-dev libadwaita-1-dev libssl-dev

# Fedora
sudo dnf install gcc gcc-c++ make cmake pkgconf-pkg-config git curl \
  gtk4-devel libadwaita-devel openssl-devel

# Arch Linux
sudo pacman -S base-devel cmake pkgconf git curl gtk4 libadwaita openssl
```

## Building

```bash
# Clone and build
cd "SkyBridge Compass Ubuntu"
cargo build --release

# Run
cargo run --release -p skybridge-app
```

For Ubuntu `--all-features` checks or the optional Linux HEVC remote-desktop path,
install the extra FFmpeg and Clang development packages:

```bash
sudo apt install -y \
  libavutil-dev libavcodec-dev libswscale-dev \
  clang libclang-dev
```

### Native Ubuntu Server Build

If you have an Ubuntu server available, native Linux builds are the recommended path.
Cross-compiling this workspace from macOS requires an extra Linux toolchain, Linux `pkg-config`
sysroot, and target C compiler because dependencies such as `ring`, `pqcrypto-*`, `glib-sys`,
`gtk4`, and `libadwaita` compile target-specific native code.

```bash
sudo apt update
sudo apt install -y \
  build-essential cmake pkg-config curl git \
  libgtk-4-dev libadwaita-1-dev libssl-dev

sudo apt install -y \
  libavutil-dev libavcodec-dev libswscale-dev \
  clang libclang-dev

curl https://sh.rustup.rs -sSf | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install stable
rustup default stable

git clone <your-repo-url> skybridge-compass-ubuntu
cd skybridge-compass-ubuntu

cargo check --workspace --all-features
cargo test --workspace --all-features
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo build --release --workspace --all-features
```

### Headless Server Caveat

- A headless Ubuntu server can build the project and run static checks just fine.
- The desktop application, screen capture, remote input, tray integration, and visual parity work
  require a graphical session (`X11` or `Wayland` + `xdg-desktop-portal`).
- For CI or artifact builds, a server is enough.
- For end-to-end discovery, file transfer, and remote desktop validation, use a real Ubuntu desktop
  machine or a VM with a desktop environment.

### Cloud terminal profile

For hardened GPU-backed Wayland terminals, use the dedicated user-service and
bootstrap flow documented in [docs/cloud-terminal/README.md](docs/cloud-terminal/README.md).
That guide now covers bootstrap, post-bootstrap runtime validation, GNOME power
hardening, the golden AMI version manifest, and the relay-only production
deployment profile. The example service unit lives at
`packaging/linux/systemd/user/skybridge-compass.service`, and the example
runtime config lives at `packaging/linux/production.toml.example`.

## Cryptographic Suites

The application supports multiple cryptographic suites for secure communication:

| Suite | KEM | AEAD | Signature | Type |
|-------|-----|------|-----------|------|
| X-Wing + AES-256-GCM + ML-DSA-65 | X25519 + ML-KEM-768 | AES-256-GCM | ML-DSA-65 | Hybrid PQC |
| ML-KEM-768 + AES-256-GCM + ML-DSA-65 | ML-KEM-768 | AES-256-GCM | ML-DSA-65 | Pure PQC |
| X25519 + AES-256-GCM + Ed25519 | X25519 | AES-256-GCM | Ed25519 | Classic |
| X25519 + ChaCha20-Poly1305 + Ed25519 | X25519 | ChaCha20-Poly1305 | Ed25519 | Classic |

## NebulaID Format

Device and user IDs use a Snowflake-based distributed ID system:

```
NEBULA-{year}-{base36_id}
Example: NEBULA-2025-A1B2C3D4E5F6
```

Bit structure (64-bit):
- Timestamp: 41 bits (69 years from epoch)
- Datacenter ID: 5 bits (32 datacenters)
- Worker ID: 5 bits (32 workers)
- Sequence: 12 bits (4096 IDs/ms)

## Protocol Compatibility

This Ubuntu snapshot is designed for protocol compatibility with:
- SkyBridge Compass Pro (macOS)
- SkyBridge Compass (Android)

Interop status is still evolving; see [STATUS.md](STATUS.md) for the current
validation boundary between static checks, runtime interop, and UI parity.

All platforms use:
- Same handshake protocol
- Same NebulaID generation algorithm
- Same mDNS service types (`_skybridge._tcp`, `_skybridge._udp`)
- Same cryptographic suites

## License

Repository licensing is inherited from the parent codebase. Add or align a
top-level license file before treating this branch as a standalone distribution.
