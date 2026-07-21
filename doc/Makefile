# Build a PDF of the design spec (design-spec.md) via the pandoc + LaTeX stack.
#
#   make            # build build/design-spec.pdf
#   make clean      # remove build/
#
# Requires pandoc and a LaTeX engine. The engine is auto-detected — pdflatex
# (proven on this document) is preferred, then xelatex (better Unicode, e.g. if
# diagrams or wide glyphs are added later). Override with `make PDF_ENGINE=xelatex`.
#   - pdflatex: sudo apt install texlive-latex-recommended texlive-latex-extra
#   - xelatex:  sudo apt install texlive-xetex
# If pandoc or a LaTeX engine is absent, the build degrades to a clean skip
# (exit 0) so it never breaks a tree-wide `make` / CI run.

BUILD_DIR   := build
SOURCE_MD   := design-spec.md
OUTPUT_PDF  := $(BUILD_DIR)/design-spec.pdf
BUILD_DATE  := $(shell date +%Y-%m-%d)

# Prefer pdflatex, fall back to xelatex; empty if neither is installed.
PDF_ENGINE  ?= $(shell command -v pdflatex >/dev/null 2>&1 && echo pdflatex || \
                       { command -v xelatex >/dev/null 2>&1 && echo xelatex; })

.PHONY: all pdf clean

all: pdf

pdf:
	@set -e; \
	command -v pandoc >/dev/null 2>&1 || { \
		echo "[DOC] pandoc not on PATH; skipping (install pandoc + a LaTeX engine)"; exit 0; }; \
	if [ -z "$(PDF_ENGINE)" ]; then \
		echo "[DOC] no LaTeX engine (pdflatex/xelatex) on PATH; skipping"; exit 0; fi; \
	mkdir -p $(BUILD_DIR); \
	echo "[DOC] building $(OUTPUT_PDF) with $(PDF_ENGINE) (date $(BUILD_DATE))..."; \
	pandoc $(SOURCE_MD) -o $(OUTPUT_PDF) \
		--pdf-engine=$(PDF_ENGINE) \
		--toc --toc-depth=2 \
		-M date="$(BUILD_DATE)" \
		-V geometry:margin=1in \
		-V colorlinks=true -V linkcolor=RoyalBlue -V toccolor=black \
		--highlight-style=tango; \
	echo "[DOC] wrote $(OUTPUT_PDF)"

clean:
	rm -rf $(BUILD_DIR)
