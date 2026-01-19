#!/usr/bin/env python3
"""
SkyBridge Compass - Table Generator
Generates LaTeX tables from CSV artifacts to ensure data consistency.

Usage: python3 Scripts/make_tables.py

Outputs:
  - tables/perf_summary.tex (Main text Performance Summary Table)
  - supp_tables/s1_latency.tex (Supplementary full latency)
  - supp_tables/s2_rtt.tex (Supplementary full RTT)
  - supp_tables/s3_message_sizes.tex (Supplementary message breakdown)
  - supp_tables/s7_traffic_padding.tex (Supplementary traffic padding quantization summary)
  - supp_tables/s8_traffic_padding_sensitivity.tex (Supplementary SBP2 bucket-cap sensitivity study)
"""

import csv
import os
import math
from pathlib import Path
from datetime import datetime
from statistics import stdev

# Paths
PROJECT_ROOT = Path(__file__).parent.parent
ARTIFACTS_DIR = PROJECT_ROOT / "Artifacts"
TABLES_DIR = PROJECT_ROOT / "Docs" / "tables"
SUPP_DIR = PROJECT_ROOT / "Docs" / "supp_tables"

# Repeatability table caps (journal-friendly: report up to 5 independent batches)
MAX_REPEATABILITY_BATCHES = 5

# Canonical configuration names used by the paper tables.
ORDERED_PERF_CONFIGS = [
    "Classic (X25519 + Ed25519)",
    "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
    "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
]

# Prefer selecting a representative batch based on the highest-variance configuration first.
REFERENCE_CONFIG_PREFERENCE = [
    "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
    "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
    "Classic (X25519 + Ed25519)",
]

# Ensure output directories exist
TABLES_DIR.mkdir(parents=True, exist_ok=True)
SUPP_DIR.mkdir(parents=True, exist_ok=True)

def find_latest_csv(prefix):
    """Find the most recent CSV file with given prefix."""
    files = list(ARTIFACTS_DIR.glob(f"{prefix}_*.csv"))
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)

def _date_suffixes_for_prefix(prefix: str) -> set[str]:
    """
    Return the set of date suffixes present for prefix files matching:
      Artifacts/<prefix>_<DATE>.csv
    """
    out: set[str] = set()
    for p in ARTIFACTS_DIR.glob(f"{prefix}_*.csv"):
        name = p.name
        if not name.startswith(prefix + "_") or not name.endswith(".csv"):
            continue
        out.add(name[len(prefix) + 1:-4])
    return out

def select_artifact_csv(prefix: str, artifact_date: str | None, strict: bool = True) -> Path | None:
    """
    Select an artifact CSV by prefix with a single shared date suffix.

    - If artifact_date is provided, require the exact file to exist.
    - Else, pick the latest file by mtime (legacy behavior).
    """
    if artifact_date:
        candidate = ARTIFACTS_DIR / f"{prefix}_{artifact_date}.csv"
        if candidate.exists():
            return candidate
        if strict:
            raise FileNotFoundError(f"Missing required artifact: {candidate}")
        return None
    latest = find_latest_csv(prefix)
    if latest is None and strict:
        raise FileNotFoundError(f"No {prefix}_*.csv found in {ARTIFACTS_DIR}")
    return latest

def select_common_artifact_date(prefixes: list[str]) -> str | None:
    """
    Pick a single DATE such that all prefixes have Artifacts/<prefix>_<DATE>.csv.
    Returns the lexicographically largest DATE (YYYY-MM-DD sorts correctly).
    """
    if not prefixes:
        return None
    common = None
    for pref in prefixes:
        dates = _date_suffixes_for_prefix(pref)
        if not dates:
            return None
        common = dates if common is None else (common & dates)
        if not common:
            return None
    return max(common) if common else None

def _read_csv_rows(filepath):
    with open(filepath, 'r', newline='') as f:
        return list(csv.DictReader(f))

def _latex_escape(s: str) -> str:
    return (s
        .replace('\\', r'\textbackslash{}')
        .replace('_', r'\_')
        .replace('%', r'\%')
        .replace('&', r'\&')
        .replace('#', r'\#')
        .replace('{', r'\{')
        .replace('}', r'\}')
    )

def _parse_bucket_sizes(s: str):
    # "256:20|512:20|1024:30"
    out = {}
    if not s:
        return out
    for part in s.split('|'):
        if not part:
            continue
        if ':' not in part:
            continue
        k, v = part.split(':', 1)
        try:
            out[int(k)] = int(v)
        except ValueError:
            continue
    return out

def _top_bucket_summary(bucket_map):
    if not bucket_map:
        return "-"
    total = sum(bucket_map.values())
    if total <= 0:
        return "-"
    top_size, top_count = max(bucket_map.items(), key=lambda kv: kv[1])
    pct = 100.0 * (top_count / total)
    return f"{top_size}B ({pct:.0f}\\%)"

def _parse_latency_row(row):
    return {
        'n': int(row['iteration_count']),
        'mean': float(row['mean_ms']),
        'std': float(row['stddev_ms']),
        'p50': float(row['p50_ms']),
        'p95': float(row['p95_ms']),
        'p99': float(row['p99_ms'])
    }

def _parse_rtt_row(row):
    # RTT artifacts include stddev_ms in the CSV for completeness; tables may not display it.
    return {
        'n': int(row['iteration_count']),
        'mean': float(row['mean_ms']),
        'std': float(row.get('stddev_ms', 0.0)),
        'p50': float(row['p50_ms']),
        'p95': float(row['p95_ms']),
        'p99': float(row['p99_ms'])
    }

def _filter_to_configs(rows, allowed_configs):
    allowed = set(allowed_configs)
    return [r for r in rows if r.get('configuration') in allowed]

def _group_rows_into_batches(rows, parse_row):
    """
    Group sequential CSV rows into batches.

    A batch contains at most one entry per configuration. If a configuration repeats,
    we start a new batch. This avoids selecting partial runs (e.g., running only
    Classic) as the "latest" data for mixed-configuration tables.
    """
    batches = []
    current = {}
    for row in rows:
        config = row['configuration']
        if config in current:
            batches.append(current)
            current = {}
        current[config] = parse_row(row)
    if current:
        batches.append(current)
    return batches

def _complete_batches(batches, required_configs):
    required = set(required_configs)
    return [b for b in batches if required.issubset(b.keys())]

def _select_reference_config(required_configs):
    required = set(required_configs)
    for cfg in REFERENCE_CONFIG_PREFERENCE:
        if cfg in required:
            return cfg
    return next(iter(required)) if required else None

def _select_representative_batch(batches, required_configs, metric='mean'):
    """
    Choose a representative batch from the trailing window of complete batches.

    We select the batch whose reference configuration's metric is closest to the
    across-window mean, which avoids picking an outlier "last run" when the CSV
    contains multiple independent batches.
    """
    complete = _complete_batches(batches, required_configs)
    if not complete:
        return None

    window = complete[-MAX_REPEATABILITY_BATCHES:]
    reference = _select_reference_config(required_configs)
    if reference is None:
        return window[-1]

    values = [b[reference][metric] for b in window if reference in b and metric in b[reference]]
    if not values:
        return window[-1]

    target = sum(values) / len(values)
    best_index = 0
    best_distance = None
    for i, b in enumerate(window):
        v = b[reference].get(metric)
        if v is None:
            continue
        dist = abs(v - target)
        if best_distance is None or dist < best_distance or (dist == best_distance and i > best_index):
            best_distance = dist
            best_index = i
    return window[best_index]

def parse_handshake_bench(filepath):
    """Parse handshake benchmark CSV, return a representative complete batch by configuration."""
    rows = _filter_to_configs(_read_csv_rows(filepath), ORDERED_PERF_CONFIGS)
    batches = _group_rows_into_batches(rows, _parse_latency_row)
    representative = _select_representative_batch(batches, ORDERED_PERF_CONFIGS, metric='mean')
    return representative or {}

def parse_handshake_bench_runs(filepath):
    """Parse handshake benchmark CSV, return the last N complete batches grouped by configuration."""
    rows = _filter_to_configs(_read_csv_rows(filepath), ORDERED_PERF_CONFIGS)
    batches = _group_rows_into_batches(rows, _parse_latency_row)
    complete = _complete_batches(batches, ORDERED_PERF_CONFIGS)
    window = complete[-MAX_REPEATABILITY_BATCHES:]
    return {cfg: [b[cfg] for b in window] for cfg in ORDERED_PERF_CONFIGS}

def parse_rtt(filepath):
    """Parse RTT CSV, return a representative complete batch by configuration."""
    rows = _filter_to_configs(_read_csv_rows(filepath), ORDERED_PERF_CONFIGS)
    batches = _group_rows_into_batches(rows, _parse_rtt_row)
    representative = _select_representative_batch(batches, ORDERED_PERF_CONFIGS, metric='mean')
    return representative or {}

def parse_rtt_runs(filepath):
    """Parse RTT CSV, return the last N complete batches grouped by configuration."""
    rows = _filter_to_configs(_read_csv_rows(filepath), ORDERED_PERF_CONFIGS)
    batches = _group_rows_into_batches(rows, _parse_rtt_row)
    complete = _complete_batches(batches, ORDERED_PERF_CONFIGS)
    window = complete[-MAX_REPEATABILITY_BATCHES:]
    return {cfg: [b[cfg] for b in window] for cfg in ORDERED_PERF_CONFIGS}

_T_CRIT_975 = {
    1: 12.706,
    2: 4.303,
    3: 3.182,
    4: 2.776,
    5: 2.571,
    6: 2.447,
    7: 2.365,
    8: 2.306,
    9: 2.262,
    10: 2.228,
    11: 2.201,
    12: 2.179,
    13: 2.160,
    14: 2.145,
    15: 2.131,
    16: 2.120,
    17: 2.110,
    18: 2.101,
    19: 2.093,
    20: 2.086,
    21: 2.080,
    22: 2.074,
    23: 2.069,
    24: 2.064,
    25: 2.060,
    26: 2.056,
    27: 2.052,
    28: 2.048,
    29: 2.045,
    30: 2.042,
}

def mean_and_ci(values):
    """Compute mean and 95% CI half-width using Student-t (fallback to normal for df>30)."""
    if not values:
        return (0.0, 0.0, 0)
    n = len(values)
    mu = sum(values) / n
    if n < 2:
        return (mu, 0.0, n)
    s = stdev(values)
    se = s / math.sqrt(n)
    df = n - 1
    t = _T_CRIT_975.get(df, 1.96)
    return (mu, t * se, n)

def generate_repeatability_latency_table(latency_runs):
    """Generate supplementary repeatability table for latency (mean ± 95% CI across batches)."""
    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: Repeatability across independent benchmark batches (latency). Cells report mean $\pm$ 95\% CI across batches; each batch uses N=1000 iterations after 10 warmup runs.}",
        r"\label{tab:supp-repeatability-latency}",
        r"\begin{tabular}{@{}lccccc@{}}",
        r"\toprule",
        r"Configuration & B & N/batch & mean (ms) & p50 (ms) & p95 (ms) \\",
        r"\midrule",
    ]

    for config in ORDERED_PERF_CONFIGS:
        runs = latency_runs.get(config, [])
        if not runs:
            continue
        short = short_config(config)
        n_per = runs[0]['n']
        means = [r['mean'] for r in runs]
        p50s = [r['p50'] for r in runs]
        p95s = [r['p95'] for r in runs]
        mean_mu, mean_ci, b = mean_and_ci(means)
        p50_mu, p50_ci, _ = mean_and_ci(p50s)
        p95_mu, p95_ci, _ = mean_and_ci(p95s)
        line = (
            f"{short} & {b} & {n_per} & "
            f"${mean_mu:.3f} \\pm {mean_ci:.3f}$ & "
            f"${p50_mu:.3f} \\pm {p50_ci:.3f}$ & "
            f"${p95_mu:.3f} \\pm {p95_ci:.3f}$ \\\\"
        )
        lines.append(line)

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}",
    ])
    return "\n".join(lines)

def generate_repeatability_rtt_table(rtt_runs):
    """Generate supplementary repeatability table for RTT (mean ± 95% CI across batches)."""
    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: Repeatability across independent benchmark batches (RTT). Cells report mean $\pm$ 95\% CI across batches; each batch uses N=1000 iterations after 10 warmup runs.}",
        r"\label{tab:supp-repeatability-rtt}",
        r"\begin{tabular}{@{}lccccc@{}}",
        r"\toprule",
        r"Configuration & B & N/batch & mean (ms) & p50 (ms) & p95 (ms) \\",
        r"\midrule",
    ]

    for config in ORDERED_PERF_CONFIGS:
        runs = rtt_runs.get(config, [])
        if not runs:
            continue
        short = short_config(config)
        n_per = runs[0]['n']
        means = [r['mean'] for r in runs]
        p50s = [r['p50'] for r in runs]
        p95s = [r['p95'] for r in runs]
        mean_mu, mean_ci, b = mean_and_ci(means)
        p50_mu, p50_ci, _ = mean_and_ci(p50s)
        p95_mu, p95_ci, _ = mean_and_ci(p95s)
        line = (
            f"{short} & {b} & {n_per} & "
            f"${mean_mu:.3f} \\pm {mean_ci:.3f}$ & "
            f"${p50_mu:.3f} \\pm {p50_ci:.3f}$ & "
            f"${p95_mu:.3f} \\pm {p95_ci:.3f}$ \\\\"
        )
        lines.append(line)

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}",
    ])
    return "\n".join(lines)

def parse_message_sizes(filepath):
    """Parse message sizes CSV."""
    data = {}
    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            data[row['message']] = {
                'total': int(row['total_bytes']),
                'sig': int(row['signature_bytes']),
                'keyshare': int(row['keyshare_bytes']),
                'identity': int(row['identity_bytes']),
                'overhead': int(row['overhead_bytes'])
            }
    return data

def short_config(config):
    """Convert long config name to short form."""
    if 'Classic' in config:
        return 'Classic'
    if 'liboqs' in config:
        return 'liboqs PQC'
    if 'CryptoKit' in config:
        return 'CryptoKit PQC'
    return config

def generate_perf_summary_table(latency, rtt, msg_sizes):
    """Generate the main Performance Summary Table."""
    def message_total(keys, fallback):
        for key in keys:
            if key in msg_sizes:
                return msg_sizes[key].get('total', fallback)
        return fallback

    finished_size = message_total(["Finished"], 38)
    classic_total = (
        message_total(["MessageA.Classic"], 293) +
        message_total(["MessageB.Classic"], 318) +
        finished_size * 2
    )
    liboqs_total = (
        message_total(
            ["MessageA.PQC-liboqs", "MessageA.PQC (liboqs)", "MessageA.PQC"],
            6507
        ) +
        message_total(
            ["MessageB.PQC-liboqs", "MessageB.PQC (liboqs)", "MessageB.PQC"],
            7595
        ) +
        finished_size * 2
    )
    cryptokit_total = (
        message_total(
            ["MessageA.PQC-CryptoKit", "MessageA.PQC (CryptoKit)", "MessageA.PQC"],
            6507
        ) +
        message_total(
            ["MessageB.PQC-CryptoKit", "MessageB.PQC (CryptoKit)", "MessageB.PQC"],
            7595
        ) +
        finished_size * 2
    )

    # Order: Classic, liboqs, CryptoKit
    configs = [
        ('Classic (X25519 + Ed25519)', 'Classic', classic_total),
        ('liboqs PQC (ML-KEM-768 + ML-DSA-65)', 'liboqs PQC', liboqs_total),
        ('CryptoKit PQC (ML-KEM-768 + ML-DSA-65)', 'CryptoKit PQC', cryptokit_total)
    ]

    # Throughput (hardcoded as no CSV, from text)
    throughput = {'Classic': 3.7, 'liboqs PQC': 3.7, 'CryptoKit PQC': 3.7}

    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Performance Summary. All benchmarks on Apple Silicon (M1/M3), macOS 26.x, N=1000 iterations after 10 warmup runs. Wire Size counts payload-only handshake bytes (MessageA + MessageB + 2$\times$Finished); loopback wire sizes including transport overhead are reported separately in Table~\ref{tab:baseline-comparison} and Supplementary Table~S4. Data-plane AEAD is fixed to AES-256-GCM in v1, so throughput is independent of the negotiated handshake suite; throughput measured post-handshake on 1~MiB payloads.}",
        r"\label{tab:perf-summary}",
        r"\begin{tabular}{@{}lcccccc@{}}",
        r"\toprule",
        r"Configuration & \multicolumn{2}{c}{Handshake Latency} & \multicolumn{2}{c}{RTT} & Wire Size & Throughput \\",
        r"\cmidrule(lr){2-3} \cmidrule(lr){4-5}",
        r" & mean (ms) & p95 (ms) & p50 (ms) & p95 (ms) & (bytes) & (GB/s) \\",
        r"\midrule"
    ]

    for full_config, short, wire_size in configs:
        lat = latency.get(full_config, {})
        r = rtt.get(full_config, {})
        tp = throughput.get(short, 3.7)

        line = f"{short} & {lat.get('mean', 0):.2f} & {lat.get('p95', 0):.2f} & " \
               f"{r.get('p50', 0):.2f} & {r.get('p95', 0):.2f} & " \
               f"{wire_size:,} & {tp:.1f} \\\\"
        lines.append(line)

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}"
    ])

    return '\n'.join(lines)

def generate_supp_latency_table(latency):
    """Generate supplementary full latency table."""
    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: Full Handshake Latency Statistics.}",
        r"\label{tab:supp-latency}",
        r"\begin{tabular}{@{}lcccccc@{}}",
        r"\toprule",
        r"Configuration & N & mean (ms) & std (ms) & p50 (ms) & p95 (ms) & p99 (ms) \\",
        r"\midrule"
    ]

    for config in ORDERED_PERF_CONFIGS:
        data = latency.get(config)
        if not data:
            continue
        short = short_config(config)
        line = f"{short} & {data['n']} & {data['mean']:.3f} & {data['std']:.3f} & " \
               f"{data['p50']:.3f} & {data['p95']:.3f} & {data['p99']:.3f} \\\\"
        lines.append(line)

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}"
    ])

    return '\n'.join(lines)

def generate_supp_rtt_table(rtt):
    """Generate supplementary RTT table."""
    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: Full RTT Statistics.}",
        r"\label{tab:supp-rtt}",
        r"\begin{tabular}{@{}lccccc@{}}",
        r"\toprule",
        r"Configuration & N & mean (ms) & p50 (ms) & p95 (ms) & p99 (ms) \\",
        r"\midrule"
    ]

    for config in ORDERED_PERF_CONFIGS:
        data = rtt.get(config)
        if not data:
            continue
        short = short_config(config)
        line = f"{short} & {data['n']} & {data['mean']:.3f} & " \
               f"{data['p50']:.3f} & {data['p95']:.3f} & {data['p99']:.3f} \\\\"
        lines.append(line)

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}"
    ])

    return '\n'.join(lines)

def generate_supp_message_sizes_table(msg_sizes):
    """Generate supplementary message sizes breakdown table."""
    order = [
        "MessageA.Classic",
        "MessageB.Classic",
        "MessageA.PQC-liboqs",
        "MessageB.PQC-liboqs",
        "MessageA.PQC-CryptoKit",
        "MessageB.PQC-CryptoKit",
        "MessageA.XWing",
        "MessageB.XWing",
        "MessageA.PQC (liboqs)",
        "MessageB.PQC (liboqs)",
        "MessageA.PQC (CryptoKit)",
        "MessageB.PQC (CryptoKit)",
        "MessageA.PQC",
        "MessageB.PQC",
        "Finished"
    ]
    seen = set()
    ordered_items = []
    for key in order:
        if key in msg_sizes and key not in seen:
            ordered_items.append((key, msg_sizes[key]))
            seen.add(key)
    for key in sorted(msg_sizes.keys()):
        if key not in seen:
            ordered_items.append((key, msg_sizes[key]))
            seen.add(key)

    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: Message Size Breakdown by Field.}",
        r"\label{tab:supp-message-sizes}",
        r"\begin{tabular}{@{}lccccc@{}}",
        r"\toprule",
        r"Message & Total (B) & Signature (B) & KeyShare (B) & Identity (B) & Overhead (B) \\",
        r"\midrule"
    ]

    for msg, data in ordered_items:
        line = f"{msg} & {data['total']} & {data['sig']} & " \
               f"{data['keyshare']} & {data['identity']} & {data['overhead']} \\\\"
        lines.append(line)

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}"
    ])

    return '\n'.join(lines)

def parse_traffic_padding(filepath):
    """Parse traffic padding CSV (already aggregated per-label in the runtime telemetry)."""
    if not filepath:
        return []
    return _read_csv_rows(filepath)

def parse_traffic_padding_sensitivity(filepath):
    """Parse traffic padding sensitivity CSV (per-label, per-cap summary)."""
    if not filepath:
        return []
    rows = _read_csv_rows(filepath)
    out = []
    for r in rows:
        try:
            out.append({
                "artifact_date": r.get("artifact_date", ""),
                "cap_bytes": int(r.get("cap_bytes", "0") or 0),
                "label": r.get("label", ""),
                "wraps": int(float(r.get("wraps", "0") or 0)),
                "unwraps": int(float(r.get("unwraps", "0") or 0)),
                "raw_bytes": int(float(r.get("raw_bytes", "0") or 0)),
                "padded_bytes": int(float(r.get("padded_bytes", "0") or 0)),
                "overhead_ratio": float(r.get("overhead_ratio", "0") or 0.0),
                "over_cap_events": int(float(r.get("over_cap_events", "0") or 0)),
                "over_cap_rate": float(r.get("over_cap_rate", "0") or 0.0),
                "unique_buckets": int(float(r.get("unique_buckets", "0") or 0)),
                "entropy_bits": float(r.get("entropy_bits", "0") or 0.0),
                "top_bucket": r.get("top_bucket", "") or "-",
            })
        except Exception:
            continue
    return out

def generate_supp_traffic_padding_table(rows):
    """Generate supplementary traffic padding quantization summary (SBP2)."""
    # Keep a compact, paper-friendly subset (handshake labels + rx + selected data-plane sizes).
    allow = {"HS/MessageA", "HS/MessageB", "HS/Finished", "rx",
             # Control-plane (real protocol messages)
             "CP/heartbeat", "CP/systemCommand", "CP/fileTransferRequest",
             # Data-plane (binary frames, representative sizes)
             "DP/32B", "DP/300B", "DP/900B", "DP/1400B",
             "DP/4KiB", "DP/16KiB", "DP/64KiB"}
    filtered = [r for r in rows if r.get("label") in allow]

    def _dp_size(label):
        try:
            tail = label.split("/", 1)[1]
            if tail.endswith("KiB"):
                return int(tail.replace("KiB", "")) * 1024
            if tail.endswith("B"):
                return int(tail.replace("B", ""))
            return 10**9
        except Exception:
            return 10**9

    def _sort_key(r):
        label = r.get("label", "")
        if label.startswith("HS/"):
            return (0, label)
        if label == "rx":
            return (1, label)
        if label.startswith("CP/"):
            return (2, label)
        if label.startswith("DP/"):
            return (3, _dp_size(label))
        return (3, label)

    filtered.sort(key=_sort_key)

    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: SBP2 traffic padding quantization summary. ``raw''/``padded'' are aggregate bytes across events; overhead is relative to raw. Top bucket reports the most frequent bucket size (share).}",
        r"\label{tab:supp-traffic-padding}",
        r"\begin{tabular}{@{}lrrrrrl@{}}",
        r"\toprule",
        r"Label & wraps & unwraps & raw (B) & padded (B) & overhead (\%) & top bucket \\",
        r"\midrule"
    ]

    for r in filtered:
        label = _latex_escape(r.get("label", ""))
        wraps = int(float(r.get("wraps", "0") or 0))
        unwraps = int(float(r.get("unwraps", "0") or 0))
        raw_b = int(float(r.get("raw_bytes", "0") or 0))
        pad_b = int(float(r.get("padded_bytes", "0") or 0))
        overhead_ratio = float(r.get("overhead_ratio", "0") or 0.0)
        overhead_pct = (overhead_ratio - 1.0) * 100.0 if overhead_ratio > 0 else 0.0
        buckets = _parse_bucket_sizes(r.get("bucket_sizes", ""))
        top_bucket = _top_bucket_summary(buckets)

        lines.append(f"{label} & {wraps} & {unwraps} & {raw_b} & {pad_b} & {overhead_pct:.0f}\\% & {top_bucket} \\\\")

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}"
    ])

    return '\n'.join(lines)

def generate_supp_traffic_padding_sensitivity_table(rows):
    """
    Supplementary Table: SBP2 bucket-cap sensitivity study.
    We vary the maximum bucket size (cap) and report overhead (%) and entropy (bits).
    """
    labels = [
        "HS/MessageA", "HS/MessageB", "HS/Finished",
        "CP/heartbeat", "CP/systemCommand", "CP/fileTransferRequest",
        "DP/32B", "DP/300B", "DP/900B", "DP/1400B", "DP/4KiB", "DP/16KiB",
        "DP/rdpMix", "DP/fileMix",
    ]
    caps = [65536, 131072, 262144]

    idx = {(r["cap_bytes"], r["label"]): r for r in rows}

    lines = [
        r"\begin{table*}[!t]",
        r"\centering",
        r"\caption{Supplementary Table \thetable: SBP2 bucket-cap sensitivity study. We vary the maximum bucket size (cap) and report padding overhead, cap coverage (fraction of frames whose framed payload exceeds the cap), and a privacy proxy (bucket entropy) for representative handshake, control, and data-plane workloads.}",
        r"\label{tab:supp-traffic-padding-sensitivity}",
        r"\begin{tabular}{@{}lrrrrrrrrr@{}}",
        r"\toprule",
        r"Label & \multicolumn{3}{c}{64\,KiB cap} & \multicolumn{3}{c}{128\,KiB cap} & \multicolumn{3}{c}{256\,KiB cap} \\",
        r"\cmidrule(lr){2-4}\cmidrule(lr){5-7}\cmidrule(lr){8-10}",
        r" & overhead (\%) & $>$cap (\%) & entropy (b) & overhead (\%) & $>$cap (\%) & entropy (b) & overhead (\%) & $>$cap (\%) & entropy (b) \\",
        r"\midrule",
    ]

    for lab in labels:
        row = [_latex_escape(lab)]
        for cap in caps:
            r = idx.get((cap, lab))
            if not r or r["raw_bytes"] <= 0:
                row += ["-", "-", "-"]
                continue
            pct = (r["overhead_ratio"] - 1.0) * 100.0 if r["overhead_ratio"] > 0 else 0.0
            over_cap_pct = max(0.0, min(1.0, r.get("over_cap_rate", 0.0))) * 100.0
            row += [f"{pct:.0f}\\%", f"{over_cap_pct:.0f}\\%", f"{r['entropy_bits']:.2f}"]
        lines.append(" & ".join(row) + r" \\")

    lines.extend([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}",
    ])
    return "\n".join(lines)

def main():
    print("=" * 60)
    print("SkyBridge Compass Table Generator")
    print("=" * 60)

    # Find latest CSVs
    # IMPORTANT: avoid mixing new/old data across experiments.
    # We either:
    # - Use an explicit ARTIFACT_DATE=<YYYY-MM-DD>, OR
    # - Select the latest common date across all required prefixes.
    #
    # If no common date exists, we fail loudly to prevent accidentally mixing datasets in the paper.
    requested_date = os.environ.get("ARTIFACT_DATE") or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
    required_prefixes = ["handshake_bench", "handshake_rtt", "message_sizes", "traffic_padding", "traffic_padding_sensitivity"]
    artifact_date = requested_date or select_common_artifact_date(required_prefixes)
    if artifact_date is None:
        raise SystemExit(
            "ERROR: No common ARTIFACT_DATE across required prefixes "
            f"{required_prefixes}. Run Scripts/run_paper_eval.sh to regenerate a consistent set, "
            "or set ARTIFACT_DATE=YYYY-MM-DD explicitly."
        )

    latency_csv = select_artifact_csv("handshake_bench", artifact_date, strict=True)
    rtt_csv = select_artifact_csv("handshake_rtt", artifact_date, strict=True)
    msg_csv = select_artifact_csv("message_sizes", artifact_date, strict=True)
    traffic_csv = select_artifact_csv("traffic_padding", artifact_date, strict=True)
    sens_csv = select_artifact_csv("traffic_padding_sensitivity", artifact_date, strict=True)

    print(f"\nUsing data files:")
    print(f"  Latency: {latency_csv}")
    print(f"  RTT: {rtt_csv}")
    print(f"  Message Sizes: {msg_csv}")
    print(f"  Traffic Padding: {traffic_csv}")
    print(f"  Traffic Padding Sensitivity: {sens_csv}")
    print(f"  -> ARTIFACT_DATE locked: {artifact_date}")

    # Parse data
    latency = parse_handshake_bench(latency_csv) if latency_csv else {}
    rtt = parse_rtt(rtt_csv) if rtt_csv else {}
    msg_sizes = parse_message_sizes(msg_csv) if msg_csv else {}
    latency_runs = parse_handshake_bench_runs(latency_csv) if latency_csv else {}
    rtt_runs = parse_rtt_runs(rtt_csv) if rtt_csv else {}
    traffic_rows = parse_traffic_padding(traffic_csv) if traffic_csv else []
    sens_rows = parse_traffic_padding_sensitivity(sens_csv) if sens_csv else []

    # Generate tables
    print("\nGenerating tables...")

    # Main Performance Summary Table
    perf_summary = generate_perf_summary_table(latency, rtt, msg_sizes)
    perf_path = TABLES_DIR / "perf_summary.tex"
    with open(perf_path, 'w') as f:
        f.write(f"% Auto-generated by make_tables.py on {datetime.now().isoformat()}\n")
        f.write(f"% DO NOT EDIT MANUALLY - regenerate from CSV artifacts\n\n")
        f.write(perf_summary)
    print(f"  -> {perf_path}")

    # Supplementary tables
    supp_lat = generate_supp_latency_table(latency)
    supp_lat_path = SUPP_DIR / "s1_latency.tex"
    with open(supp_lat_path, 'w') as f:
        f.write(f"% Auto-generated by make_tables.py\n\n")
        f.write(supp_lat)
    print(f"  -> {supp_lat_path}")

    supp_rtt = generate_supp_rtt_table(rtt)
    supp_rtt_path = SUPP_DIR / "s2_rtt.tex"
    with open(supp_rtt_path, 'w') as f:
        f.write(f"% Auto-generated by make_tables.py\n\n")
        f.write(supp_rtt)
    print(f"  -> {supp_rtt_path}")

    supp_msg = generate_supp_message_sizes_table(msg_sizes)
    supp_msg_path = SUPP_DIR / "s3_message_sizes.tex"
    with open(supp_msg_path, 'w') as f:
        f.write(f"% Auto-generated by make_tables.py\n\n")
        f.write(supp_msg)
    print(f"  -> {supp_msg_path}")

    # Traffic padding (SBP2) quantization summary
    if traffic_rows:
        supp_tp = generate_supp_traffic_padding_table(traffic_rows)
        supp_tp_path = SUPP_DIR / "s7_traffic_padding.tex"
        with open(supp_tp_path, 'w') as f:
            f.write(f"% Auto-generated by make_tables.py\n\n")
            f.write(supp_tp)
        print(f"  -> {supp_tp_path}")

    # Traffic padding sensitivity study (SBP2 cap)
    if sens_rows:
        supp_sens = generate_supp_traffic_padding_sensitivity_table(sens_rows)
        supp_sens_path = SUPP_DIR / "s8_traffic_padding_sensitivity.tex"
        with open(supp_sens_path, 'w') as f:
            f.write(f"% Auto-generated by make_tables.py\n\n")
            f.write(supp_sens)
        print(f"  -> {supp_sens_path}")

    # Repeatability tables (multi-batch CI)
    supp_rep_lat = generate_repeatability_latency_table(latency_runs)
    supp_rep_lat_path = SUPP_DIR / "s5_repeatability_latency.tex"
    with open(supp_rep_lat_path, 'w') as f:
        f.write(f"% Auto-generated by make_tables.py\n\n")
        f.write(supp_rep_lat)
    print(f"  -> {supp_rep_lat_path}")

    supp_rep_rtt = generate_repeatability_rtt_table(rtt_runs)
    supp_rep_rtt_path = SUPP_DIR / "s6_repeatability_rtt.tex"
    with open(supp_rep_rtt_path, 'w') as f:
        f.write(f"% Auto-generated by make_tables.py\n\n")
        f.write(supp_rep_rtt)
    print(f"  -> {supp_rep_rtt_path}")

    # Print summary for Abstract verification
    print("\n" + "=" * 60)
    print("NUMBERS FOR ABSTRACT VERIFICATION:")
    print("=" * 60)
    for config in ['Classic (X25519 + Ed25519)',
                   'liboqs PQC (ML-KEM-768 + ML-DSA-65)',
                   'CryptoKit PQC (ML-KEM-768 + ML-DSA-65)']:
        if config in latency:
            d = latency[config]
            print(f"{short_config(config)}:")
            print(f"  Latency: {d['mean']:.2f} ms (p95 {d['p95']:.2f} ms)")

    print("\nDone!")

if __name__ == "__main__":
    main()
