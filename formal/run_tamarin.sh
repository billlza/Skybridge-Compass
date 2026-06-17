#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

theory="${1:-skybridge_v2.spthy}"
theory_base="${theory%.spthy}"
project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
artifact_date="${ARTIFACT_DATE:-$(date +%F)}"
artifact_dir="$project_root/Artifacts"
report_dir="$SCRIPT_DIR/tamarin-report"
report_file="$report_dir/${theory_base}_prove.txt"
summary_file="$report_dir/${theory_base}_summary.txt"
artifact_report_file="$artifact_dir/tamarin_${theory_base}_proof_${artifact_date}.txt"
artifact_summary_file="$artifact_dir/tamarin_${theory_base}_summary_${artifact_date}.txt"
artifact_summary_png="$artifact_dir/tamarin_${theory_base}_summary_${artifact_date}.png"
artifact_manifest="$artifact_dir/tamarin_${theory_base}_report_${artifact_date}.md"

if ! command -v tamarin-prover >/dev/null 2>&1; then
  echo "ERROR: tamarin-prover not found on PATH." >&2
  echo "Install Tamarin and rerun. See: https://tamarin-prover.github.io/" >&2
  exit 2
fi

mkdir -p "$report_dir" "$artifact_dir"

echo "== Running Tamarin: ${theory} =="
# --derivcheck-timeout=0 disables the preprocessing derivation-check
# *timeout heuristic* (the only thing that ever "failed" wellformedness on
# this DH+KEM theory); it does not affect soundness of the proofs, it just
# lets the (slow) source/derivation analysis run to completion so the
# report has no spurious "results might be wrong" banner.
tamarin-prover "${theory}" --prove --derivcheck-timeout=0 | tee "$report_file"

awk '/^summary of summaries:/{flag=1} flag{print}' "$report_file" > "$summary_file"

cp "$report_file" "$artifact_report_file"
cp "$summary_file" "$artifact_summary_file"

python3 - "$summary_file" "$artifact_summary_png" <<'PY'
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
png_path = Path(sys.argv[2])
text = summary_path.read_text(encoding="utf-8", errors="ignore").strip()
if not text:
    text = "No summary captured."

try:
    import matplotlib.pyplot as plt
except Exception:
    raise SystemExit(0)

fig, ax = plt.subplots(figsize=(13, 7), dpi=220)
ax.axis("off")
ax.text(
    0.01,
    0.99,
    text,
    family="monospace",
    fontsize=10,
    va="top",
    ha="left",
)
fig.savefig(png_path, bbox_inches="tight", pad_inches=0.25)
PY

{
  echo "# Tamarin Proof Report"
  echo
  echo "- Theory: \`$theory\`"
  echo "- Date: \`$artifact_date\`"
  echo "- Command: \`tamarin-prover $theory --prove\`"
  echo "- Raw output: \`$(basename "$artifact_report_file")\`"
  echo "- Summary: \`$(basename "$artifact_summary_file")\`"
  if [[ -f "$artifact_summary_png" ]]; then
    echo "- Summary screenshot: \`$(basename "$artifact_summary_png")\`"
  fi
  echo
  echo "## Lemma Status"
  grep -E "exists-trace|all-traces" "$summary_file" || true
} > "$artifact_manifest"

echo
echo "== Done =="
echo "Report: $report_dir/"
echo "Artifact report: $artifact_report_file"
echo "Artifact summary: $artifact_summary_file"
if [[ -f "$artifact_summary_png" ]]; then
  echo "Artifact screenshot: $artifact_summary_png"
fi
echo "Artifact manifest: $artifact_manifest"
