# Revision Note (2026-01-23): Core Gate vs Apple/X-Wing Contrast

## Scope
This revision updates the **evaluation gating policy and reporting structure** only.

- Unchanged: security model, formal definitions/theorems, strict/default downgrade semantics, and protocol threat assumptions.
- Changed: benchmark gate composition, artifact split, and table/text reporting path.

## Why Apple hard-gate was removed
Apple PQC/X-Wing availability and variance are platform/runtime dependent in ways that can reduce cross-environment reproducibility for hard pass/fail CI gates.

To strengthen reproducibility, we now define a **core reproducibility gate** using only:

1. Classic (X25519 + Ed25519)
2. liboqs PQC (ML-KEM-768 + ML-DSA-65)
3. liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)

Apple PQC and X-Wing are still measured and published, but as **non-gating contrast**.

## New dual-track evaluation policy
- **Core gate (pass/fail):** `SKYBRIDGE_BENCH_PROFILE=core`
- **Contrast sampling (informational):** `SKYBRIDGE_BENCH_PROFILE=contrast`

Gate stability no longer requires Apple rows when:

- `SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE=0`

Artifact date lock remains:

- `ARTIFACT_DATE=2026-01-23`

## Artifact split
Core artifacts:

- `Artifacts/handshake_bench_2026-01-23.csv`
- `Artifacts/handshake_rtt_2026-01-23.csv`

Contrast artifacts:

- `Artifacts/handshake_bench_contrast_2026-01-23.csv`
- `Artifacts/handshake_rtt_contrast_2026-01-23.csv`
- `Artifacts/apple_contrast_summary_2026-01-23.json`

## Paper/reporting mapping
- Main performance conclusions and hard-gate claims are sourced from **core** artifacts.
- Apple PQC/X-Wing appear in supplementary contrast reporting (e.g., `Docs/supp_tables/s13_apple_contrast.tex`) and do not affect pass/fail gate outcomes.

## Reproducibility rationale
This split preserves transparency (Apple/X-Wing still fully reported) while improving gate determinism and cross-run reproducibility for the primary claims.
