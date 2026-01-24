# SkyBridge Compass — Minimal Symbolic Model (Tamarin)

This directory contains a **minimal symbolic model** of SkyBridge Compass's
handshake core, intended to strengthen reviewer-facing claims with a
machine-checkable artifact.

## Scope (deliberately minimal)

The model captures only the parts needed to reason about the paper's core
security contract:

- **Suite negotiation integrity** (selected suite must be among offered suites)
- **Transcript binding** (responder signature binds MessageA + selectedSuite)
- **Explicit key confirmation** (two Finished messages)
- **Downgrade / fallback gate** (strictPQC forbids classic; default policy allows classic only under a local-only gate)

It intentionally abstracts away:

- Pairing ceremony details (assumed to yield a pinned identity key)
- Concrete algorithms (KEM/DH/HKDF are symbolic primitives)
- OS logging / tamper-proof storage (treated as events)

## Files

- `skybridge_minimal.spthy`: Tamarin theory (protocol + lemmas).
- `run_tamarin.sh`: helper to run Tamarin locally and export a proof report.

## How to run (local)

Install Tamarin (see `tamarin-prover` docs), then:

```bash
cd formal
./run_tamarin.sh
```

Expected output:

- A `tamarin-report/` folder with HTML proof output (if enabled)
- Console summary showing lemma status

## Lemmas (high level)

The theory includes lemmas corresponding to the paper's key claims:

- **Negotiation integrity**: attacker cannot make responder accept a suite not offered by initiator.
- **No timeout-induced downgrade**: a network attacker (drop/delay/reorder) cannot induce a successful classic session under `strictPQC`.
- **No silent downgrade**: any successful classic session under default policy implies an explicit downgrade event.

Note: The precise lemma names are in the `.spthy` file.


