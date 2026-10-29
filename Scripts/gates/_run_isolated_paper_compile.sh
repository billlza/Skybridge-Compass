#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

DOCS_SRC="${ROOT_DIR}/Docs"
DOCS_TMP="${TMP_DIR}/Docs"

MAIN_TEX="TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
MAIN_PDF="TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf"
SUPP_TEX="TDSC-2026-01-0318_supplementary.tex"
SUPP_PDF="TDSC-2026-01-0318_supplementary.pdf"

rsync -a --delete --exclude='*.pdf' "${DOCS_SRC}/" "${DOCS_TMP}/"
mkdir -p "${TMP_DIR}/figures"
ln -s "${ROOT_DIR}/figures" "${TMP_DIR}/figures/src"
rm -f "${DOCS_TMP}/figures"
ln -s ../figures/src "${DOCS_TMP}/figures"

check_latex_log() {
  local log_file="$1"
  if [[ ! -f "${log_file}" ]]; then
    echo "missing log file: ${log_file}" >&2
    exit 1
  fi
  if command -v rg >/dev/null 2>&1; then
    if rg -n "(LaTeX Error|LaTeX Warning|Overfull \\\\hbox)" "${log_file}" >/dev/null; then
      rg -n "(LaTeX Error|LaTeX Warning|Overfull \\\\hbox)" "${log_file}" >&2 || true
      exit 1
    fi
  else
    if grep -nE "(LaTeX Error|LaTeX Warning|Overfull \\\\hbox)" "${log_file}" >/dev/null; then
      grep -nE "(LaTeX Error|LaTeX Warning|Overfull \\\\hbox)" "${log_file}" >&2 || true
      exit 1
    fi
  fi
}

check_pdf_quality() {
  local pdf_file="$1"
  [[ -f "${pdf_file}" ]] || { echo "missing pdf: ${pdf_file}" >&2; exit 1; }
  pdffonts "${pdf_file}" | grep -q "Type 3" && {
    echo "Type 3 font detected in ${pdf_file}" >&2
    exit 1
  }
  local text_file
  text_file="$(mktemp)"
  pdftotext "${pdf_file}" "${text_file}"
  python3 - "${text_file}" <<'PY'
import sys
text = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
bad = [ch for ch in text if ord(ch) in (0xFFFD, 0xFFFE, 0xFFFF)]
if bad:
    raise SystemExit(1)
PY
  rm -f "${text_file}"

  python3 - "${pdf_file}" <<'PY'
import subprocess
import sys

pdf = sys.argv[1]
raw = subprocess.check_output(["pdfinfo", pdf], text=True, errors="ignore")
pages = 0
encrypted = ""
for line in raw.splitlines():
    if line.startswith("Pages:"):
        pages = int(line.split(":", 1)[1].strip() or "0")
    if line.startswith("Encrypted:"):
        encrypted = line.split(":", 1)[1].strip()
if pages <= 0:
    raise SystemExit(1)
if encrypted.lower().startswith("yes"):
    raise SystemExit(1)
PY
}

(
  cd "${DOCS_TMP}"

  pdflatex -interaction=nonstopmode "${MAIN_TEX}" >/dev/null
  if [[ -f "${SUPP_TEX}" ]]; then
    pdflatex -interaction=nonstopmode "${SUPP_TEX}" >/dev/null
    pdflatex -interaction=nonstopmode "${SUPP_TEX}" >/dev/null
  fi
  pdflatex -interaction=nonstopmode "${MAIN_TEX}" >/dev/null
  pdflatex -interaction=nonstopmode "${MAIN_TEX}" >/dev/null
  if [[ -f "${SUPP_TEX}" ]]; then
    pdflatex -interaction=nonstopmode "${SUPP_TEX}" >/dev/null
    pdflatex -interaction=nonstopmode "${SUPP_TEX}" >/dev/null
  fi

  check_latex_log "${DOCS_TMP}/${MAIN_TEX%.tex}.log"
  check_pdf_quality "${DOCS_TMP}/${MAIN_PDF}"
  if [[ -f "${DOCS_TMP}/${SUPP_TEX}" ]]; then
    check_latex_log "${DOCS_TMP}/${SUPP_TEX%.tex}.log"
    check_pdf_quality "${DOCS_TMP}/${SUPP_PDF}"
  fi
)

echo "isolated_paper_compile_ok tmp=${DOCS_TMP}"
