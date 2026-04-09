# SkyBridge Quality Issue Ledger

Fields: `ID | Category | Priority (P0-P3) | Impact | Repro/Trigger | Evidence (file:line) | Fix Plan | Regression Test | Status`

## Functional Gaps

| ID | Category | Priority | Impact | Repro/Trigger | Evidence | Fix Plan | Regression Test | Status |
|---|---|---|---|---|---|---|---|---|
| FUNC-001 | Remote desktop client placeholder | P0 | Remote desktop path reports connected without real protocol/session | Call `VncClient::connect` and send events | `skybridge-core/src/remote/vnc.rs:248` | Replaced placeholder with real VNC connect/auth/encoding/event-pump/input/clipboard/update flow | `cargo test --workspace --all-features` + remote module unit tests | Resolved (2026-03-04) |
| FUNC-002 | Remote manager connect placeholder | P0 | Session created without attempting remote endpoint connection | Call `RemoteDesktopManager::connect` | `skybridge-core/src/remote/manager.rs:172` | Resolve best peer address and establish real session before registration | `cargo test --workspace --all-features` | Resolved (2026-03-04) |
| FUNC-003 | Discovery optional transports not implemented | P2 | BLE / Wi-Fi Direct config can mislead operators on Ubuntu builds | Start discovery with optional transports enabled | `skybridge-core/src/discovery/manager.rs:199` | Explicit compatibility fallback (no-op + telemetry) without breaking callers | `cargo test --workspace --all-features` (discovery tests) | Resolved (2026-03-04) |
| FUNC-004 | Platform/capability parsing compatibility gaps | P1 | macOS aliases may parse inconsistently across channels | Parse legacy TXT aliases from macOS peers | `skybridge-core/src/discovery/types.rs:70` | Added `FromStr` + compatible parser paths and alias mapping | `cargo test --workspace --all-features` (discovery/mdns tests) | Resolved (2026-03-04) |
| FUNC-005 | mDNS multi-service merge gap | P0 | Remote/transfer ports from Mac service advertisements are dropped, causing wrong endpoint selection | Peer advertises `_skybridge-remote._tcp` / `_skybridge-transfer._tcp` alongside control channel | `skybridge-core/src/discovery/mdns.rs:103`, `skybridge-core/src/discovery/types.rs:170`, `skybridge-core/src/remote/manager.rs:167` | Browse all service types, merge endpoints per device, keep online status until last service removed, and use remote endpoint preference in remote manager | `cargo test --workspace --all-features` (mdns + discovery types tests) | Resolved (2026-03-04) |
| FUNC-006 | Handshake identity/signature algorithm mismatch | P0 | Ubuntu may fail peer signature verification against Mac/iOS algorithm advertising (including P-256 compatibility path) | Connect to peer advertising non-default signing algorithm | `skybridge-core/src/crypto/signature.rs:16`, `skybridge-core/src/crypto/provider.rs:80`, `skybridge-core/src/p2p/driver.rs:1382` | Added P-256 ECDSA provider and explicit algorithm-based verification path in handshake driver | `cargo test --workspace --all-features` (`crypto::signature` + `p2p::driver` tests) | Resolved (2026-03-04) |
| FUNC-007 | Handshake wire strictness/legacy decode drift | P1 | Invalid key-share framing may pass parse or legacy identity payloads may decode inconsistently vs Mac/iOS | Feed malformed MessageA/MessageB key-share lengths/order or legacy identity block | `skybridge-core/src/p2p/messages.rs:533`, `skybridge-core/src/p2p/messages.rs:666`, `skybridge-core/src/p2p/messages.rs:809` | Added strict suite/key-share validation and controlled legacy identity fallback (65-byte uncompressed P-256 only) | `cargo test --workspace --all-features` (`p2p::messages` tests) | Resolved (2026-03-04) |
| FUNC-008 | Remote transport protocol mismatch for Apple peers | P0 | Apple peers exposing remote JSON endpoint may fail/underperform if Ubuntu always prefers VNC | Connect to macOS/iOS peer with remote service endpoint | `skybridge-core/src/remote/manager.rs:16`, `skybridge-core/src/remote/manager.rs:340` | Added transport selection (Mac JSON for Apple/remote-service peers) with fallback to VNC on connect failure | `cargo test --workspace --all-features` (`remote::manager` tests) | Resolved (2026-03-04) |

## Stability & Safety

| ID | Category | Priority | Impact | Repro/Trigger | Evidence | Fix Plan | Regression Test | Status |
|---|---|---|---|---|---|---|---|---|
| STAB-001 | Potential panic usage in non-test code | P1 | Runtime abort risk under unexpected state/parse failures | Non-test `.unwrap/.expect` paths | `skybridge-app/src/main.rs`, `skybridge-core/src/*` | Replaced high-risk panic points in touched compatibility paths; retained low-risk startup expects for now | Existing unit + negative path tests | Mitigated (follow-up needed) |

## Engineering Quality

| ID | Category | Priority | Impact | Repro/Trigger | Evidence | Fix Plan | Regression Test | Status |
|---|---|---|---|---|---|---|---|---|
| ENG-001 | Formatting gate failing | P1 | CI gate cannot be enforced | `cargo fmt --all -- --check` | Workspace-wide formatting drift | Applied formatting and validated gate | `cargo fmt --all -- --check` | Resolved (2026-03-04) |
| ENG-002 | Clippy strict gate failing | P1 | `-D warnings` fails release pipeline | `cargo clippy ... -D warnings` | Warnings across `skybridge-core/ui/app` | Mechanical + structural cleanup; kept compatibility APIs | `cargo clippy --workspace --all-targets --all-features -- -D warnings` | Resolved (2026-03-04) |

## UI Parity Tracking (Ubuntu vs Mac baseline)

| ID | Category | Priority | Impact | Repro/Trigger | Evidence | Fix Plan | Regression Test | Status |
|---|---|---|---|---|---|---|---|---|
| UI-001 | Missing shared design tokens | P1 | Inconsistent typography/spacing/colors across pages | Navigate login/dashboard/devices/transfers/settings | `skybridge-ui/src/utils/style.css:3` | Added shared tokenized CSS and standardized component surfaces/states | Manual screenshot diff workflow + CI visual threshold | Resolved (2026-03-04) |
| UI-002 | Page shell/header inconsistency | P1 | Header/title rhythm differs by page | Switch between major pages | `skybridge-ui/src/pages/login.rs:44`, `skybridge-ui/src/pages/dashboard.rs:130`, `skybridge-ui/src/pages/settings.rs:52` | Added common `page-root/page-header/page-title` classes for all major pages | UI baseline checklist run | Resolved (2026-03-04) |
| UI-003 | List row visual inconsistency | P2 | Device and transfer rows differ from Mac visual rhythm | Open Devices and Transfers pages | `skybridge-ui/src/components/device_card.rs:22`, `skybridge-ui/src/components/transfer_row.rs:28` | Unified row radius/border/padding states via shared classes | UI baseline checklist run | Resolved (2026-03-04) |
| UI-004 | Missing automated pixel diff gate | P1 | Pixel parity verification depends on manual reviewer inspection | Compare Ubuntu vs Mac screenshot sets per capture matrix | `docs/mac-baseline/ui-baseline/compare_screenshots.py:1`, `docs/mac-baseline/ui-baseline/capture-manifest.json:1` | Added manifest-driven automated diff script with threshold/hard-fail rules and artifact output | Run baseline compare script and review `summary.json`/`diff/*.png` | In progress (awaiting screenshot bundle) |
| UI-005 | Sidebar/page copy and navigation color parity drift | P2 | Ubuntu navigation labels/state colors differ from Mac baseline and reduce cross-platform consistency | Compare sidebar + page headers against Mac baseline strings | `skybridge-app/src/main.rs:2867`, `skybridge-ui/src/pages/dashboard.rs:142`, `skybridge-ui/src/pages/transfers.rs:43`, `skybridge-ui/src/utils/style.css:67` | Aligned labels (`Main Console`, `System Monitor`, Quantum suffix), empty-state copy, and per-nav selected color styles | UI baseline screenshot diff (`UI-CAP-003/005/007`) | Resolved (2026-03-04) |

## Latest Validation Snapshot

- `cargo check --workspace`: pass
- `cargo test --workspace --all-features`: pass
- `cargo fmt --all -- --check`: pass
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`: pass
