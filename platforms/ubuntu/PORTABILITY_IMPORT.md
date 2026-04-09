Ubuntu portability snapshot imported into `Bill/ubuntu-portability`.

Source:
- `/Users/bill/Desktop/SkyBridge Compass Ubuntu`

Included:
- Rust workspace crates, docs, scripts, packaging assets, vendored dependencies

Excluded:
- `.remote-sync`
- `target/` and `build/` outputs
- Python cache files and log files

Validated before import:
- `cargo build --workspace`

Notes:
- The pre-import warning in `skybridge-app/src/main.rs` was fixed by removing an unused import.
