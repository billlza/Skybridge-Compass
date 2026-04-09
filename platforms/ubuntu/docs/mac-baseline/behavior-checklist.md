# Ubuntu ↔ Mac Behavior Checklist

| Area | Scenario | Expected | Status |
|---|---|---|---|
| Discovery | mDNS `_skybridge._tcp`/`_skybridge._udp` | Device visible and online state updates | Implemented (pending Mac lab verification) |
| Discovery | Alias TXT keys (`device_id`, `fn`, `os`) | Parsed into canonical fields | Implemented + unit-tested |
| Handshake | PQC/hybrid suite negotiation | Same suite selected or deterministic fallback | Implemented + regression-tested |
| Handshake | Identity key decode compatibility | New format strict parse; fallback only for legacy uncompressed P-256 key | Implemented + regression-tested |
| Handshake | Wire strictness for key shares | Reject invalid/misaligned key-share length or ordering | Implemented + regression-tested |
| Handshake | Signature verify parity | Verify by wire signature algorithm (Ed25519 / ML-DSA-65 / P-256 ECDSA) | Implemented + regression-tested |
| Handshake | Classic fallback cooldown | Immediate retry blocked per policy | Implemented + regression-tested |
| Transfer | Small file (<1MB) | Complete with hash verification | Implemented (pending Mac lab verification) |
| Transfer | Large file + resume | Resume from chunk index and final hash matches | Implemented (pending Mac lab verification) |
| Remote Desktop | Connect + first frame | Session active with first frame rendered | Implemented (pending Mac lab verification) |
| Remote Desktop | Apple remote transport compatibility | Prefer Mac JSON remote protocol for Apple peers / remote endpoint, fallback to VNC on failure | Implemented + regression-tested |
| Remote Desktop | Mouse/keyboard/clipboard | Input propagates and returns success/failure deterministically | Implemented (pending Mac lab verification) |
| Recovery | Peer disconnect during active stream | Session transitions to disconnected and resources cleaned up | Implemented + unit-tested |
