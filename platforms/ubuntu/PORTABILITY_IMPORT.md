Ubuntu portability snapshot imported into `Bill/ubuntu-portability`.

Source:
- External Ubuntu workspace snapshot imported into the repository under `platforms/ubuntu`

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
