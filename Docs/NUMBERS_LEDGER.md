# SkyBridge Compass - Numbers Ledger (Data Consistency Audit)

## STATUS: ALL NUMBERS VERIFIED CONSISTENT ✅

Last verified: 2026-01-23 (artifact snapshot repackaged under the correct build date suffix)

---

## SOURCE OF TRUTH: Performance Summary Table (tab:perf-summary)

| Configuration | Latency mean | Latency p95 | RTT p50 | RTT p95 | Wire Size | Throughput |
|---------------|--------------|-------------|---------|---------|-----------|------------|
| Classic | 1.89 ms | 2.18 ms | 0.53 ms | 0.57 ms | 687 B | 3.7 GB/s |
| liboqs PQC | 3.47 ms | 4.18 ms | 1.51 ms | 2.06 ms | 12,002 B | 3.7 GB/s |
| CryptoKit PQC | 5.20 ms | 6.16 ms | 2.36 ms | 3.05 ms | 12,002 B | 3.7 GB/s |

---

## ABSTRACT VERIFICATION ✅

| Metric | Abstract Value | Table Value | Status |
|--------|---------------|-------------|--------|
| Classic latency mean | 1.89 ms | 1.89 ms | ✅ MATCH |
| Classic latency p95 | 2.18 ms | 2.18 ms | ✅ MATCH |
| liboqs PQC latency mean | 3.47 ms | 3.47 ms | ✅ MATCH |
| liboqs PQC latency p95 | 4.18 ms | 4.18 ms | ✅ MATCH |
| CryptoKit PQC latency mean | 5.20 ms | 5.20 ms | ✅ MATCH |
| CryptoKit PQC latency p95 | 6.16 ms | 6.16 ms | ✅ MATCH |
| Classic wire size | 687 B | 687 B | ✅ MATCH |
| liboqs PQC wire size | 12,002 B | 12,002 B | ✅ MATCH |
| CryptoKit PQC wire size | 12,002 B | 12,002 B | ✅ MATCH |

---

## DATA PIPELINE

All numbers are generated from CSV artifacts via `Scripts/make_tables.py`.

### What went wrong (root cause of the Fig/Table mismatch)

The repository historically had **two parallel “selection rules”**:
- Tables (`Table 8`, `Supplementary S1/S3`) were generated via `Scripts/make_tables.py`, which prefers a **pinned** `ARTIFACT_DATE` (and can read `\artifactdate` from the main TeX) to avoid mixing datasets.
- Some figure-generation paths used a **“latest CSV in Artifacts/”** heuristic or carried a **placeholder date suffix** during artifact packaging.

This split allowed a single PDF to accidentally combine:
- Figures built from a newer / placeholder-suffixed snapshot
- Tables built from the pinned 2026-01-16 snapshot

The fix is to **force a single snapshot date** end-to-end and regenerate both figures and tables.
### Fixed snapshot (paper-facing)

We repackaged the previously placeholder-suffixed snapshot as **`ARTIFACT_DATE=2026-01-23`** by copying the relevant CSVs (content unchanged) so that the paper-facing chain uses a realistic build date suffix.
All paper-facing numbers now use **one date suffix**:

```
Artifacts/ (ARTIFACT_DATE=2026-01-23)
  handshake_bench_2026-01-23.csv  → Latency data (Fig.8, Table 8, Supp. S1)
  handshake_rtt_2026-01-23.csv    → RTT data (Table 8, Supp. S2)
  message_sizes_2026-01-23.csv    → Message sizes / Wire size (Fig.9, Table 8, Supp. S3)
  traffic_padding_2026-01-23.csv  → SBP2 padding quantization/overhead (Supp. S7, Fig.11)
  traffic_padding_sensitivity_2026-01-23.csv → SBP2 cap sensitivity study (Supp. S8, Fig.12)
                ↓
Scripts/make_tables.py
                ↓
Docs/tables/perf_summary.tex     → Main text Performance Summary Table
Docs/supp_tables/s1_latency.tex  → Supplementary latency details
Docs/supp_tables/s2_rtt.tex      → Supplementary RTT details
Docs/supp_tables/s3_message_sizes.tex → Supplementary message breakdown
Docs/supp_tables/s7_traffic_padding.tex → Supplementary SBP2 traffic padding table
Docs/supp_tables/s8_traffic_padding_sensitivity.tex → Supplementary SBP2 cap sensitivity table
```

Repeatability (multi-batch) notes:
- Repeatability tables report observed batch count **B** and (when **B ≥ 2**) mean \(\pm\) 95\% CI across independent batches.
- To generate multi-batch artifacts, rerun with process restarts, e.g. `ARTIFACT_DATE=YYYY-MM-DD SKYBRIDGE_BENCH_BATCHES=5 bash Scripts/run_paper_eval.sh`.

System-level impact is generated from a separate artifact set:

```
Artifacts/system_impact_2026-01-22.csv → session-level connect/transfer metrics
```

---

## ROUNDING RULES

- Latency: 2 decimal places (ms)
- Wire size: Integer (bytes), comma for thousands
- Throughput: 1 decimal place (GB/s)
- Percentages: Integer

---

## CROSS-REFERENCE CHECKLIST

- [x] Abstract matches Table tab:perf-summary
- [x] All Fig/Table/Section references exist
- [ ] X-Wing projection matches Appendix calculation (N/A in ARTIFACT_DATE=2026-01-23 snapshot)
- [x] Supplementary tables referenced in main text
