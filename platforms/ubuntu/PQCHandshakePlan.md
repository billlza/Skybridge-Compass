# SkyBridge Compass Ubuntu – PQC Handshake Plan

**Date:** 2026-01-30  
**Status:** In progress (Phase 1 implementation started)

## Goal
Align Ubuntu’s P2P handshake with the macOS/iOS PQC handshake strategy so that macOS, iOS, and Linux can negotiate a quantum‑safe session (PQC/Hybrid) with safe classic fallback when required.

## Reference Behavior (macOS/iOS)
Key behaviors observed in `SkyBridge Compass Pro release`:
- **Suite IDs**: `0x0001` (X‑Wing hybrid), `0x0101` (ML‑KEM‑768), `0x1001` (X25519 classic).
- **Signature rule**: If any PQC/Hybrid suite is offered → `sigA = ML‑DSA‑65`; otherwise `sigA = Ed25519`.  
  Homogeneity is enforced: PQC suites cannot be mixed with classic in one attempt.
- **Two‑attempt strategy**: PQC‑only attempt first; if it fails for *allowed* reasons, retry classic‑only.  
  Timeout never triggers fallback; per‑peer cooldown prevents downgrade spam.
- **PQC keyshare semantics**:
  - Initiator uses **peer KEM public key** to encapsulate and sends the **ciphertext** as the key share.
  - Responder decapsulates with its KEM private key to derive the shared secret.
  - MessageB for PQC does **not** carry a responder key share (empty).
- **HandshakePolicy** is embedded in the transcript to resist downgrade attacks.

## Ubuntu Current State (before Phase 1)
- Crypto primitives already available:
  - **ML‑KEM‑768** via `pqcrypto‑kyber`.
  - **ML‑DSA‑65** via `pqcrypto‑dilithium`.
  - **X‑Wing (X25519 + ML‑KEM‑768)** in `crypto/kem.rs`.
- Handshake currently:
  - Offers **PQC + Classic together**.
  - Chooses signature provider based on **first suite**, which can mismatch.
  - Uses **bincode** encoding (not compatible with macOS wire format).

## Plan Overview
### Phase 1 (Now) – Policy + Homogeneity + PQC Semantics
1. **HandshakePolicy** in Ubuntu core:
   - `require_pqc`, `allow_classic_fallback`, `minimum_tier`.
2. **Two‑attempt gating** (PQC‑only → Classic‑only).
3. **Signature alignment**:
   - ML‑DSA‑65 for PQC/Hybrid attempts; Ed25519 for classic‑only.
   - Reject mismatches early.
4. **PQC keyshare semantics**:
   - Initiator uses peer KEM public key (if known) to encapsulate.
   - If peer KEM key is missing, PQC suites are skipped (fallback path).
5. **Failure reasons** upgraded so fallback decisions are explicit.

### Phase 2 – Wire Format Alignment (macOS compatible)
1. Implement macOS‑style **deterministic encoding** and handshake message layout.
2. Add **CryptoCapabilities** + **HandshakePolicy** encoding in transcript.
3. Replace bincode handshake serialization for cross‑platform interop.

### Phase 3 – Trust/Discovery Key Sync
1. Store **peer KEM public keys** (trust store or pairing exchange).
2. Advertise KEM key fingerprints via discovery or pairing channel.
3. Enable PQC handshake even on first contact (TOFU or explicit pairing).

## Implementation Notes (Phase 1)
- **Homogeneity** ensures a single attempt never mixes PQC + Classic.
- **Peer KEM keys** are optional; without them, PQC is skipped instead of sent in “legacy mode”.
- This phase does **not** change the wire format yet; Phase 2 will handle interop.

## Next Steps After Phase 1
- Implement macOS wire format (`MessageA/B` byte layout + deterministic transcript).
- Add cross‑platform test vectors and interoperability tests.


