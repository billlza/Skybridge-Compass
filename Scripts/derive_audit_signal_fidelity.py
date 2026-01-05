#!/usr/bin/env python3
import csv
from pathlib import Path

ARTIFACTS = Path("Artifacts")
OUT_DIR = ARTIFACTS

FAULT_CLASSES = {
    "drop_timeout": {"drop", "delay_exceed_timeout", "concurrent_timeout"},
    "corrupt_wrong_sig": {"corrupt_header", "corrupt_payload", "wrong_signature"},
    "benign_ordering": {"out_of_order", "duplicate", "delay_within_timeout"},
}


def latest_csv(prefix: str) -> Path:
    files = sorted(ARTIFACTS.glob(f"{prefix}_*.csv"))
    if not files:
        raise SystemExit(f"No {prefix}_*.csv found in Artifacts/")
    return files[-1]


def load_fault_rows(path: Path):
    rows = {}
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            policy = row.get("policy", "default")
            scenario = row["scenario"]
            rows[(policy, scenario)] = {
                "n_runs": int(row["n_runs"]),
                "E_handshakeFailed": int(row.get("E_handshakeFailed", 0)),
                "E_cryptoDowngrade": int(row.get("E_cryptoDowngrade", 0)),
            }
    return rows


def load_policy_rows(path: Path):
    rows = {}
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            policy = row["policy"]
            rows[policy] = {
                "iterations": int(row["iterations"]),
                "fallback_events": int(row.get("fallback_events", 0)),
            }
    return rows


def summarize_class(rows, policies, scenarios, expect_failed, expect_fallback):
    total_runs = 0
    tp_runs = 0
    fp_runs = 0
    for policy in policies:
        for name in scenarios:
            key = (policy, name)
            if key not in rows:
                continue
            r = rows[key]
            total_runs += r["n_runs"]
            failed_ok = (r["E_handshakeFailed"] == r["n_runs"]) if expect_failed else (r["E_handshakeFailed"] == 0)
            fallback_ok = (r["E_cryptoDowngrade"] == 0) if expect_fallback == 0 else (r["E_cryptoDowngrade"] > 0)
            if failed_ok and fallback_ok:
                tp_runs += r["n_runs"]
            else:
                fp_runs += r["n_runs"]
    tp_rate = (tp_runs / total_runs) if total_runs else 0.0
    fp_rate = (fp_runs / total_runs) if total_runs else 0.0
    return total_runs, tp_rate, fp_rate


def main():
    fault_path = latest_csv("fault_injection")
    policy_path = latest_csv("policy_downgrade")
    fault_rows = load_fault_rows(fault_path)
    policy_rows = load_policy_rows(policy_path)

    date_suffix = fault_path.stem.split("_")[-1]
    out_path = OUT_DIR / f"audit_signal_fidelity_{date_suffix}.csv"

    results = []

    policies = sorted({policy for (policy, _) in fault_rows.keys()})
    for policy in policies:
        total, tp, fp = summarize_class(
            fault_rows,
            [policy],
            FAULT_CLASSES["drop_timeout"],
            expect_failed=True,
            expect_fallback=0
        )
        results.append({
            "scenario_class": f"drop_timeout_{policy}",
            "expected_signal": "handshakeFailed=1, handshakeFallback=0",
            "total_runs": total,
            "tp_rate": f"{tp:.2f}",
            "fp_rate": f"{fp:.2f}",
        })

        total, tp, fp = summarize_class(
            fault_rows,
            [policy],
            FAULT_CLASSES["corrupt_wrong_sig"],
            expect_failed=True,
            expect_fallback=0
        )
        results.append({
            "scenario_class": f"corrupt_wrong_sig_{policy}",
            "expected_signal": "handshakeFailed=1, handshakeFallback=0",
            "total_runs": total,
            "tp_rate": f"{tp:.2f}",
            "fp_rate": f"{fp:.2f}",
        })

        total, tp, fp = summarize_class(
            fault_rows,
            [policy],
            FAULT_CLASSES["benign_ordering"],
            expect_failed=False,
            expect_fallback=0
        )
        results.append({
            "scenario_class": f"benign_ordering_{policy}",
            "expected_signal": "handshakeFailed=0, handshakeFallback=0",
            "total_runs": total,
            "tp_rate": f"{tp:.2f}",
            "fp_rate": f"{fp:.2f}",
        })

    for policy in ("default", "strictPQC"):
        row = policy_rows.get(policy)
        if not row:
            continue
        expect_fallback = 1 if policy == "default" else 0
        tp_rate = 1.0 if ((row["fallback_events"] > 0) == (expect_fallback == 1)) else 0.0
        results.append({
            "scenario_class": f"pqc_unavailable_{policy}",
            "expected_signal": "handshakeFallback=1" if expect_fallback == 1 else "handshakeFallback=0",
            "total_runs": row["iterations"],
            "tp_rate": f"{tp_rate:.2f}",
            "fp_rate": f"{0.0:.2f}",
        })

    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["scenario_class", "expected_signal", "total_runs", "tp_rate", "fp_rate"])
        writer.writeheader()
        writer.writerows(results)

    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
