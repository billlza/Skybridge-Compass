#!/bin/bash
# CI Check Script for SkyBridge Compass Paper
# Checks source files and compiled PDFs for common issues

set -e
DOCS_DIR="$(dirname "$0")/../Docs"
FAILED=0

echo "=== SkyBridge Compass Paper CI Check ==="
echo ""

# 1. Check source files for soft hyphens (U+00AD)
echo "[1/5] Checking source files for soft hyphens (U+00AD)..."
if LC_ALL=C grep -r $'\xc2\xad' "$DOCS_DIR"/*.tex "$DOCS_DIR"/*.bib 2>/dev/null; then
    echo "  FAIL: Soft hyphens found in source files!"
    FAILED=1
else
    echo "  PASS: No soft hyphens in source"
fi

# 2. Check source files for other problematic Unicode
echo "[2/5] Checking source files for non-ASCII characters..."
NON_ASCII=$(cat "$DOCS_DIR"/*.tex 2>/dev/null | python3 -c "
import sys
text = sys.stdin.read()
count = sum(1 for c in text if ord(c) > 127)
print(count)
")
if [ "$NON_ASCII" -gt 0 ]; then
    echo "  WARN: Found $NON_ASCII non-ASCII characters (review manually)"
else
    echo "  PASS: Source files are ASCII-clean"
fi

# 3. Compile and check PDF
echo "[3/5] Compiling PDF..."
cd "$DOCS_DIR"
pdflatex -interaction=nonstopmode IEEE_Paper_SkyBridge_Compass_patched.tex > /dev/null 2>&1
pdflatex -interaction=nonstopmode IEEE_Paper_SkyBridge_Compass_patched.tex > /dev/null 2>&1
pdflatex -interaction=nonstopmode supplementary.tex > /dev/null 2>&1
echo "  DONE: PDFs compiled"

# 4. Check PDF text extraction for soft hyphens
echo "[4/5] Checking PDF text for soft hyphens..."
pdftotext IEEE_Paper_SkyBridge_Compass_patched.pdf /tmp/ci_paper_text.txt
SOFT_HYPHEN=$(python3 -c "
text = open('/tmp/ci_paper_text.txt').read()
print(text.count('\u00ad'))
")
if [ "$SOFT_HYPHEN" -gt 0 ]; then
    echo "  FAIL: Found $SOFT_HYPHEN soft hyphens in PDF text!"
    FAILED=1
else
    echo "  PASS: No soft hyphens in PDF"
fi

# 5. Check for undefined references
echo "[5/5] Checking for undefined references..."
UNDEF=$(grep -c "undefined" IEEE_Paper_SkyBridge_Compass_patched.log 2>/dev/null || true)
UNDEF=${UNDEF:-0}
if [ "$UNDEF" -gt 0 ]; then
    echo "  WARN: $UNDEF undefined reference warnings (run pdflatex again)"
else
    echo "  PASS: All references resolved"
fi

echo ""
echo "=== CI Check Complete ==="
if [ "$FAILED" -eq 1 ]; then
    echo "STATUS: FAILED - Fix issues above before submission"
    exit 1
else
    echo "STATUS: PASSED"
    exit 0
fi
