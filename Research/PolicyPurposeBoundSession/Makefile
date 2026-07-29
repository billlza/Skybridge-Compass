PYTHON ?= python3
LATEXMK ?= latexmk
PDFINFO ?= pdfinfo
OUTPUT_DIR ?= output/pdf

.PHONY: all ledger test pdf check clean

all: check

ledger:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) artifact/validate_claim_ledger.py artifact/claim-ledger.json

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest -v artifact.test_validate_claim_ledger

pdf:
	$(LATEXMK) -cd -pdf -interaction=nonstopmode -halt-on-error -file-line-error paper/main.tex
	$(LATEXMK) -cd -pdf -interaction=nonstopmode -halt-on-error -file-line-error paper/supplement.tex

check: ledger test pdf
	@command -v rg >/dev/null 2>&1 || { echo "required diagnostic scanner rg is unavailable" >&2; exit 1; }
	@scan_status=0; \
	rg -n "((LaTeX|Package [^:]+|Class [^:]+|pdfTeX) Warning:|Overfull|Underfull|undefined references|undefined citations)" paper/main.log paper/supplement.log || scan_status=$$?; \
	if [ "$$scan_status" -eq 0 ]; then \
		echo "LaTeX diagnostics must be resolved" >&2; \
		exit 1; \
	elif [ "$$scan_status" -ne 1 ]; then \
		echo "LaTeX diagnostic scan failed with status $$scan_status" >&2; \
		exit "$$scan_status"; \
	fi
	@main_pages=`$(PDFINFO) paper/main.pdf | awk '/^Pages:/ {print $$2}'`; \
	if [ -z "$$main_pages" ] || [ "$$main_pages" -gt 13 ]; then \
		echo "main paper page limit failed: $$main_pages" >&2; \
		exit 1; \
	fi
	@supp_pages=`$(PDFINFO) paper/supplement.pdf | awk '/^Pages:/ {print $$2}'`; \
	if [ -z "$$supp_pages" ] || [ "$$supp_pages" -gt 6 ]; then \
		echo "supplement page limit failed: $$supp_pages" >&2; \
		exit 1; \
	fi
	@mkdir -p $(OUTPUT_DIR)
	@cp paper/main.pdf $(OUTPUT_DIR)/policy-to-purpose-to-byte-tifs-draft.pdf
	@cp paper/supplement.pdf $(OUTPUT_DIR)/policy-to-purpose-to-byte-tifs-supplement-draft.pdf

clean:
	$(LATEXMK) -cd -C paper/main.tex
	$(LATEXMK) -cd -C paper/supplement.tex
