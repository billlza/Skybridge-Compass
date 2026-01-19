# SkyBridge Compass - Numbers Ledger (Data Consistency Audit)

## STATUS: ALL NUMBERS VERIFIED CONSISTENT ✅

Last verified: 2026-01-16

---

## SOURCE OF TRUTH: Performance Summary Table (tab:perf-summary)

| Configuration | Latency mean | Latency p95 | RTT p50 | RTT p95 | Wire Size | Throughput |
|---------------|--------------|-------------|---------|---------|-----------|------------|
| Classic | 1.41 ms | 1.45 ms | 0.36 ms | 0.37 ms | 687 B | 3.7 GB/s |
| liboqs PQC | 2.00 ms | 2.62 ms | 0.65 ms | 1.24 ms | 12,002 B | 3.7 GB/s |
| CryptoKit PQC | 4.63 ms | 5.45 ms | 2.23 ms | 3.01 ms | 12,002 B | 3.7 GB/s |

---

## ABSTRACT VERIFICATION ✅

| Metric | Abstract Value | Table Value | Status |
|--------|---------------|-------------|--------|
| Classic latency mean | 1.41 ms | 1.41 ms | ✅ MATCH |
| Classic latency p95 | 1.45 ms | 1.45 ms | ✅ MATCH |
| liboqs PQC latency mean | 2.00 ms | 2.00 ms | ✅ MATCH |
| liboqs PQC latency p95 | 2.62 ms | 2.62 ms | ✅ MATCH |
| CryptoKit PQC latency mean | 4.63 ms | 4.63 ms | ✅ MATCH |
| CryptoKit PQC latency p95 | 5.45 ms | 5.45 ms | ✅ MATCH |
| Classic wire size | 687 B | 687 B | ✅ MATCH |
| liboqs PQC wire size | 12,002 B | 12,002 B | ✅ MATCH |
| CryptoKit PQC wire size | 12,002 B | 12,002 B | ✅ MATCH |
| X-Wing projection | ~12.1 KB | 12,130 B (Appendix) | ✅ MATCH (rounded) |

---

## DATA PIPELINE

All numbers are generated from CSV artifacts via `Scripts/make_tables.py`:

```
Artifacts/
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
