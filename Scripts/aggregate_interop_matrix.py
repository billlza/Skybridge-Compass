#!/usr/bin/env python3
"""Build cross-platform interop matrix artifacts for the TDSC supplementary."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Dict, List, Optional


def read_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def fmt_float(value: Optional[float], digits: int = 3) -> str:
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def suite_mode_from_payload(payload_bytes: int) -> str:
    if payload_bytes == 687:
        return "classic"
    if payload_bytes == 12002:
        return "pqc-v1"
    return f"payload-{payload_bytes}B"


def load_measured_rows(path: Path) -> List[Dict[str, str]]:
    rows = read_csv(path)
    if not rows:
        return []

    classic_by_label: Dict[str, float] = {}
    for row in rows:
        try:
            payload = int(row.get("payload_bytes", "0"))
            label = row.get("label", "")
            p50 = float(row.get("total_p50_ms", "nan"))
        except Exception:
            continue
        if payload == 687:
            classic_by_label[label] = p50

    out: List[Dict[str, str]] = []
    for row in rows:
        try:
            payload = int(row.get("payload_bytes", "0"))
            n = int(row.get("samples", "0"))
            ok_rate = float(row.get("ok_rate", "0"))
            p50 = float(row.get("total_p50_ms", "nan"))
            p95 = float(row.get("total_p95_ms", "nan"))
        except Exception:
            continue

        label = row.get("label", "")
        classic_p50 = classic_by_label.get(label)
        delta = p50 - classic_p50 if classic_p50 is not None else None

        out.append(
            {
                "initiator_platform": "iOS/macOS client",
                "responder_platform": "Ubuntu EC2",
                "policy_mode": "default",
                "suite_mode": suite_mode_from_payload(payload),
                "path_label": label,
                "n": str(n),
                "success_rate": f"{ok_rate:.4f}",
                "p50_ms": f"{p50:.3f}",
                "p95_ms": f"{p95:.3f}",
                "delta_vs_classic_ms": "" if delta is None else f"{delta:.3f}",
                "evidence_class": "measured",
                "source": path.name,
            }
        )
    return out


def load_static_rows(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        raise FileNotFoundError(
            f"Missing interop consistency artifact: {path}. "
            "Run Scripts/check_cross_platform_interop.py first."
        )
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("status", "").lower() != "pass":
        raise ValueError(
            "Interop consistency artifact is not PASS; refusing to build a mixed evidence table. "
            f"Blockers: {payload.get('blockers', [])}"
        )
    is_pass = payload.get("status", "").lower() == "pass"
    success = "1.0000" if is_pass else "0.0000"
    source = path.name
    pair_rows = [
        ("iOS/macOS", "Android"),
        ("iOS/macOS", "Ubuntu"),
        ("Android", "Ubuntu"),
    ]
    out: List[Dict[str, str]] = []
    for initiator, responder in pair_rows:
        out.append(
            {
                "initiator_platform": initiator,
                "responder_platform": responder,
                "policy_mode": "runtime_matrix",
                "suite_mode": "catalog+policy-contract",
                "path_label": "static_contract_consistency",
                "n": "1",
                "success_rate": success,
                "p50_ms": "",
                "p95_ms": "",
                "delta_vs_classic_ms": "",
                "evidence_class": "static_contract",
                "source": source,
            }
        )
    return out


def write_csv(path: Path, rows: List[Dict[str, str]]) -> None:
    fieldnames = [
        "initiator_platform",
        "responder_platform",
        "policy_mode",
        "suite_mode",
        "path_label",
        "n",
        "success_rate",
        "p50_ms",
        "p95_ms",
        "delta_vs_classic_ms",
        "evidence_class",
        "source",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def tex_escape(text: str) -> str:
    out = text.replace("\\", "\\textbackslash{}")
    out = out.replace("&", "\\&")
    out = out.replace("%", "\\%")
    out = out.replace("_", "\\_")
    out = out.replace("#", "\\#")
    return out


def path_label_for_tex(label: str) -> str:
    aliases = {
        "ec2_v2_contract_54_direct": "direct-ec2-54",
        "ec2_v2_contract_tunnel": "ssh-tunnel",
        "home_wifi": "home-wifi",
        "phone_hotspot_5ga_r18": "hotspot-5ga",
        "static_contract_consistency": "static-contract",
    }
    return aliases.get(label, label)


def write_tex(path: Path, rows: List[Dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: List[str] = []
    lines.append(r"\begin{table*}[!tp]")
    lines.append(r"\centering")
    lines.append(r"\scriptsize")
    lines.append(r"\setlength{\tabcolsep}{2pt}")
    lines.append(
        r"\caption{Cross-platform interop matrix (measured external Linux paths + static contract-consistency pairs).}"
    )
    lines.append(r"\label{tab:supp-interop-matrix}")
    lines.append(
        r"\begin{tabular}{@{}>{\raggedright\arraybackslash}p{0.14\linewidth}>{\raggedright\arraybackslash}p{0.14\linewidth}>{\raggedright\arraybackslash}p{0.09\linewidth}>{\raggedright\arraybackslash}p{0.12\linewidth}>{\raggedright\arraybackslash}p{0.13\linewidth}>{\centering\arraybackslash}p{0.05\linewidth}>{\centering\arraybackslash}p{0.06\linewidth}>{\centering\arraybackslash}p{0.05\linewidth}>{\centering\arraybackslash}p{0.05\linewidth}@{}}"
    )
    lines.append(r"\toprule")
    lines.append(
        r"Initiator & Responder & Evidence & Suite mode & Path label & $n$ & Success & p50 (ms) & p95 (ms) \\"
    )
    lines.append(r"\midrule")
    for row in rows:
        lines.append(
            " & ".join(
                [
                    tex_escape(row["initiator_platform"]),
                    tex_escape(row["responder_platform"]),
                    tex_escape(row["evidence_class"]),
                    tex_escape(row["suite_mode"]),
                    r"\texttt{" + tex_escape(path_label_for_tex(row["path_label"])) + "}",
                    tex_escape(row["n"]),
                    tex_escape(row["success_rate"]),
                    tex_escape(row["p50_ms"] or "-"),
                    tex_escape(row["p95_ms"] or "-"),
                ]
            )
            + r" \\"
        )
    lines.append(r"\bottomrule")
    lines.append(r"\end{tabular}")
    lines.append(
        r"\vspace{2pt}\par\raggedright\footnotesize\textit{Notes:} Measured rows use \texttt{Artifacts/realnet\_e2e\_summary\_2026-01-23\_*.csv}; static-contract rows derive from \texttt{Scripts/check\_cross\_platform\_interop.py} output."
    )
    lines.append(r"\end{table*}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-date", default="2026-01-23")
    parser.add_argument("--interop-json")
    parser.add_argument("--direct-summary")
    parser.add_argument("--tunnel-summary")
    parser.add_argument("--out-csv")
    parser.add_argument("--out-tex")
    args = parser.parse_args()

    artifact_date = args.artifact_date
    interop_json = Path(args.interop_json or f"Artifacts/interop_consistency_{artifact_date}.json")
    out_csv = Path(args.out_csv or f"Artifacts/interop_cross_platform_{artifact_date}.csv")
    out_tex = Path(args.out_tex or "Docs/supp_tables/s13_interop_matrix.tex")

    summary_inputs: List[Path] = []
    if args.direct_summary:
        summary_inputs.append(Path(args.direct_summary))
    if args.tunnel_summary:
        summary_inputs.append(Path(args.tunnel_summary))
    if not summary_inputs:
        summary_inputs = sorted(Path("Artifacts").glob(f"realnet_e2e_summary_{artifact_date}_*.csv"))

    measured_rows: List[Dict[str, str]] = []
    for summary_path in summary_inputs:
        measured_rows.extend(load_measured_rows(summary_path))

    try:
        static_rows = load_static_rows(interop_json)
    except (FileNotFoundError, ValueError) as exc:
        print(f"[interop-matrix] FAIL: {exc}")
        return 1

    all_rows = measured_rows + static_rows

    write_csv(out_csv, all_rows)
    write_tex(out_tex, all_rows)

    print(f"[interop-matrix] rows={len(all_rows)}")
    print(f"[interop-matrix] wrote {out_csv}")
    print(f"[interop-matrix] wrote {out_tex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
