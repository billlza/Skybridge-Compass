# Ubuntu Build Guide

This branch stores the Ubuntu portability snapshot under `platforms/ubuntu`.

## Supported baseline

- Branch: `Bill/ubuntu-portability`
- Preferred validation command:

```bash
cd platforms/ubuntu
cargo build --workspace
```

- Expanded verification command:

```bash
cd platforms/ubuntu
cargo build --release --workspace --all-features
```

## System dependencies

See the package lists in [README.md](README.md). At minimum you need Rust, GTK4,
libadwaita, OpenSSL, and a working native Linux toolchain.

## Version-control exclusions

The portability branch intentionally excludes:

- `.remote-sync`
- `target/`
- `build/`
- Python cache files and log files

Vendored dependencies under `vendor/` are intentionally preserved when they are
required by the workspace.
