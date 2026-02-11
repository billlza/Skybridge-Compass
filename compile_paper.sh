#!/bin/bash
# SkyBridge Paper 编译脚本 - 带自动时间戳归档
# 用法: ./compile_paper.sh [--skip-figures] [--skip-checks]

set -euo pipefail

PROJECT_DIR="/Users/bill/Desktop/SkyBridge Compass Pro release"
DOCS_DIR="$PROJECT_DIR/Docs"
OUT_DIR="$PROJECT_DIR/out"
TEX_FILE="TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
PDF_FILE="TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf"
SUPP_TEX_FILE="TDSC-2026-01-0318_supplementary.tex"
SUPP_PDF_FILE="TDSC-2026-01-0318_supplementary.pdf"

SKIP_FIGURES=0
SKIP_CHECKS=0
PYTHON_BIN="${PYTHON_BIN:-python3}"

for arg in "$@"; do
  case "$arg" in
    --skip-figures) SKIP_FIGURES=1 ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ -x "/opt/homebrew/bin/python3" ]]; then
  if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
  then
    PYTHON_BIN="/opt/homebrew/bin/python3"
  fi
fi

if command -v rg >/dev/null 2>&1; then
  LOG_GREP=(rg -n)
  LOG_GREP_QUIET=(rg -q)
else
  LOG_GREP=(grep -nE)
  LOG_GREP_QUIET=(grep -qE)
fi

check_latex_log() {
  local log_file="$1"
  local label="${2:-LaTeX}"

  if [[ ! -f "$log_file" ]]; then
    echo "ERROR: $label log not found: $log_file" >&2
    exit 1
  fi

  if "${LOG_GREP[@]}" "(LaTeX Error|LaTeX Warning|Overfull \\\\hbox)" "$log_file" >/dev/null; then
    echo "ERROR: $label log contains errors/warnings/overfull boxes: $log_file" >&2
    "${LOG_GREP[@]}" "(LaTeX Error|LaTeX Warning|Overfull \\\\hbox)" "$log_file" >&2 || true
    exit 1
  fi
}

check_type3_fonts() {
  local pdf_file="$1"
  local label="${2:-PDF}"

  if [[ ! -f "$pdf_file" ]]; then
    echo "ERROR: $label PDF not found: $pdf_file" >&2
    exit 1
  fi

  if ! command -v pdffonts >/dev/null 2>&1; then
    echo "ERROR: pdffonts not found; install poppler to enable Type 3 font checks." >&2
    exit 1
  fi

  if pdffonts "$pdf_file" | "${LOG_GREP_QUIET[@]}" "Type 3"; then
    echo "ERROR: $label contains Type 3 fonts (IEEE PDF eXpress may reject): $pdf_file" >&2
    pdffonts "$pdf_file" | "${LOG_GREP[@]}" "Type 3" >&2 || true
    exit 1
  fi
}

run_pdflatex_relaxed() {
  local tex_file="$1"
  pdflatex -interaction=nonstopmode "$tex_file" || true
}

cd "$DOCS_DIR"
mkdir -p "$OUT_DIR"

echo "=== 开始编译 ==="

# 先生成 IEEE figures（避免 Type 3 字体 / hatch 等问题传递到最终 PDF）
if [[ "$SKIP_FIGURES" -eq 0 && -f "$PROJECT_DIR/Scripts/generate_ieee_figures.py" ]]; then
    echo "=== 生成 figures ==="
    MPLBACKEND=Agg "$PYTHON_BIN" "$PROJECT_DIR/Scripts/generate_ieee_figures.py"
fi

# 预编译主文，生成主文 aux（供 supplementary 交叉引用）
echo "=== 预编译 main (bootstrap aux) ==="
run_pdflatex_relaxed "$TEX_FILE"

if [[ -f "$SUPP_TEX_FILE" ]]; then
    # 先编 supplementary，生成其 aux（供 main 交叉引用）
    echo "=== 预编译 supplementary (bootstrap aux) ==="
    run_pdflatex_relaxed "$SUPP_TEX_FILE"
    run_pdflatex_relaxed "$SUPP_TEX_FILE"
fi

# 再编译主文两次确保引用收敛
echo "=== 编译 main ==="
run_pdflatex_relaxed "$TEX_FILE"
pdflatex -interaction=nonstopmode "$TEX_FILE"

if [[ -f "$SUPP_TEX_FILE" ]]; then
    # 主文稳定后回编 supplementary，确保其引用也收敛
    echo "=== 回编 supplementary ==="
    run_pdflatex_relaxed "$SUPP_TEX_FILE"
    pdflatex -interaction=nonstopmode "$SUPP_TEX_FILE"
fi

if [[ "$SKIP_CHECKS" -eq 0 ]]; then
    check_latex_log "$DOCS_DIR/${TEX_FILE%.tex}.log" "Main paper"
    check_type3_fonts "$DOCS_DIR/$PDF_FILE" "Main paper"
    if [[ -f "$SUPP_TEX_FILE" ]]; then
        check_latex_log "$DOCS_DIR/${SUPP_TEX_FILE%.tex}.log" "Supplementary"
        check_type3_fonts "$DOCS_DIR/$SUPP_PDF_FILE" "Supplementary"
    fi
fi

if [ -f "$PDF_FILE" ]; then
    # 生成时间戳
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    ARCHIVE_NAME="paper_${TIMESTAMP}.pdf"

    # 复制到 out 目录
    cp "$PDF_FILE" "$OUT_DIR/$ARCHIVE_NAME"

    echo ""
    echo "=== 编译成功 ==="
    echo "输出文件: $DOCS_DIR/$PDF_FILE"
    echo "归档文件: $OUT_DIR/$ARCHIVE_NAME"
    echo ""
    echo "当前归档历史:"
    ls -lt "$OUT_DIR"/*.pdf 2>/dev/null | head -10
else
    echo "=== 编译失败 ==="
    exit 1
fi
