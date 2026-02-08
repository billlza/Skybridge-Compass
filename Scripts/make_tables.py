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

# System impact canonical suite ids (Artifacts/system_impact_<date>.csv)
SYSTEM_IMPACT_SUITES = [
    ("classic", "Classic"),
    ("pqc_liboqs", "liboqs PQC"),
    ("pqc_cryptokit", "CryptoKit PQC"),
]

# System impact canonical network conditions (Artifacts/system_impact_<date>.csv)
SYSTEM_IMPACT_CONDITIONS = [
    ("ideal", "ideal"),
    ("rtt50_j20", "RTT 50$\\pm$20 ms"),
    ("rtt100_j50", "RTT 100$\\pm$50 ms"),
]

# Prefer these file sizes (bytes) for amortization reporting if present.
SYSTEM_IMPACT_PREFERRED_FILE_BYTES = [
    1 * 1024 * 1024,
    10 * 1024 * 1024,
    100 * 1024 * 1024,
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

def _artifact_date_from_main_tex() -> str | None:
    """
    Prefer the artifact date pinned in the main paper TeX to avoid accidentally
    selecting placeholder/future artifacts (e.g., 2099-01-01).
    """
    tex = PROJECT_ROOT / "Docs" / "TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
    if not tex.exists():
        return None
    try:
        s = tex.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return None
    # \newcommand{\artifactdate}{YYYY-MM-DD}
    import re
    m = re.search(r"\\newcommand\\{\\artifactdate\\}\\{([^}]+)\\}", s)
    if not m:
        return None
    v = (m.group(1) or "").strip()
    return v if v else None

def _is_future_date(yyyy_mm_dd: str, today: str) -> bool:
    # Lexicographic compare is safe for YYYY-MM-DD.
    return yyyy_mm_dd > today

def _read_csv_rows(filepath):
    with open(filepath, 'r', newline='') as f:
        return list(csv.DictReader(f))

def _percentile(samples: list[float], p: float) -> float:
    if not samples:
        return float("nan")
    xs = sorted(samples)
    if len(xs) == 1:
        return xs[0]
    idx = int((len(xs) - 1) * p)
    return xs[max(0, min(idx, len(xs) - 1))]

def _fmt_ms_p50_p95(samples_ms: list[float], decimals: int = 1) -> str:
    p50 = _percentile(samples_ms, 0.50)
    p95 = _percentile(samples_ms, 0.95)
    if math.isnan(p50) or math.isnan(p95):
        return "--"
    return f"{p50:.{decimals}f}/{p95:.{decimals}f}"

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
        r"\caption{Supplementary Table \thetable: Repeatability across independent benchmark batches (latency). Table reports observed batch count $B$. Cells report mean and (when $B \ge 2$) $\pm$ 95\% CI across batches; each batch uses N=1000 iterations after 10 warmup runs.}",
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
        if b < 2:
            mean_cell = f"${mean_mu:.3f}$"
            p50_cell = f"${p50_mu:.3f}$"
            p95_cell = f"${p95_mu:.3f}$"
        else:
            # LaTeX plus/minus is `\pm` (single backslash). Do NOT emit `\\pm` (linebreak + "pm").
            mean_cell = f"${mean_mu:.3f} \\pm {mean_ci:.3f}$"
            p50_cell = f"${p50_mu:.3f} \\pm {p50_ci:.3f}$"
            p95_cell = f"${p95_mu:.3f} \\pm {p95_ci:.3f}$"
        line = (
            f"{short} & {b} & {n_per} & "
            f"{mean_cell} & "
            f"{p50_cell} & "
            f"{p95_cell} \\\\"
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
        r"\caption{Supplementary Table \thetable: Repeatability across independent benchmark batches (RTT). Table reports observed batch count $B$. Cells report mean and (when $B \ge 2$) $\pm$ 95\% CI across batches; each batch uses N=1000 iterations after 10 warmup runs.}",
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
        if b < 2:
            mean_cell = f"${mean_mu:.3f}$"
            p50_cell = f"${p50_mu:.3f}$"
            p95_cell = f"${p95_mu:.3f}$"
        else:
            # LaTeX plus/minus is `\pm` (single backslash). Do NOT emit `\\pm` (linebreak + "pm").
            mean_cell = f"${mean_mu:.3f} \\pm {mean_ci:.3f}$"
            p50_cell = f"${p50_mu:.3f} \\pm {p50_ci:.3f}$"
            p95_cell = f"${p95_mu:.3f} \\pm {p95_ci:.3f}$"
        line = (
            f"{short} & {b} & {n_per} & "
            f"{mean_cell} & "
            f"{p50_cell} & "
            f"{p95_cell} \\\\"
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
        r"\caption{Performance Summary. All benchmarks on Apple Silicon (M1/M3), macOS 26.x, N=1000 iterations after 10 warmup runs. Wire Size counts payload-only handshake bytes (MessageA + MessageB + 2$\times$Finished); loopback wire sizes including transport overhead are reported separately in Table~\ref{tab:baseline-comparison} and Supplementary Table~\ref{tab:supp-loopback-wire}. Data-plane AEAD is fixed to AES-256-GCM in v1, so throughput is independent of the negotiated handshake suite; throughput measured post-handshake on 1~MiB payloads.}",
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
        r"\scriptsize",
        r"\setlength{\tabcolsep}{3pt}",
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

def parse_system_impact(filepath: Path) -> list[dict[str, str]]:
    """Parse system_impact CSV rows (raw)."""
    return _read_csv_rows(filepath)

def generate_system_impact_table(rows: list[dict[str, str]], source_csv_name: str | None = None) -> str:
    """
    Generate main paper table for system-level impact.

    Columns:
    - T_connect p50/p95 (ms) across conditions
    - T_total p50/p95 (ms) for selected file sizes under RTT 50±20ms
    """
    present_file_bytes = sorted({int(r["file_bytes"]) for r in rows if r.get("file_bytes")})
    chosen_file_bytes = [b for b in SYSTEM_IMPACT_PREFERRED_FILE_BYTES if b in present_file_bytes]
    if not chosen_file_bytes:
        chosen_file_bytes = present_file_bytes[:2]

    def samples_for(condition: str, suite: str, file_bytes: int, metric: str) -> list[float]:
        out: list[float] = []
        for r in rows:
            if r.get("condition") != condition:
                continue
            if r.get("suite") != suite:
                continue
            if int(r.get("file_bytes", "0") or "0") != int(file_bytes):
                continue
            v = r.get(metric)
            if v is None or v == "":
                continue
            try:
                x = float(v)
            except ValueError:
                continue
            if math.isnan(x) or math.isinf(x):
                continue
            out.append(x)
        return out

    connect_file_bytes = min(chosen_file_bytes) if chosen_file_bytes else (present_file_bytes[0] if present_file_bytes else 0)
    file_cols = " & ".join([f"{int(b/(1024*1024))} MiB" for b in chosen_file_bytes])

    # Compute N for transparency (reviewer-friendly).
    def _count_rows(condition: str, suite: str, file_bytes: int, metric: str) -> int:
        n = 0
        for r in rows:
            if r.get("condition") != condition:
                continue
            if r.get("suite") != suite:
                continue
            if int(r.get("file_bytes", "0") or "0") != int(file_bytes):
                continue
            v = r.get(metric)
            if v is None or v == "":
                continue
            try:
                x = float(v)
            except ValueError:
                continue
            if math.isnan(x):
                continue
            n += 1
        return n

    n_connect = min(
        _count_rows(cond_id, suite_id, connect_file_bytes, "t_connect_ms")
        for cond_id, _ in SYSTEM_IMPACT_CONDITIONS
        for suite_id, _ in SYSTEM_IMPACT_SUITES
    ) if rows else 0
    n_total_by_size = {
        int(b/(1024*1024)): min(
            _count_rows("rtt50_j20", suite_id, b, "t_file_total_ms")
            for suite_id, _ in SYSTEM_IMPACT_SUITES
        )
        for b in chosen_file_bytes
    }
    n_total_str = ", ".join([f"{k}MiB:N={v}" for k, v in n_total_by_size.items()])

    lines: list[str] = []
    lines.append(r"\begin{table*}[!t]")
    lines.append(r"\centering")
    source = source_csv_name or "system_impact_<date>.csv"
    lines.append(
        r"\caption{System-level impact and amortization (p50/p95, ms). "
        r"$T_{connect}$ is measured from connect start to handshake established (including Finished key confirmation and event emission). "
        r"$T_{total}$ is measured from connect start to completion of an encrypted bulk transfer. "
        r"Network conditions emulate deterministic RTT+jitter on a reliable stream; large data-plane payloads are bandwidth-limited (MiB/s) to avoid per-chunk RTT artifacts. "
        rf"Runs: $N_{{connect}}$={n_connect}; $N_{{total}}$ (RTT 50$\pm$20 ms) = {n_total_str}. "
        rf"Data from \texttt{{Artifacts/{source.replace('_', r'\_')}}}.}}"
    )
    lines.append(r"\label{tab:system-impact}")
    lines.append(r"\small")
    colspec = "l" + ("c" * (len(SYSTEM_IMPACT_CONDITIONS) + len(chosen_file_bytes)))
    lines.append(rf"\begin{{tabular}}{{@{{}}{colspec}@{{}}}}")
    lines.append(r"\toprule")
    lines.append(
        rf"& \multicolumn{{{len(SYSTEM_IMPACT_CONDITIONS)}}}{{c}}{{\textbf{{$T_{{connect}}$ (p50/p95)}}}}"
        rf" & \multicolumn{{{len(chosen_file_bytes)}}}{{c}}{{\textbf{{$T_{{total}}$ (p50/p95), RTT 50$\pm$20 ms}}}} \\"
    )
    lines.append(
        rf"\cmidrule(lr){{2-{1+len(SYSTEM_IMPACT_CONDITIONS)}}} "
        rf"\cmidrule(lr){{{2+len(SYSTEM_IMPACT_CONDITIONS)}-{1+len(SYSTEM_IMPACT_CONDITIONS)+len(chosen_file_bytes)}}}"
    )
    header_conds = " & ".join([label for _, label in SYSTEM_IMPACT_CONDITIONS])
    lines.append(rf"\textbf{{Suite}} & {header_conds} & {file_cols} \\")
    lines.append(r"\midrule")

    for suite_id, suite_label in SYSTEM_IMPACT_SUITES:
        connect_cells: list[str] = []
        for cond_id, _ in SYSTEM_IMPACT_CONDITIONS:
            vals = samples_for(cond_id, suite_id, connect_file_bytes, "t_connect_ms")
            connect_cells.append(_fmt_ms_p50_p95(vals, decimals=1))

        total_cells: list[str] = []
        for fb in chosen_file_bytes:
            vals = samples_for("rtt50_j20", suite_id, fb, "t_file_total_ms")
            decimals = 1 if (vals and max(vals) < 1000) else 0
            total_cells.append(_fmt_ms_p50_p95(vals, decimals=decimals))

        row = " & ".join([r"\textbf{" + _latex_escape(suite_label) + "}", *connect_cells, *total_cells]) + r" \\"
        lines.append(row)

    lines.append(r"\bottomrule")
    lines.append(r"\end{tabular}")
    lines.append(r"\end{table*}")
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
    if requested_date:
        requested_date = requested_date.strip()

    # If not explicitly pinned, prefer the date pinned in the main paper TeX.
    if not requested_date:
        requested_date = _artifact_date_from_main_tex()

    today = datetime.now().date().isoformat()

    # Convenience: generate only the system-impact table (no dependency on other artifact sets).
    if os.environ.get("SKYBRIDGE_ONLY_SYSTEM_IMPACT_TABLE") == "1":
        if not requested_date:
            latest = find_latest_csv("system_impact")
            if latest is None:
                raise SystemExit(f"ERROR: No system_impact_*.csv found in {ARTIFACTS_DIR}")
            requested_date = latest.name[len("system_impact_"):-4]
        sys_csv = select_artifact_csv("system_impact", requested_date, strict=True)
        sys_rows = parse_system_impact(sys_csv)
        sys_table = generate_system_impact_table(sys_rows, source_csv_name=sys_csv.name if sys_csv else None)
        sys_table = generate_system_impact_table(sys_rows, source_csv_name=system_impact_csv.name if system_impact_csv else None)
        sys_path = TABLES_DIR / "system_impact.tex"
        with open(sys_path, "w") as f:
            f.write(f"% Auto-generated by make_tables.py on {datetime.now().isoformat()}\n")
            f.write(f"% DO NOT EDIT MANUALLY - regenerate from CSV artifacts\n")
            f.write(f"% Source: {sys_csv.name}\n\n")
            f.write(sys_table)
        print(f"  -> {sys_path}")
        print("\nDone!")
        return

    required_prefixes = ["handshake_bench", "handshake_rtt", "message_sizes", "traffic_padding", "traffic_padding_sensitivity"]

    artifact_date = requested_date or select_common_artifact_date(required_prefixes)
    if artifact_date and not requested_date and _is_future_date(artifact_date, today):
        # Avoid selecting placeholder future artifacts unless the user explicitly pinned it.
        # Pick the latest common date that is not in the future.
        common_dates = None
        for pref in required_prefixes:
            dates = _date_suffixes_for_prefix(pref)
            common_dates = dates if common_dates is None else (common_dates & dates)
        candidates = sorted([d for d in (common_dates or set()) if not _is_future_date(d, today)])
        artifact_date = candidates[-1] if candidates else artifact_date

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
    system_impact_csv = select_artifact_csv("system_impact", artifact_date, strict=False)

    print(f"\nUsing data files:")
    print(f"  Latency: {latency_csv}")
    print(f"  RTT: {rtt_csv}")
    print(f"  Message Sizes: {msg_csv}")
    print(f"  Traffic Padding: {traffic_csv}")
    print(f"  Traffic Padding Sensitivity: {sens_csv}")
    print(f"  System Impact: {system_impact_csv}")
    print(f"  -> ARTIFACT_DATE locked: {artifact_date}")

    # Parse data
    latency = parse_handshake_bench(latency_csv) if latency_csv else {}
    rtt = parse_rtt(rtt_csv) if rtt_csv else {}
    msg_sizes = parse_message_sizes(msg_csv) if msg_csv else {}
    latency_runs = parse_handshake_bench_runs(latency_csv) if latency_csv else {}
    rtt_runs = parse_rtt_runs(rtt_csv) if rtt_csv else {}
    traffic_rows = parse_traffic_padding(traffic_csv) if traffic_csv else []
    sens_rows = parse_traffic_padding_sensitivity(sens_csv) if sens_csv else []
    system_rows = parse_system_impact(system_impact_csv) if system_impact_csv else []

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

    # System impact table (optional; requires matching ARTIFACT_DATE to avoid mixing datasets)
    if system_rows:
        sys_table = generate_system_impact_table(
            system_rows,
            source_csv_name=system_impact_csv.name if system_impact_csv else None,
        )
        sys_path = TABLES_DIR / "system_impact.tex"
        with open(sys_path, "w") as f:
            f.write(f"% Auto-generated by make_tables.py on {datetime.now().isoformat()}\n")
            f.write(f"% DO NOT EDIT MANUALLY - regenerate from CSV artifacts\n")
            f.write(f"% Source: {system_impact_csv.name if system_impact_csv else 'N/A'}\n\n")
            f.write(sys_table)
        print(f"  -> {sys_path}")
    else:
        print("  -> (skip) system_impact table: missing Artifacts/system_impact_<ARTIFACT_DATE>.csv")

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
