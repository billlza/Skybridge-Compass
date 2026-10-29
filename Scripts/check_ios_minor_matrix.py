#!/usr/bin/env python3
import argparse
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
ARTIFACTS_DIR = ROOT_DIR / "Artifacts"
EXPECTED_ARTIFACT_DATE = "2026-01-23"
ALLOWED_MODES = {"strict", "pragmatic"}


@dataclass
class DeviceRecord:
    path: Path
    label: str
    model: str
    system_name: str
    system_version: str
    major: int
    minor: int
    schema_version: int
    warmup: int
    iterations: int
    batches: int


def _resolve_artifact_date(value: str | None) -> str:
    if value:
        date = value.strip()
    else:
        date = (
            os.environ.get("ARTIFACT_DATE")
            or os.environ.get("SKYBRIDGE_ARTIFACT_DATE")
            or EXPECTED_ARTIFACT_DATE
        ).strip()
    if date != EXPECTED_ARTIFACT_DATE:
        raise SystemExit(f"ARTIFACT_DATE must be {EXPECTED_ARTIFACT_DATE}, got {date}")
    return date


def _resolve_mode(value: str | None) -> str:
    mode = (value or os.environ.get("SKYBRIDGE_IOS_MINOR_GATE_MODE") or "pragmatic").strip().lower()
    if mode not in ALLOWED_MODES:
        allowed = ", ".join(sorted(ALLOWED_MODES))
        raise SystemExit(f"invalid mode '{mode}', expected one of: {allowed}")
    return mode


def _parse_major_minor(version: str) -> tuple[int, int]:
    match = re.match(r"^(\d+)\.(\d+)(?:\.\d+)?$", version.strip())
    if not match:
        raise ValueError(f"unable to parse major/minor from systemVersion='{version}'")
    return int(match.group(1)), int(match.group(2))


def _load_device(path: Path) -> DeviceRecord:
    data = json.loads(path.read_text(encoding="utf-8"))
    schema_version = int(data.get("schemaVersion", 0))
    device = data.get("device", {}) if isinstance(data.get("device"), dict) else {}
    run_cfg = data.get("runConfig", {}) if isinstance(data.get("runConfig"), dict) else {}

    system_version = str(device.get("systemVersion", "")).strip()
    major, minor = _parse_major_minor(system_version)

    return DeviceRecord(
        path=path,
        label=str(device.get("deviceLabel", path.stem)),
        model=str(device.get("model", "unknown")),
        system_name=str(device.get("systemName", "iOS")),
        system_version=system_version,
        major=major,
        minor=minor,
        schema_version=schema_version,
        warmup=int(run_cfg.get("warmup", 0)),
        iterations=int(run_cfg.get("iterations", 0)),
        batches=int(run_cfg.get("batches", 0)),
    )


def _write_report(
    path: Path,
    artifact_date: str,
    mode: str,
    records: list[DeviceRecord],
    issues: list[str],
    warnings: list[str],
) -> None:
    lines: list[str] = []
    lines.append("# iOS Minor-Version Matrix Gate")
    lines.append("")
    lines.append(f"- Artifact date: `{artifact_date}`")
    lines.append(f"- Mode: `{mode}`")
    lines.append(f"- Device artifacts: {len(records)}")
    lines.append("")

    if records:
        lines.append("| Device | Model | OS | Version | Schema | Warmup | N | Batches | File |")
        lines.append("|---|---|---|---|---:|---:|---:|---:|---|")
        for record in records:
            lines.append(
                "| "
                + " | ".join(
                    [
                        record.label,
                        record.model,
                        record.system_name,
                        record.system_version,
                        str(record.schema_version),
                        str(record.warmup),
                        str(record.iterations),
                        str(record.batches),
                        record.path.name,
                    ]
                )
                + " |"
            )
        lines.append("")

    lines.append("## Verdict")
    lines.append("- FAIL" if issues else "- PASS")

    if records:
        major = records[0].major
        minors = sorted({record.minor for record in records})
        lines.append("")
        lines.append("## Matrix")
        lines.append(f"- major version: `{major}`")
        lines.append(f"- minor versions: `{', '.join(str(x) for x in minors)}`")

    if warnings:
        lines.append("")
        lines.append("## Warnings")
        for warning in warnings:
            lines.append(f"- {warning}")

    if issues:
        lines.append("")
        lines.append("## Issues")
        for issue in issues:
            lines.append(f"- {issue}")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate iOS minor-version compatibility matrix")
    parser.add_argument("--artifact-date", default=None, help="artifact date (must be 2026-01-23)")
    parser.add_argument("--glob", default=None, help="override glob pattern")
    parser.add_argument("--mode", default=None, choices=sorted(ALLOWED_MODES), help="gate mode")
    parser.add_argument("--output", default=None, help="report output path")
    args = parser.parse_args()

    artifact_date = _resolve_artifact_date(args.artifact_date)
    mode = _resolve_mode(args.mode)
    pattern = args.glob or f"ios_microbench_{artifact_date}_*.json"
    files = sorted(ARTIFACTS_DIR.glob(pattern))

    records: list[DeviceRecord] = []
    issues: list[str] = []
    warnings: list[str] = []

    for path in files:
        try:
            record = _load_device(path)
        except Exception as exc:
            issues.append(f"{path.name}: {exc}")
            continue
        records.append(record)

    min_devices_required = 2 if mode == "strict" else 1
    if len(records) < min_devices_required:
        issues.append(
            f"need at least {min_devices_required} device artifact(s) for date {artifact_date}; found {len(records)}"
        )

    if records:
        majors = {record.major for record in records}
        if len(majors) != 1:
            issues.append(f"devices must share same major iOS version; got {sorted(majors)}")

        minors = {record.minor for record in records}
        if len(minors) < 2:
            text = "devices currently cover only one minor version; add one 26.x device sample on another minor to strengthen compatibility evidence"
            if mode == "strict":
                issues.append(text)
            else:
                warnings.append(text)

        if mode == "pragmatic" and len(records) < 2:
            warnings.append("only one device artifact found; this is accepted in pragmatic mode but weakens generalization")

        for record in records:
            if record.schema_version != 3:
                issues.append(f"{record.path.name}: schemaVersion must be 3 (got {record.schema_version})")
            if record.warmup != 10:
                issues.append(f"{record.path.name}: warmup must be 10 (got {record.warmup})")
            if record.iterations != 1000:
                issues.append(f"{record.path.name}: iterations must be 1000 (got {record.iterations})")
            if record.batches < 3:
                issues.append(f"{record.path.name}: batches must be >=3 (got {record.batches})")

    output = Path(args.output) if args.output else ARTIFACTS_DIR / f"ios_minor_matrix_{artifact_date}.md"
    _write_report(output, artifact_date, mode, records, issues, warnings)
    print(f"ios_minor_matrix_report={output}")

    for warning in warnings:
        print(f"WARN: {warning}")

    if issues:
        for issue in issues:
            print(f"FAIL: {issue}")
        raise SystemExit(1)

    print(f"iOS minor-version matrix gate passed (mode={mode}).")


if __name__ == "__main__":
    main()
