#!/usr/bin/env python3
"""
Generate IEEE-quality PDF figures for SkyBridge Compass paper.
All figures are vector format with consistent styling.
"""

import matplotlib
# Force a headless backend so this script runs reliably in CI/sandboxed environments.
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import csv
import math
import os
from pathlib import Path

# IEEE-style configuration
# CRITICAL: pdf.fonttype=42 and ps.fonttype=42 force TrueType embedding
# instead of Type 3 fonts, which is required for IEEE PDF eXpress compliance
plt.rcParams.update({
    'font.family': 'serif',
    'font.serif': ['Times New Roman', 'Times', 'DejaVu Serif'],
    'font.size': 8,
    'axes.labelsize': 8,
    'axes.titlesize': 9,
    'xtick.labelsize': 7,
    'ytick.labelsize': 7,
    'legend.fontsize': 7,
    'figure.dpi': 300,
    'savefig.dpi': 300,
    'savefig.bbox': 'tight',
    'savefig.pad_inches': 0.02,
    'axes.linewidth': 0.5,
    'grid.linewidth': 0.3,
    'lines.linewidth': 1.0,
    'patch.linewidth': 0.5,
    # Force TrueType (Type 42) font embedding - eliminates Type 3 fonts
    'pdf.fonttype': 42,
    'ps.fonttype': 42,
    # Use TeX-compatible math rendering
    'mathtext.fontset': 'stix',
})

# IEEE single column width: ~3.5 inches
COL_WIDTH = 3.5
# Colors - grayscale friendly
COLORS = {
    'classic': '#2E86AB',      # Blue
    'liboqs': '#A23B72',       # Magenta
    'cryptokit': '#F18F01',    # Orange
    'gray1': '#404040',
    'gray2': '#808080',
    'gray3': '#C0C0C0',
}

ROOT_DIR = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = ROOT_DIR / "Artifacts"
OUTPUT_DIR = str(ROOT_DIR / "figures")

def _requested_artifact_date() -> str | None:
    v = os.environ.get("ARTIFACT_DATE") or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
    return v if v else None

def _latest_artifact_csv(prefix: str) -> Path:
    candidates = list(ARTIFACTS_DIR.glob(f"{prefix}_*.csv"))
    if not candidates:
        raise FileNotFoundError(f"No {prefix}_*.csv found in {ARTIFACTS_DIR}")
    return max(candidates, key=lambda p: p.stat().st_mtime)

def _artifact_csv(prefix: str) -> Path:
    """
    Select an artifact CSV by prefix. If ARTIFACT_DATE is set, require
    Artifacts/<prefix>_<ARTIFACT_DATE>.csv to exist (prevents mixing datasets).
    """
    date = _requested_artifact_date()
    if date:
        p = ARTIFACTS_DIR / f"{prefix}_{date}.csv"
        if not p.exists():
            raise FileNotFoundError(f"Missing required artifact for ARTIFACT_DATE={date}: {p}")
        return p
    return _latest_artifact_csv(prefix)

def _read_csv_dicts(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

def _pick_last_row(rows: list[dict[str, str]], predicate) -> dict[str, str]:
    for row in reversed(rows):
        if predicate(row):
            return row
    raise KeyError("No matching row found")

def _save_figure(basename: str) -> None:
    pdf_path = f"{OUTPUT_DIR}/{basename}.pdf"
    png_path = f"{OUTPUT_DIR}/{basename}.png"
    plt.savefig(pdf_path, format="pdf")
    plt.savefig(png_path, format="png")
    print(f"Generated: {basename}.pdf (+ preview PNG)")

def _wilson_95_ci(k: int, n: int) -> tuple[float, float]:
    if n <= 0:
        return (0.0, 0.0)
    z = 1.96
    p = k / n
    denom = 1 + (z * z) / n
    center = (p + (z * z) / (2 * n)) / denom
    half = (z * math.sqrt((p * (1 - p) + (z * z) / (4 * n)) / n)) / denom
    return (max(0.0, center - half), min(1.0, center + half))

def fig_handshake_latency():
    """Figure: Handshake latency percentiles comparison."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 2.2))

    configs = [
        "Classic\n(X25519+Ed25519)",
        "liboqs PQC\n(ML-KEM+ML-DSA)",
        "CryptoKit PQC\n(ML-KEM+ML-DSA)",
    ]
    csv_path = _artifact_csv("handshake_bench")

    # Keep Fig.8 aligned with Table 7 / Supplementary Table S1:
    # select a representative complete batch instead of "last row".
    try:
        from make_tables import ORDERED_PERF_CONFIGS, parse_handshake_bench  # type: ignore
    except Exception as e:  # pragma: no cover
        raise RuntimeError("Failed to import Scripts/make_tables.py; cannot select representative batch") from e

    batch = parse_handshake_bench(csv_path)
    required = set(ORDERED_PERF_CONFIGS)
    if not required.issubset(batch.keys()):
        missing = ", ".join(sorted(required - set(batch.keys())))
        raise RuntimeError(f"handshake_bench batch missing configs: {missing} (csv={csv_path.name})")

    p50 = [batch[cfg]["p50"] for cfg in ORDERED_PERF_CONFIGS]
    p95 = [batch[cfg]["p95"] for cfg in ORDERED_PERF_CONFIGS]
    p99 = [batch[cfg]["p99"] for cfg in ORDERED_PERF_CONFIGS]

    x = np.arange(len(configs))
    width = 0.25

    bars1 = ax.bar(x - width, p50, width, label='p50', color=COLORS['gray1'], edgecolor='black', linewidth=0.5)
    bars2 = ax.bar(x, p95, width, label='p95', color=COLORS['gray2'], edgecolor='black', linewidth=0.5)
    bars3 = ax.bar(x + width, p99, width, label='p99', color=COLORS['gray3'], edgecolor='black', linewidth=0.5)

    ax.set_ylabel('Latency (ms)')
    ax.set_xticks(x)
    ax.set_xticklabels(configs)
    ax.legend(loc='upper left', framealpha=0.9)
    ymax = max(p99) if p99 else 1.0
    ax.set_ylim(0, max(1.0, ymax * 1.25))
    ax.grid(axis='y', linestyle='--', alpha=0.5)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Add value labels on bars
    for bars in [bars1, bars2, bars3]:
        for bar in bars:
            height = bar.get_height()
            if height > 5:
                ax.annotate(f'{height:.1f}',
                           xy=(bar.get_x() + bar.get_width()/2, height),
                           xytext=(0, 2), textcoords="offset points",
                           ha='center', va='bottom', fontsize=6)

    plt.tight_layout()
    _save_figure("fig_handshake_latency")
    plt.close()

def fig_policy_downgrade():
    """Figure: Policy guard strictPQC vs default."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 1.8))

    csv_path = _artifact_csv("policy_downgrade")
    rows = _read_csv_dicts(csv_path)

    def policy_row(name: str) -> dict[str, str]:
        return _pick_last_row(rows, lambda r: r.get("policy") == name)

    policies = ['strictPQC', 'default']
    per_policy = []
    for name in policies:
        row = policy_row(name)
        iterations = int(row["iterations"])
        fallback = int(row["fallback_events"])
        classic = int(row.get("classic_attempts", "0"))
        per_policy.append({
            "iterations": iterations,
            "fallback": fallback,
            "classic": classic,
        })

    fallback_events = [p["fallback"] * 1000 / max(p["iterations"], 1) for p in per_policy]
    classic_attempts = [p["classic"] * 1000 / max(p["iterations"], 1) for p in per_policy]

    fallback_err = []
    for p in per_policy:
        lo, hi = _wilson_95_ci(p["fallback"], p["iterations"])
        v = p["fallback"] / max(p["iterations"], 1) * 1000
        fallback_err.append((v - lo * 1000, hi * 1000 - v))

    x = np.arange(len(policies))
    width = 0.35

    bars1 = ax.bar(
        x - width/2,
        fallback_events,
        width,
        label='Fallback Events',
        yerr=np.array(fallback_err).T,
        capsize=2,
                   color=COLORS['gray1'], edgecolor='black', linewidth=0.5)
    bars2 = ax.bar(x + width/2, classic_attempts, width, label='Classic Attempts',
                   color=COLORS['gray3'], edgecolor='black', linewidth=0.5)

    ax.set_ylabel('Count (N=1000)')
    ax.set_xticks(x)
    ax.set_xticklabels(policies)
    ax.legend(loc='upper left', framealpha=0.9)
    ax.set_ylim(0, 1100)
    ax.grid(axis='y', linestyle='--', alpha=0.5)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Add value labels
    for bar in bars1:
        ax.annotate(f'{int(bar.get_height())}',
                   xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                   xytext=(0, 2), textcoords="offset points",
                   ha='center', va='bottom', fontsize=7)
    for bar in bars2:
        if bar.get_height() > 0:
            ax.annotate(f'{int(bar.get_height())}',
                       xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                       xytext=(0, 2), textcoords="offset points",
                       ha='center', va='bottom', fontsize=7)

    plt.tight_layout()
    _save_figure("fig_policy_downgrade")
    plt.close()

def fig_downgrade_matrix():
    """Figure: Downgrade decision matrix."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 2.0))

    errors = ['pqcProvider\nUnavailable', 'suiteNegotiation\nFailed', 'timeout', 'signature\nVerifyFailed', 'identity\nMismatch']
    policies = ['default', 'strictPQC']

    # Matrix: 1=allow, 0=deny
    matrix = np.array([
        [1, 1, 0, 0, 0],  # default
        [0, 0, 0, 0, 0],  # strictPQC
    ])

    im = ax.imshow(matrix, cmap='RdYlGn', aspect='auto', vmin=0, vmax=1)

    ax.set_xticks(np.arange(len(errors)))
    ax.set_yticks(np.arange(len(policies)))
    ax.set_xticklabels(errors, fontsize=6)
    ax.set_yticklabels(policies)

    # Add text annotations
    for i in range(len(policies)):
        for j in range(len(errors)):
            text = 'Allow' if matrix[i, j] == 1 else 'Deny'
            color = 'white' if matrix[i, j] == 0 else 'black'
            ax.text(j, i, text, ha='center', va='center', color=color, fontsize=7, fontweight='bold')

    ax.set_xlabel('Error Type')
    ax.set_ylabel('Policy')

    plt.tight_layout()
    _save_figure("fig_downgrade_matrix")
    plt.close()

def fig_failure_histogram():
    """Figure: Failure-mode histogram of security events."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 2.0))

    fi_path = _artifact_csv("fault_injection")
    fi_rows = _read_csv_dicts(fi_path)

    def fi_row(policy: str, scenario: str) -> dict[str, str]:
        return _pick_last_row(fi_rows, lambda r: r.get("policy") == policy and r.get("scenario") == scenario)

    policy_path = _artifact_csv("policy_downgrade")
    policy_rows = _read_csv_dicts(policy_path)
    default_policy = _pick_last_row(policy_rows, lambda r: r.get("policy") == "default")
    downgrade_count = int(default_policy["fallback_events"])

    scenarios = [
        ('Drop', 'drop'),
        ('Timeout', 'delay_exceed_timeout'),
        ('Corrupt\nHeader', 'corrupt_header'),
        ('Corrupt\nPayload', 'corrupt_payload'),
        ('Wrong\nSig', 'wrong_signature'),
        ('Concurrent\nCancel', 'concurrent_cancel'),
        ('PQC\nUnavailable', None),
    ]

    failed_events = []
    downgrade_events = []
    for _, key in scenarios:
        if key is None:
            failed_events.append(0)
            downgrade_events.append(downgrade_count)
            continue
        row = fi_row("default", key)
        failed_events.append(int(row.get("E_handshakeFailed", 0)))
        downgrade_events.append(int(row.get("E_cryptoDowngrade", 0)))

    x = np.arange(len(scenarios))
    width = 0.35

    bars1 = ax.bar(x - width/2, failed_events, width, label='handshakeFailed',
                   color=COLORS['gray1'], edgecolor='black', linewidth=0.5)
    bars2 = ax.bar(x + width/2, downgrade_events, width, label='cryptoDowngrade',
                   color=COLORS['gray3'], edgecolor='black', linewidth=0.5)

    ax.set_ylabel('Event Count (N=1000)')
    ax.set_xticks(x)
    ax.set_xticklabels([s[0] for s in scenarios], fontsize=6)
    ax.legend(loc='lower right', bbox_to_anchor=(1.0, 1.04), framealpha=0.9)
    ax.set_ylim(0, 1200)
    ax.grid(axis='y', linestyle='--', alpha=0.5)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    plt.tight_layout()
    _save_figure("fig_failure_histogram")
    plt.close()

def fig_message_size_breakdown():
    """Figure: Handshake message size breakdown (payload-only bytes)."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 2.2))

    messages = ["MessageA\nClassic", "MessageB\nClassic", "MessageA\nPQC", "MessageB\nPQC"]
    csv_path = _artifact_csv("message_sizes")
    rows = _read_csv_dicts(csv_path)
    by_message = {r["message"]: r for r in rows if r.get("message")}

    ordered_keys = ["MessageA.Classic", "MessageB.Classic", "MessageA.PQC", "MessageB.PQC"]
    missing = [key for key in ordered_keys if key not in by_message]
    if missing:
        raise RuntimeError(f"message_sizes CSV missing rows: {', '.join(missing)} (csv={csv_path.name})")

    signature = [int(by_message[key]["signature_bytes"]) for key in ordered_keys]
    keyshare = [int(by_message[key]["keyshare_bytes"]) for key in ordered_keys]
    identity = [int(by_message[key]["identity_bytes"]) for key in ordered_keys]
    overhead = [int(by_message[key]["overhead_bytes"]) for key in ordered_keys]
    totals = [int(by_message[key]["total_bytes"]) for key in ordered_keys]

    x = np.arange(len(messages))
    width = 0.6

    ax.bar(x, signature, width, label='Signature', color=COLORS['gray1'], edgecolor='black', linewidth=0.5)
    ax.bar(x, keyshare, width, bottom=signature, label='KeyShare', color=COLORS['gray2'], edgecolor='black', linewidth=0.5)
    bottom2 = [s+k for s,k in zip(signature, keyshare)]
    ax.bar(x, identity, width, bottom=bottom2, label='Identity', color=COLORS['gray3'], edgecolor='black', linewidth=0.5)
    bottom3 = [b+i for b,i in zip(bottom2, identity)]
    # NOTE: Avoid hatch patterns here because Matplotlib encodes hatches as Type 3 fonts in PDFs,
    # which can fail IEEE PDF eXpress checks. Use a white fill with dashed outline instead.
    ax.bar(x, overhead, width, bottom=bottom3, label='Overhead',
           color='white', edgecolor='black', linewidth=0.5, linestyle='--')

    ax.set_ylabel('Size (bytes)')
    ax.set_xticks(x)
    ax.set_xticklabels(messages, fontsize=7)
    ax.legend(loc='upper left', framealpha=0.9, fontsize=6)
    ax.grid(axis='y', linestyle='--', alpha=0.5)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Add total labels
    for i, (xi, total) in enumerate(zip(x, totals)):
        ax.annotate(f'{total}B', xy=(xi, total), xytext=(0, 3),
                   textcoords="offset points", ha='center', va='bottom', fontsize=6)

    plt.tight_layout()
    _save_figure("fig_message_size_breakdown")
    plt.close()

def fig_event_traces():
    """Figure: Audit-signal event trace (timeout case)."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 1.6))

    # Timeline representation
    events = [
        ('Attacker\ndrops packet', 0, COLORS['gray1']),
        ('Timeout\nexpires', 1, COLORS['gray2']),
        ('Policy gate:\nDeny fallback', 2, COLORS['gray2']),
        ('Emit:\nhandshakeFailed', 3, COLORS['gray3']),
    ]

    for label, x, color in events:
        ax.add_patch(plt.Rectangle((x-0.4, 0.3), 0.8, 0.4, facecolor=color, edgecolor='black', linewidth=0.5))
        ax.text(x, 0.5, label, ha='center', va='center', fontsize=6, fontweight='bold')

    # Arrows
    for i in range(len(events)-1):
        ax.annotate('', xy=(events[i+1][1]-0.4, 0.5), xytext=(events[i][1]+0.4, 0.5),
                   arrowprops=dict(arrowstyle='->', color='black', lw=1))

    ax.set_xlim(-0.6, 3.6)
    ax.set_ylim(0, 1)
    ax.axis('off')

    plt.tight_layout()
    _save_figure("fig_event_traces")
    plt.close()

def fig_handshake_sequence():
    """Figure: Handshake sequence diagram with transcript coverage."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 3.0))

    # Lifelines
    ax.plot([0.2, 0.2], [0.1, 0.95], 'k-', linewidth=1)
    ax.plot([0.8, 0.8], [0.1, 0.95], 'k-', linewidth=1)

    # Labels
    ax.text(0.2, 0.98, 'Initiator', ha='center', va='bottom', fontsize=8, fontweight='bold')
    ax.text(0.8, 0.98, 'Responder', ha='center', va='bottom', fontsize=8, fontweight='bold')

    # Messages
    messages = [
        (0.85, 'MessageA: suites[], keyShares[], nonce_I, sigA', 0.2, 0.8),
        (0.65, 'MessageB: selectedSuite, keyShare, nonce_R, sigB', 0.8, 0.2),
        (0.45, 'Finished_R2I: HMAC(transcriptHash)', 0.8, 0.2),
        (0.25, 'Finished_I2R: HMAC(transcriptHash)', 0.2, 0.8),
    ]

    for y, label, x1, x2 in messages:
        ax.annotate('', xy=(x2, y), xytext=(x1, y),
                   arrowprops=dict(arrowstyle='->', color='black', lw=1))
        ax.text((x1+x2)/2, y+0.02, label, ha='center', va='bottom', fontsize=5.5)

    # Transcript coverage box
    ax.add_patch(plt.Rectangle((0.05, 0.55), 0.9, 0.35, fill=False,
                                edgecolor='gray', linestyle='--', linewidth=0.5))
    ax.text(0.5, 0.95, 'sigB covers: MessageA + selectedSuite',
            ha='center', va='bottom', fontsize=4.8, style='italic', color='gray')

    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1.05)
    ax.axis('off')

    plt.tight_layout()
    _save_figure("fig_handshake_sequence")
    plt.close()

def fig_traffic_padding_overhead():
    """
    Figure: SBP2 traffic padding overhead for representative workloads.
    Data: Artifacts/traffic_padding_<date>.csv
    """
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 2.4))

    csv_path = _artifact_csv("traffic_padding")
    rows = _read_csv_dicts(csv_path)

    # Labels to show (aligned with Supplementary Table S7)
    wanted = [
        ("HS/MessageA", "HS A"),
        ("HS/MessageB", "HS B"),
        ("HS/Finished", "HS Fin"),
        ("CP/heartbeat", "CP hb"),
        ("CP/systemCommand", "CP cmd"),
        ("CP/fileTransferRequest", "CP fileReq"),
        ("DP/32B", "DP 32B"),
        ("DP/300B", "DP 300B"),
        ("DP/900B", "DP 900B"),
        ("DP/1400B", "DP 1400B"),
        ("DP/4KiB", "DP 4KiB"),
        ("DP/16KiB", "DP 16KiB"),
        ("DP/64KiB", "DP 64KiB"),
    ]

    by_label = {r.get("label"): r for r in rows if r.get("label")}

    labels: list[str] = []
    overhead_pct: list[float] = []
    groups: list[str] = []  # HS / CP / DP
    for key, short in wanted:
        r = by_label.get(key)
        if not r:
            continue
        ratio = float(r.get("overhead_ratio", "0") or 0.0)
        pct = (ratio - 1.0) * 100.0 if ratio > 0 else 0.0
        labels.append(short)
        overhead_pct.append(pct)
        if key.startswith("HS/"):
            groups.append("HS")
        elif key.startswith("CP/"):
            groups.append("CP")
        else:
            groups.append("DP")

    y = np.arange(len(labels))
    # Grayscale-friendly styling: HS dark, CP mid, DP light + outline
    color_map = {"HS": COLORS["gray1"], "CP": COLORS["gray2"], "DP": COLORS["gray3"]}
    colors = [color_map.get(g, COLORS["gray2"]) for g in groups]

    bars = ax.barh(y, overhead_pct, color=colors, edgecolor="black", linewidth=0.5)
    ax.set_yticks(y)
    ax.set_yticklabels(labels)
    ax.set_xlabel("Overhead (%)")
    ax.set_title("SBP2 Padding Overhead (Representative Workloads)")
    ax.grid(axis="x", linestyle="--", alpha=0.5)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    # Annotate values (compact)
    for bar, pct in zip(bars, overhead_pct):
        x = bar.get_width()
        ax.annotate(f"{pct:.0f}%",
                    xy=(x, bar.get_y() + bar.get_height()/2),
                    xytext=(2, 0),
                    textcoords="offset points",
                    va="center",
                    fontsize=6)

    legend = [
        mpatches.Patch(facecolor=color_map["HS"], edgecolor="black", label="Handshake"),
        mpatches.Patch(facecolor=color_map["CP"], edgecolor="black", label="Control"),
        mpatches.Patch(facecolor=color_map["DP"], edgecolor="black", label="Data"),
    ]
    ax.legend(handles=legend, loc="upper right", framealpha=0.9)

    plt.tight_layout()
    _save_figure("fig_traffic_padding_overhead")
    plt.close()

def fig_traffic_padding_sensitivity():
    """Figure: SBP2 bucket-cap sensitivity (overhead vs cap)."""
    fig, ax = plt.subplots(figsize=(COL_WIDTH, 2.0))

    csv_path = _artifact_csv("traffic_padding_sensitivity")
    rows = _read_csv_dicts(csv_path)

    # Convert and index
    parsed = []
    for r in rows:
        try:
            parsed.append({
                "cap": int(float(r.get("cap_bytes", "0") or 0)),
                "label": r.get("label", ""),
                "overhead_ratio": float(r.get("overhead_ratio", "0") or 0.0),
                "entropy": float(r.get("entropy_bits", "0") or 0.0),
            })
        except Exception:
            continue

    caps = [65536, 131072, 262144]
    cap_labels = ["64KiB", "128KiB", "256KiB"]
    x = np.arange(len(caps))

    # Representative labels (compare large-frame distributions)
    series = [
        ("HS/MessageA", "Handshake (A)", COLORS["gray1"], "-o"),
        ("CP/heartbeat", "Control (hb)", COLORS["gray2"], "--s"),
        ("DP/rdpMix", "Remote-desktop mix", COLORS["gray3"], "-.^"),
        ("DP/fileMix", "File-chunk mix", COLORS["gray2"], ":d"),
    ]

    for key, name, color, style in series:
        ys = []
        for cap in caps:
            r = next((p for p in parsed if p["label"] == key and p["cap"] == cap), None)
            if not r or r["overhead_ratio"] <= 0:
                ys.append(np.nan)
            else:
                ys.append((r["overhead_ratio"] - 1.0) * 100.0)
        ax.plot(x, ys, style, label=name, color=color, linewidth=1.0, markersize=4)

    ax.set_xticks(x)
    ax.set_xticklabels(cap_labels)
    ax.set_ylabel("Overhead (%)")
    ax.set_xlabel("SBP2 max bucket size (cap)")
    ax.set_title("SBP2 Sensitivity: Bucket Cap vs Overhead")
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    # Slightly lower the legend to avoid covering curves near the top edge.
    ax.legend(loc="upper left", bbox_to_anchor=(0.0, 0.93), framealpha=0.9, fontsize=6)

    plt.tight_layout()
    _save_figure("fig_traffic_padding_sensitivity")
    plt.close()

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("Generating IEEE-quality PDF figures...")
    print(f"Output directory: {OUTPUT_DIR}")
    print()

    fig_handshake_latency()
    fig_policy_downgrade()
    fig_downgrade_matrix()
    fig_failure_histogram()
    fig_message_size_breakdown()
    fig_event_traces()
    fig_handshake_sequence()
    fig_traffic_padding_overhead()
    fig_traffic_padding_sensitivity()

    print()
    print("All figures generated successfully!")
    print("Update .tex file to use .pdf instead of .png")

if __name__ == '__main__':
    main()
