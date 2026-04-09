# Ubuntu Portability Status

## Snapshot

- Branch: `Bill/ubuntu-portability`
- Import scope: Rust workspace crates, packaging assets, docs, scripts, vendored dependencies
- Validation performed before import:
  - `cargo build --workspace`

## Capability status

| Area | Status | Notes |
| --- | --- | --- |
| Workspace build | Ready | Workspace build succeeds on the imported branch snapshot. |
| GTK/libadwaita UI | Implemented | `skybridge-ui` and `skybridge-app` are present. |
| Device discovery | Implemented | `skybridge-core/src/discovery` is included. |
| File transfer | Implemented | `skybridge-core/src/transfer` is included. |
| Remote desktop | Implemented | `skybridge-core/src/remote` and Linux capture/input paths are present. |
| WebRTC / signaling | Implemented | `skybridge-core/src/webrtc` is included. |
| PQC / crypto | Implemented | `skybridge-core/src/crypto` is included. |
| Packaging | Implemented | Linux packaging assets and service templates are included. |
| Production readiness | Partial | This branch is intended as a portability snapshot / backup, not a polished release branch. |

## De-localization work completed

- Removed the one observed Rust warning before import
- Kept `.remote-sync`, build outputs, and cache files out of version control
- Replaced import notes with branch-generic wording instead of workstation-specific paths
