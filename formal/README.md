# SkyBridge Compass Formal Model (v2)

This directory contains the reviewer-facing Tamarin artifact for the
SkyBridge handshake, including protocol v2 fallback/FS semantics.

## Files

- `skybridge_v2.spthy`: main theory used by the paper.
- `skybridge_minimal.spthy`: earlier reduced model (kept for reference).
- `run_tamarin.sh`: helper script (`./run_tamarin.sh [theory]`).

## How to run

```bash
cd formal
./run_tamarin.sh
```

By default this proves `skybridge_v2.spthy`. You can pass another theory
as the first argument.

## Lemma inventory (exact names in `skybridge_v2.spthy`)

### Existence lemmas (anti-vacuity)

- `Exists_DefaultClassicTrace`
- `Exists_StrictPQCv2Trace`

### Security lemmas

- `NoClassicUnderStrictPQC`
- `NegotiationIntegrity_SelectedWasOffered`
- `AuthenticationRequiresVerifiedSigB`
- `ClassicRequiresDowngradeEvent`
- `ClassicRequiresFallbackGate`
- `ClassicOnlyUnderDefaultPolicy`
- `V2HybridSecretComposition`

## Modeling notes

- The model explicitly emits `DowngradeEvent` on default-policy classic fallback.
- v2 FS is modeled as requiring both static and ephemeral contribution events.
- Pairing storage/platform API details are intentionally abstracted.
