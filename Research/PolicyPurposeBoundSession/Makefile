PYTHON ?= python3
LATEXMK ?= latexmk
PDFINFO ?= pdfinfo
PDFTOTEXT ?= pdftotext
OUTPUT_DIR ?= output/pdf
METADATA_VALIDATOR = submission/validate_manuscript_metadata.py
MAIN_OUTPUT = $(OUTPUT_DIR)/policy-to-purpose-to-byte-tifs-draft.pdf
SUPPLEMENT_OUTPUT = $(OUTPUT_DIR)/policy-to-purpose-to-byte-tifs-supplement-draft.pdf

.PHONY: all ledger metadata metadata-check test pdf check submission-check clean

all: check

ledger:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) artifact/validate_claim_ledger.py artifact/claim-ledger.json

metadata:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(METADATA_VALIDATOR) --root . --write-generated

metadata-check:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(METADATA_VALIDATOR) --root .

test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest -v \
		artifact.test_validate_claim_ledger \
		submission.test_validate_manuscript_metadata

pdf: metadata-check
	$(LATEXMK) -cd -pdf -interaction=nonstopmode -halt-on-error -file-line-error paper/main.tex
	$(LATEXMK) -cd -pdf -interaction=nonstopmode -halt-on-error -file-line-error paper/supplement.tex

check: ledger test pdf
	@command -v rg >/dev/null 2>&1 || { echo "required diagnostic scanner rg is unavailable" >&2; exit 1; }
	@command -v $(PDFINFO) >/dev/null 2>&1 || { echo "required PDF inspector is unavailable" >&2; exit 1; }
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
	case "$$main_pages" in ''|*[!0-9]*) \
		echo "main paper page count is not a positive integer: $$main_pages" >&2; exit 1;; \
	esac; \
	if [ "$$main_pages" -gt 13 ]; then \
		echo "main paper page limit failed: $$main_pages" >&2; \
		exit 1; \
	fi
	@supp_pages=`$(PDFINFO) paper/supplement.pdf | awk '/^Pages:/ {print $$2}'`; \
	case "$$supp_pages" in ''|*[!0-9]*) \
		echo "supplement page count is not a positive integer: $$supp_pages" >&2; exit 1;; \
	esac; \
	if [ "$$supp_pages" -gt 6 ]; then \
		echo "supplement page limit failed: $$supp_pages" >&2; \
		exit 1; \
	fi
	@PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(METADATA_VALIDATOR) --root . \
		--pdfinfo "$(PDFINFO)" --pdftotext "$(PDFTOTEXT)" \
		--main-pdf paper/main.pdf \
		--supplement-pdf paper/supplement.pdf
	@set -eu; \
	mkdir -p "$(OUTPUT_DIR)"; \
	main_tmp="$(MAIN_OUTPUT).tmp.$$$$"; \
	supplement_tmp="$(SUPPLEMENT_OUTPUT).tmp.$$$$"; \
	cleanup() { /bin/rm -f "$$main_tmp" "$$supplement_tmp"; }; \
	trap cleanup EXIT HUP INT TERM; \
	cp paper/main.pdf "$$main_tmp"; \
	cp paper/supplement.pdf "$$supplement_tmp"; \
	cmp -s paper/main.pdf "$$main_tmp" || { echo "staged main PDF differs from the built PDF" >&2; exit 1; }; \
	cmp -s paper/supplement.pdf "$$supplement_tmp" || { echo "staged supplement PDF differs from the built PDF" >&2; exit 1; }; \
	mv -f "$$main_tmp" "$(MAIN_OUTPUT)"; \
	mv -f "$$supplement_tmp" "$(SUPPLEMENT_OUTPUT)"; \
	trap - EXIT HUP INT TERM
	@PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(METADATA_VALIDATOR) --root . \
		--pdfinfo "$(PDFINFO)" --pdftotext "$(PDFTOTEXT)" \
		--main-pdf "$(MAIN_OUTPUT)" \
		--supplement-pdf "$(SUPPLEMENT_OUTPUT)"

submission-check: check
	@PYTHONDONTWRITEBYTECODE=1 $(PYTHON) $(METADATA_VALIDATOR) --root . \
		--require-confirmed-email \
		--pdfinfo "$(PDFINFO)" --pdftotext "$(PDFTOTEXT)" \
		--main-pdf "$(MAIN_OUTPUT)" \
		--supplement-pdf "$(SUPPLEMENT_OUTPUT)"

clean:
	$(LATEXMK) -cd -C paper/main.tex
	$(LATEXMK) -cd -C paper/supplement.tex
