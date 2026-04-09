# SkyBridge Mac Baseline (Latest Mainline)

This directory captures the Ubuntu compatibility baseline against the latest SkyBridge Mac behavior.

## Baseline metadata

- Baseline platform: SkyBridge Mac mainline (latest available at sync time)
- Ubuntu sync date: 2026-03-04
- Purpose: lock Ubuntu↔Mac wire compatibility and UI behavior parity in one delivery track

## Layout

- `protocol-samples/`: normalized protocol payload samples used for Ubuntu↔Mac wire-compat checks.
- `ui-baseline/`: UI capture checklist and visual parity notes used by screenshot diff gates.
- `behavior-checklist.md`: end-to-end behavior matrix for discovery, handshake, transfer, and remote desktop.

## Baseline update policy

1. Refresh whenever Mac mainline protocol/UI changes.
2. Record update date and source commit/release tag.
3. Keep previous snapshots in Git history; do not overwrite evidence without changelog entries.
4. If Mac introduces new aliases/fields, add them to protocol samples and update parser compatibility tests.

## Verification usage

- Protocol compatibility tests load payloads from `protocol-samples/`.
- UI parity checks compare fixed-size screenshots against the checklist in `ui-baseline/`.
- Quality issue closure state is tracked in `/docs/quality-issue-ledger.md`.
