#!/usr/bin/env python3
"""
Aggregate iOS on-device microbench JSON artifacts (schema v3).

Inputs:
  Artifacts/ios_microbench_<ARTIFACT_DATE>_<device_label>.json

Outputs:
  Artifacts/ios_microbench_<ARTIFACT_DATE>.csv
  Docs/tables/ios_microbench.tex
  Docs/supp_tables/s11_ios_microbench_devices.tex
"""

from __future__ import annotations

import csv
import json
import os
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "Artifacts"
TABLES = ROOT / "Docs" / "tables"
SUPP = ROOT / "Docs" / "supp_tables"

ORDERED_SUITES = [
    "classic_x25519_ed25519",
    "cryptokit_mlkem768_mldsa65",
    "cryptokit_xwing_mldsa65",
]
SUITE_LABELS = {
    "classic_x25519_ed25519": "Classic (X25519 + Ed25519)",
    "cryptokit_mlkem768_mldsa65": "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
    "cryptokit_xwing_mldsa65": "CryptoKit Hybrid (X-Wing + ML-DSA-65)",
}
ORDERED_OPS = [
    "kem_encapsulate",
    "sign",
    "verify",
    "kem_dem_seal_open",
]
OP_LABELS = {
    "kem_encapsulate": "KEM encap",
    "sign": "Sign",
    "verify": "Verify",
    "kem_dem_seal_open": "KEM-DEM seal+open",
}


@dataclass
class Metric:
    mean_ms: float | None
    p99_ms: float | None


@dataclass
class DeviceArtifact:
    path: Path
    artifact_date: str
    device_label: str
    model: str
    system_version: str
    os_build: str
    chip: str
    thermal_state: str
    warmup: int
    iterations: int
    batches: int
    metrics: dict[str, dict[str, Metric]]
    suite_status: dict[str, str]


def _escape_tex(value: str) -> str:
    return (
        value.replace("\\", r"\textbackslash{}")
        .replace("_", r"\_")
        .replace("%", r"\%")
        .replace("&", r"\&")
        .replace("#", r"\#")
        .replace("{", r"\{")
        .replace("}", r"\}")
    )


def _artifact_date_from_env() -> str | None:
    value = os.environ.get("ARTIFACT_DATE") or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
    if value and value.strip():
        return value.strip()
    return None


def _discover_files(date_hint: str | None) -> tuple[str | None, list[Path]]:
    if date_hint:
        files = sorted(ARTIFACTS.glob(f"ios_microbench_{date_hint}_*.json"))
        return (date_hint, files)

    files = sorted(ARTIFACTS.glob("ios_microbench_*.json"))
    if not files:
        return (None, [])

    by_date: dict[str, list[Path]] = {}
    for path in files:
        stem = path.stem
        parts = stem.split("_")
        if len(parts) < 4:
            continue
        date = parts[2]
        by_date.setdefault(date, []).append(path)
    if not by_date:
        return (None, [])
    selected_date = sorted(by_date.keys())[-1]
    return (selected_date, sorted(by_date[selected_date]))


def _load_device(path: Path) -> DeviceArtifact:
    data = json.loads(path.read_text(encoding="utf-8"))
    if int(data.get("schemaVersion", 0)) != 3:
        raise ValueError(f"{path.name}: expected schemaVersion=3")

    device = data.get("device", {})
    run_cfg = data.get("runConfig", {})
    suites = data.get("suites", [])

    metrics: dict[str, dict[str, Metric]] = {}
    suite_status: dict[str, str] = {}

    for suite in suites:
        suite_id = str(suite.get("suiteId", ""))
        if not suite_id:
            continue
        status = str(suite.get("status", "unknown"))
        suite_status[suite_id] = status
        metrics[suite_id] = {}
        for op in suite.get("operations", []):
            op_name = str(op.get("operation", ""))
            summary = op.get("summary", {})
            mean = summary.get("meanMs")
            p99 = summary.get("p99Ms")
            metrics[suite_id][op_name] = Metric(
                mean_ms=float(mean) if mean is not None else None,
                p99_ms=float(p99) if p99 is not None else None,
            )

    return DeviceArtifact(
        path=path,
        artifact_date=str(data.get("artifactDate", "")),
        device_label=str(device.get("deviceLabel", "unknown")),
        model=str(device.get("model", "unknown")),
        system_version=str(device.get("systemVersion", "unknown")),
        os_build=str(device.get("osBuild", "unknown")),
        chip=str(device.get("chip", "unknown")),
        thermal_state=str(device.get("thermalState", "unknown")),
        warmup=int(run_cfg.get("warmup", 0)),
        iterations=int(run_cfg.get("iterations", 0)),
        batches=int(run_cfg.get("batches", 0)),
        metrics=metrics,
        suite_status=suite_status,
    )


def _format_metric(metric: Metric | None) -> str:
    if metric is None or metric.mean_ms is None or metric.p99_ms is None:
        return "-"
    return f"{metric.mean_ms:.3f} / {metric.p99_ms:.3f}"


def _write_csv(rows: list[dict[str, str]], artifact_date: str) -> Path:
    out = ARTIFACTS / f"ios_microbench_{artifact_date}.csv"
    with out.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "artifact_date",
                "device_label",
                "model",
                "system_version",
                "os_build",
                "chip",
                "thermal_state",
                "suite_id",
                "suite_label",
                "suite_status",
                "operation",
                "mean_ms",
                "p99_ms",
                "warmup",
                "iterations",
                "batches",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)
    return out


def _write_main_table(devices: list[DeviceArtifact], artifact_date: str) -> Path:
    TABLES.mkdir(parents=True, exist_ok=True)
    out = TABLES / "ios_microbench.tex"

    d1 = devices[0] if len(devices) > 0 else None
    d2 = devices[1] if len(devices) > 1 else None

    warmup = d1.warmup if d1 else 10
    iterations = d1.iterations if d1 else 1000
    batches = d1.batches if d1 else 3

    d1_label = _escape_tex(d1.device_label) if d1 else "device-a"
    d2_label = _escape_tex(d2.device_label) if d2 else "device-b"

    lines: list[str] = []
    lines.append(r"\begin{table*}[!t]")
    lines.append(r"\centering")
    lines.append(
        rf"\caption{{On-device micro-benchmark on iOS 26+ (two devices, schema v3 artifacts). Each device runs warmup={warmup}, N={iterations}, batches={batches}. Cells report mean/p99 in ms from pooled measured iterations. Data from \texttt{{Artifacts/ios\_microbench\_{artifact_date}.csv}} (generated via \texttt{{Scripts/aggregate\_ios\_microbench.py}}).}}"
    )
    lines.append(r"\label{tab:ios-microbench}")
    lines.append(r"{\setlength{\tabcolsep}{3pt}\scriptsize")
    lines.append(r"\begin{tabular}{@{}lcccccccc@{}}")
    lines.append(r"\toprule")
    lines.append(
        rf"Configuration & \multicolumn{{4}}{{c}}{{\texttt{{{d1_label}}}}} & \multicolumn{{4}}{{c}}{{\texttt{{{d2_label}}}}} \\"
    )
    lines.append(r"\cmidrule(lr){2-5}\cmidrule(lr){6-9}")
    lines.append(r"& KEM encap & Sign & Verify & KEM-DEM & KEM encap & Sign & Verify & KEM-DEM \\")
    lines.append(r"\midrule")

    for suite_id in ORDERED_SUITES:
        suite_label = _escape_tex(SUITE_LABELS.get(suite_id, suite_id))
        row = [suite_label]
        for device in [d1, d2]:
            for op in ORDERED_OPS:
                metric = None
                if device:
                    status = device.suite_status.get(suite_id, "")
                    if status == "ok":
                        metric = device.metrics.get(suite_id, {}).get(op)
                    elif status == "unavailable":
                        row.append(r"\textit{n/a}")
                        continue
                row.append(_format_metric(metric))
        lines.append(" & ".join(row) + r" \\")

    lines.append(r"\bottomrule")
    lines.append(r"\end{tabular}")
    lines.append(r"}")
    lines.append(r"\end{table*}")

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out


def _write_device_metadata_table(devices: list[DeviceArtifact], artifact_date: str) -> Path:
    SUPP.mkdir(parents=True, exist_ok=True)
    out = SUPP / "s11_ios_microbench_devices.tex"

    lines: list[str] = []
    lines.append(r"\begin{table*}[!tp]")
    lines.append(r"\centering")
    lines.append(
        rf"\caption{{Supplementary Table \thetable: iOS micro-benchmark device metadata (\texttt{{Artifacts/ios\_microbench\_{artifact_date}.csv}}).}}"
    )
    lines.append(r"\label{tab:supp-ios-microbench-devices}")
    lines.append(r"\begin{tabular}{@{}lllllll@{}}")
    lines.append(r"\toprule")
    lines.append(r"Device label & Model & System & Build & Chip/machine & Thermal & Config \\")
    lines.append(r"\midrule")
    for device in devices:
        config = f"warmup={device.warmup}, N={device.iterations}, B={device.batches}"
        lines.append(
            " & ".join(
                [
                    _escape_tex(device.device_label),
                    _escape_tex(device.model),
                    _escape_tex(device.system_version),
                    _escape_tex(device.os_build),
                    _escape_tex(device.chip),
                    _escape_tex(device.thermal_state),
                    _escape_tex(config),
                ]
            )
            + r" \\"
        )
    lines.append(r"\bottomrule")
    lines.append(r"\end{tabular}")
    lines.append(r"\end{table*}")

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out


def _write_placeholder_tables() -> tuple[Path, Path]:
    TABLES.mkdir(parents=True, exist_ok=True)
    SUPP.mkdir(parents=True, exist_ok=True)
    main_out = TABLES / "ios_microbench.tex"
    supp_out = SUPP / "s11_ios_microbench_devices.tex"

    main_out.write_text(
        "\n".join(
            [
                r"\begin{table*}[!t]",
                r"\centering",
                r"\caption{On-device micro-benchmark on iOS 26+ (artifact pending). Export \texttt{ios\_microbench\_<date>\_<device>.json} and run \texttt{python3 Scripts/aggregate\_ios\_microbench.py}.}",
                r"\label{tab:ios-microbench}",
                r"{\setlength{\tabcolsep}{3pt}\scriptsize",
                r"\begin{tabular}{@{}lcccccccc@{}}",
                r"\toprule",
                r"Configuration & \multicolumn{4}{c}{device-a} & \multicolumn{4}{c}{device-b} \\",
                r"\cmidrule(lr){2-5}\cmidrule(lr){6-9}",
                r"& KEM encap & Sign & Verify & KEM-DEM & KEM encap & Sign & Verify & KEM-DEM \\",
                r"\midrule",
                r"Classic (X25519 + Ed25519) & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} \\",
                r"CryptoKit PQC (ML-KEM-768 + ML-DSA-65) & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} \\",
                r"CryptoKit Hybrid (X-Wing + ML-DSA-65) & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} & \textit{n/a} \\",
                r"\bottomrule",
                r"\end{tabular}",
                r"}",
                r"\end{table*}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    supp_out.write_text(
        "\n".join(
            [
                r"\begin{table*}[!tp]",
                r"\centering",
                r"\caption{Supplementary Table \thetable: iOS micro-benchmark device metadata (artifact pending).}",
                r"\label{tab:supp-ios-microbench-devices}",
                r"\begin{tabular}{@{}l@{}}",
                r"\toprule",
                r"Artifact data not found. \\",
                r"\bottomrule",
                r"\end{tabular}",
                r"\end{table*}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    return (main_out, supp_out)


def main() -> None:
    date_hint = _artifact_date_from_env()
    artifact_date, files = _discover_files(date_hint)
    if not files or not artifact_date:
        main_out, supp_out = _write_placeholder_tables()
        print("No iOS microbench JSON files found.")
        print(f"Wrote placeholder: {main_out}")
        print(f"Wrote placeholder: {supp_out}")
        return

    devices = sorted((_load_device(path) for path in files), key=lambda d: d.device_label)
    selected_devices = devices[:2]

    csv_rows: list[dict[str, str]] = []
    for device in devices:
        for suite_id in ORDERED_SUITES:
            suite_label = SUITE_LABELS.get(suite_id, suite_id)
            suite_status = device.suite_status.get(suite_id, "missing")
            for op in ORDERED_OPS:
                metric = device.metrics.get(suite_id, {}).get(op)
                csv_rows.append(
                    {
                        "artifact_date": device.artifact_date,
                        "device_label": device.device_label,
                        "model": device.model,
                        "system_version": device.system_version,
                        "os_build": device.os_build,
                        "chip": device.chip,
                        "thermal_state": device.thermal_state,
                        "suite_id": suite_id,
                        "suite_label": suite_label,
                        "suite_status": suite_status,
                        "operation": op,
                        "mean_ms": "" if metric is None or metric.mean_ms is None else f"{metric.mean_ms:.6f}",
                        "p99_ms": "" if metric is None or metric.p99_ms is None else f"{metric.p99_ms:.6f}",
                        "warmup": str(device.warmup),
                        "iterations": str(device.iterations),
                        "batches": str(device.batches),
                    }
                )

    csv_out = _write_csv(csv_rows, artifact_date)
    table_out = _write_main_table(selected_devices, artifact_date)
    supp_out = _write_device_metadata_table(devices, artifact_date)
    print(f"Wrote: {csv_out}")
    print(f"Wrote: {table_out}")
    print(f"Wrote: {supp_out}")


if __name__ == "__main__":
    main()
