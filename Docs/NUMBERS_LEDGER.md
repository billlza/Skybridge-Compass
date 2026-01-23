# SkyBridge Compass - Numbers Ledger (Data Consistency Audit)

## STATUS: ALL NUMBERS VERIFIED CONSISTENT ✅

Last verified: 2026-01-22

---

## SOURCE OF TRUTH: Performance Summary Table (tab:perf-summary)

| Configuration | Latency mean | Latency p95 | RTT p50 | RTT p95 | Wire Size | Throughput |
|---------------|--------------|-------------|---------|---------|-----------|------------|
| Classic | 1.62 ms | 1.81 ms | 0.41 ms | 0.46 ms | 827 B | 3.7 GB/s |
| liboqs PQC | 2.29 ms | 3.01 ms | 0.80 ms | 1.35 ms | 12,163 B | 3.7 GB/s |
| CryptoKit PQC | 5.76 ms | 6.71 ms | 1.59 ms | 2.27 ms | 12,163 B | 3.7 GB/s |

---

## ABSTRACT VERIFICATION ✅

| Metric | Abstract Value | Table Value | Status |
|--------|---------------|-------------|--------|
| Classic latency mean | 1.62 ms | 1.62 ms | ✅ MATCH |
| Classic latency p95 | 1.81 ms | 1.81 ms | ✅ MATCH |
| liboqs PQC latency mean | 2.29 ms | 2.29 ms | ✅ MATCH |
| liboqs PQC latency p95 | 3.01 ms | 3.01 ms | ✅ MATCH |
| CryptoKit PQC latency mean | 5.76 ms | 5.76 ms | ✅ MATCH |
| CryptoKit PQC latency p95 | 6.71 ms | 6.71 ms | ✅ MATCH |
| Classic wire size | 827 B | 827 B | ✅ MATCH |
| liboqs PQC wire size | 12,163 B | 12,163 B | ✅ MATCH |
| CryptoKit PQC wire size | 12,163 B | 12,163 B | ✅ MATCH |
| X-Wing wire size | 12,195 B | 12,195 B (main text) | ✅ MATCH |

---

## DATA PIPELINE

All numbers are generated from CSV artifacts via `Scripts/make_tables.py`:

```
Artifacts/ (ARTIFACT_DATE=2026-01-16)
  handshake_bench_2026-01-16.csv  → Latency data
  handshake_rtt_2026-01-16.csv    → RTT data
  message_sizes_2026-01-16.csv    → Wire size data
  traffic_padding_2026-01-16.csv  → SBP2 padding quantization/overhead (Phase C3, locked to ARTIFACT_DATE)
  traffic_padding_sensitivity_2026-01-16.csv → SBP2 cap sensitivity study (64/128/256KiB)
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
- [x] X-Wing projection matches Appendix calculation
- [x] Supplementary tables referenced in main text
