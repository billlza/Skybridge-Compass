#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MAIN_TEX="Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
SUPP_TEX="Docs/TDSC-2026-01-0318_supplementary.tex"
README_FILE="README.md"
SUBMISSION_TEX="Docs/tdsc_submission/paper.tex"
SUBMISSION_NAMED_TEX="Docs/tdsc_submission/TDSC-2026-01-0318_paper.tex"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "missing file: $1" >&2
    exit 1
  fi
}

require_file "$MAIN_TEX"
require_file "$SUPP_TEX"
require_file "$README_FILE"
require_file "$SUBMISSION_TEX"
require_file "$SUBMISSION_NAMED_TEX"

restore_system_impact_if_missing() {
  local artifact_date="$1"
  local target="Artifacts/system_impact_${artifact_date}.csv"
  [[ -f "$target" ]] && return 0
  local backup
  backup="$(ls -1t "${target}.bak_"* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$backup" && -f "$backup" ]]; then
    cp "$backup" "$target"
    echo "restored system impact snapshot from backup: $backup"
  fi
}

restore_realnet_summaries_if_missing() {
  local artifact_date="$1"
  for kind in stun e2e; do
    local pattern="Artifacts/realnet_${kind}_summary_${artifact_date}_*.csv.bak_*"
    while IFS= read -r backup; do
      [[ -n "$backup" ]] || continue
      local canonical="${backup%%.csv.bak_*}.csv"
      if [[ ! -f "$canonical" ]]; then
        cp "$backup" "$canonical"
        echo "restored realnet summary from backup: $backup"
      fi
    done < <(find Artifacts -maxdepth 1 -type f -name "realnet_${kind}_summary_${artifact_date}_*.csv.bak_*" -print)
  done
}

restore_realnet_microstudy_if_missing() {
  local artifact_date="$1"
  local target="Artifacts/realnet_microstudy_${artifact_date}.csv"
  [[ -f "$target" ]] && return 0
  restore_realnet_summaries_if_missing "$artifact_date"
  if [[ -x "Scripts/aggregate_realnet.py" || -f "Scripts/aggregate_realnet.py" ]]; then
    ARTIFACT_DATE="$artifact_date" python3 Scripts/aggregate_realnet.py >/dev/null 2>&1 || true
  fi
}

restore_kernel_emulation_if_missing() {
  local artifact_date="$1"
  local target="Artifacts/network_emulation_kernel_${artifact_date}.csv"
  [[ -f "$target" ]] && return 0
  if [[ -x "Scripts/run_network_emulation_kernel.sh" || -f "Scripts/run_network_emulation_kernel.sh" ]]; then
    ARTIFACT_DATE="$artifact_date" TOOL=netem START_SERVER=0 bash Scripts/run_network_emulation_kernel.sh >/dev/null 2>&1 || true
  fi
}

if ! cmp -s "$MAIN_TEX" "$SUBMISSION_TEX"; then
  echo "submission tex drift detected: $SUBMISSION_TEX differs from $MAIN_TEX" >&2
  exit 1
fi
if ! cmp -s "$MAIN_TEX" "$SUBMISSION_NAMED_TEX"; then
  echo "submission tex drift detected: $SUBMISSION_NAMED_TEX differs from $MAIN_TEX" >&2
  exit 1
fi

extract_macro() {
  local file="$1"
  local macro="$2"
  python3 - "$file" "$macro" <<'PY'
import re,sys
text=open(sys.argv[1],'r',encoding='utf-8',errors='ignore').read()
macro=sys.argv[2]
m=re.search(rf"^\\newcommand\{{\\{macro}\}}\{{(.*)\}}\s*$", text, flags=re.MULTILINE)
if not m:
    print("")
else:
    value=m.group(1).replace("\\allowbreak{}", "").replace("\\allowbreak", "").strip()
    print(value)
PY
}

main_tag="$(extract_macro "$MAIN_TEX" artifacttag)"
supp_tag="$(extract_macro "$SUPP_TEX" artifacttag)"
main_sha="$(extract_macro "$MAIN_TEX" artifactsha)"
supp_sha="$(extract_macro "$SUPP_TEX" artifactsha)"
main_zipsha="$(extract_macro "$MAIN_TEX" artifactzipsha)"
supp_zipsha="$(extract_macro "$SUPP_TEX" artifactzipsha)"
main_tarsha="$(extract_macro "$MAIN_TEX" artifacttarsha)"
supp_tarsha="$(extract_macro "$SUPP_TEX" artifacttarsha)"
main_artifact_date="$(extract_macro "$MAIN_TEX" artifactdate)"

if [[ -z "$main_tag" || -z "$main_sha" ]]; then
  echo "failed to parse artifact macros in $MAIN_TEX" >&2
  exit 1
fi
if [[ -z "$main_artifact_date" ]]; then
  echo "failed to parse artifactdate macro in $MAIN_TEX" >&2
  exit 1
fi

if [[ "$main_tag" != "$supp_tag" || "$main_sha" != "$supp_sha" || "$main_zipsha" != "$supp_zipsha" || "$main_tarsha" != "$supp_tarsha" ]]; then
  echo "artifact metadata mismatch between main and supplementary" >&2
  exit 1
fi

if ! rg -q "$main_tag" "$README_FILE"; then
  echo "README missing artifact tag: $main_tag" >&2
  exit 1
fi
if ! rg -q "$main_sha" "$README_FILE"; then
  echo "README missing artifact commit: $main_sha" >&2
  exit 1
fi
if ! rg -q "$main_zipsha" "$README_FILE"; then
  echo "README missing zip SHA256: $main_zipsha" >&2
  exit 1
fi
if ! rg -q "$main_tarsha" "$README_FILE"; then
  echo "README missing tar.gz SHA256: $main_tarsha" >&2
  exit 1
fi

restore_system_impact_if_missing "$main_artifact_date"
restore_realnet_microstudy_if_missing "$main_artifact_date"
restore_kernel_emulation_if_missing "$main_artifact_date"

for prefix in system_impact realnet_microstudy network_emulation_kernel; do
  required_csv="Artifacts/${prefix}_${main_artifact_date}.csv"
  if [[ ! -f "$required_csv" ]]; then
    echo "missing required artifact CSV: $required_csv" >&2
    exit 1
  fi
done

for legacy_pdf in \
  "TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf" \
  "Docs/tdsc_submission/TDSC-2026-01-0318_paper.pdf"; do
  if [[ -f "$legacy_pdf" ]]; then
    echo "legacy PDF should be removed to avoid submission confusion: $legacy_pdf" >&2
    exit 1
  fi
done

if rg -n "N=50([^0-9]|$)|no warmup|schema v2" "$MAIN_TEX" >/dev/null; then
  echo "found stale iOS microbench wording (N=50/no warmup/schema v2) in main paper" >&2
  rg -n "N=50([^0-9]|$)|no warmup|schema v2" "$MAIN_TEX" >&2
  exit 1
fi

if ! rg -q "warmup=10" "$MAIN_TEX"; then
  echo "main paper missing warmup=10 methodological control statement" >&2
  exit 1
fi
if ! rg -q "N=1000" "$MAIN_TEX"; then
  echo "main paper missing N=1000 methodological control statement" >&2
  exit 1
fi

if rg -n "12163|827 B|12,163" "$MAIN_TEX" "$SUPP_TEX" "$README_FILE" "Scripts/run_real_network_e2e.swift" "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/RealNetworkE2EBenchView.swift" >/dev/null; then
  echo "found stale real-network payload constants (expected 687/12002 baseline)" >&2
  rg -n "12163|827 B|12,163" "$MAIN_TEX" "$SUPP_TEX" "$README_FILE" "Scripts/run_real_network_e2e.swift" "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/RealNetworkE2EBenchView.swift" >&2
  exit 1
fi

if ! rg -q "687|\\\\claimClassicPayloadBytes" "$MAIN_TEX" || ! rg -q "12,002|\\\\claimLiboqsPayloadBytes" "$MAIN_TEX"; then
  echo "main paper missing canonical payload constants (687 / 12,002 or equivalent macros)" >&2
  exit 1
fi

echo "Consistency check passed."
echo "Artifact tag: $main_tag"
echo "Artifact commit: $main_sha"
