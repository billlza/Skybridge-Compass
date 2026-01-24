#!/usr/bin/env python3
r"""
Export a clean, version-consistent DOCX from the LaTeX source used to build the IEEE PDF.

Goals:
- Resolve \ref{} and \cite{} to concrete numbers using the LaTeX .aux file (prevents drift/mismatches).
- Replace TikZ figures with pre-rendered PNGs (Word cannot render TikZ).
- Replace .pdf figure includes with .png counterparts for DOCX embedding.

This script is intentionally conservative: it creates a derived LaTeX file and runs pandoc on it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ET


NEWLABEL_RE = re.compile(r"\\newlabel\{(?P<label>[^}]+)\}\{\{(?P<num>[^}]*)\}\{")
BIBCITE_RE = re.compile(r"\\bibcite\{(?P<key>[^}]+)\}\{(?P<num>[^}]+)\}")


def parse_aux(aux_path: Path) -> tuple[dict[str, str], dict[str, str]]:
    ref_map: dict[str, str] = {}
    cite_map: dict[str, str] = {}
    text = aux_path.read_text(encoding="utf-8", errors="ignore")

    for m in NEWLABEL_RE.finditer(text):
        ref_map[m.group("label")] = m.group("num")

    for m in BIBCITE_RE.finditer(text):
        cite_map[m.group("key")] = m.group("num")

    return ref_map, cite_map


def merge_maps(base: dict[str, str], extra: dict[str, str]) -> dict[str, str]:
    merged = dict(base)
    merged.update(extra)
    return merged


def replace_refs(tex: str, ref_map: dict[str, str]) -> str:
    def repl(m: re.Match) -> str:
        key = m.group(1)
        return ref_map.get(key, "??")

    # \ref{...}
    tex = re.sub(r"\\ref\{([^}]+)\}", repl, tex)
    # \pageref{...} (rare)
    tex = re.sub(r"\\pageref\{([^}]+)\}", repl, tex)
    return tex


def replace_cites(tex: str, cite_map: dict[str, str]) -> str:
    def repl(m: re.Match) -> str:
        keys = [k.strip() for k in m.group(1).split(",") if k.strip()]
        nums = [cite_map.get(k, "??") for k in keys]
        return "[" + ", ".join(nums) + "]"

    # Handle \cite{a,b,c}
    tex = re.sub(r"\\cite\{([^}]+)\}", repl, tex)
    return tex


def strip_latex_softbreaks(tex: str) -> str:
    # Remove PDF-specific soft break helpers that look ugly in Word.
    tex = tex.replace("\\allowbreak", "")
    tex = tex.replace("\\hspace{0pt}", "")
    return tex


def style_id_by_name(styles_xml: str, wanted_name: str) -> str | None:
    """
    Return w:styleId for a given human-readable style name (w:name w:val="...").
    """
    # Best-effort regex (avoid full XML parsing for speed/robustness).
    # Pattern: <w:style ... w:styleId="X"> ... <w:name w:val="Wanted"/>
    pat = re.compile(
        r'<w:style[^>]*w:styleId="(?P<id>[^"]+)"[^>]*>[\s\S]*?<w:name[^>]*w:val="(?P<name>[^"]+)"',
        re.IGNORECASE,
    )
    for m in pat.finditer(styles_xml):
        if m.group("name").strip().lower() == wanted_name.strip().lower():
            return m.group("id")
    return None

def style_id_by_name_xml(styles_xml_bytes: bytes, wanted_name: str) -> str | None:
    """
    Parse styles.xml and return styleId for a given human-readable style name.
    More robust than regex (handles localized templates cleanly).
    """
    ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    try:
        root = ET.fromstring(styles_xml_bytes)
    except Exception:
        return None
    wanted = wanted_name.strip().lower()
    for st in root.findall("w:style", ns):
        sid = st.attrib.get(f"{{{ns['w']}}}styleId")
        name_el = st.find("w:name", ns)
        name = name_el.attrib.get(f"{{{ns['w']}}}val") if name_el is not None else None
        if sid and name and name.strip().lower() == wanted:
            return sid
    return None


def extract_labeled_tables_as_placeholders(
    tex: str,
    ref_map: dict[str, str],
    cite_map: dict[str, str],
) -> tuple[str, dict[str, dict]]:
    """
    Replace each labeled table environment with:
      - a caption paragraph (already prefixed by prefix_table_and_figure_captions_in_envs)
      - a placeholder paragraph: DOCX_TABLE_PLACEHOLDER::<tab:...>

    And return a mapping label -> matrix(rows x cols) for later DOCX XML injection.
    """
    table_pat = re.compile(r"(\\begin\{table\*?\}[\s\S]*?\\end\{table\*?\})", re.DOTALL)
    tab_pat = re.compile(r"(\\begin\{tabular\}[\s\S]*?\\end\{tabular\})", re.DOTALL)

    def simplify_tabular_for_matrix(tab: str) -> str:
        # Remove wrappers and noise; keep plain \hline and rows.
        tab = _strip_minipage_wrappers(tab)
        tab = re.sub(r"\\noalign\{[^}]*\}", "", tab)
        tab = tab.replace("\\toprule", "\\hline").replace("\\midrule", "\\hline").replace("\\bottomrule", "\\hline")
        tab = re.sub(r"\\cmidrule\([^)]*\)\{[^}]*\}\s*", "", tab)
        tab = re.sub(r"\\cmidrule\{[^}]*\}\s*", "", tab)
        # Normalize multirow -> content only.
        tab = re.sub(r"\\multirow\{\d+\}\{[^}]*\}\{([\s\S]*?)\}", r"\1", tab)

        # Expand multicolumn inside each row.
        mc_re = re.compile(r"\\multicolumn\{(\d+)\}\{[^}]*\}\{([\s\S]*?)\}")

        def expand_row(line: str) -> str:
            if "\\\\" not in line:
                return line
            cells = [c.strip() for c in line.split("&")]
            out: list[str] = []
            for cell in cells:
                m = mc_re.search(cell)
                if not m:
                    out.append(cell)
                    continue
                try:
                    span = int(m.group(1))
                except Exception:
                    span = 1
                content = m.group(2).strip()
                # Replace the entire cell with the content
                cell2 = mc_re.sub(content, cell).strip()
                out.append(cell2)
                for _ in range(max(0, span - 1)):
                    out.append("")
            return " & ".join(out)

        tab = "\n".join(expand_row(ln) for ln in tab.splitlines())
        return tab

    def tabular_to_matrix(tab: str) -> list[list[str]]:
        tab = simplify_tabular_for_matrix(tab)
        # Remove begin/end
        tab = re.sub(r"^\\begin\{tabular\}\{[^}]*\}\s*", "", tab, flags=re.DOTALL)
        tab = re.sub(r"\\end\{tabular\}\s*$", "", tab, flags=re.DOTALL)
        # Resolve citations/refs so captions and table content are stable.
        tab = replace_cites(tab, cite_map)
        tab = replace_refs(tab, ref_map)
        # Drop hlines and empty lines.
        lines = [ln.strip() for ln in tab.splitlines() if ln.strip() and ln.strip() != "\\hline"]
        rows: list[list[str]] = []
        for ln in lines:
            if not ln.endswith("\\\\"):
                continue
            ln = ln[:-2].strip()
            cells = [strip_latex_commands(c.strip(), cite_map=cite_map) for c in ln.split("&")]
            # Clean up braces and repeated spaces.
            cells = [re.sub(r"\s+", " ", c.replace("{", "").replace("}", "")).strip() for c in cells]
            rows.append(cells)
        # Normalize to rectangular matrix
        max_cols = max((len(r) for r in rows), default=0)
        return [r + [""] * (max_cols - len(r)) for r in rows]

    tables: dict[str, dict] = {}

    def repl(m: re.Match) -> str:
        block = m.group(1)
        lm = re.search(r"\\label\{(tab:[^}]+)\}", block)
        if not lm:
            return block
        label = lm.group(1)
        # Balanced caption extraction is critical because captions often contain nested braces
        # (e.g., \cite{...}, \texttt{...}), and a naive regex will truncate.
        caption = (extract_braced_command_content(block, "caption") or "").strip()
        is_star = block.lstrip().startswith("\\begin{table*}")
        # Grab first tabular in the table env
        tm = tab_pat.search(block)
        if tm:
            tables[label] = {
                "matrix": tabular_to_matrix(tm.group(1)),
                "span2": bool(is_star),
            }
        else:
            tables[label] = {"matrix": [], "span2": bool(is_star)}

        # Build a caption paragraph (italic) and a placeholder paragraph.
        # NOTE: caption has already been prefixed to "TABLE X." earlier.
        cap_txt = strip_latex_commands(caption, cite_map=cite_map)
        cap_txt = cap_txt.replace("\\pm", "±")
        cap_txt = re.sub(r"\$([^$]*)\$", r"\1", cap_txt).replace("$", "")
        cap_txt = cap_txt.replace("{", "").replace("}", "")
        span_tag = "SPAN2" if is_star else "SPAN1"
        return (
            f"\n\\noindent\\textit{{{cap_txt}}}\\par\n"
            f"\\noindent DOCX_TABLE_PLACEHOLDER::{label}::{span_tag}\\par\n"
        )

    return table_pat.sub(repl, tex), tables



def inject_tables_into_docx(
    docx_path: Path,
    table_matrices: dict[str, dict],
    table_style_id: str | None,
) -> None:
    """
    Replace DOCX_TABLE_PLACEHOLDER::<tab:...> paragraphs with real Word tables (w:tbl).
    """
    ns_w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    ET.register_namespace("w", ns_w)

    with zipfile.ZipFile(docx_path) as z:
        doc_xml = z.read("word/document.xml")
        styles_xml = z.read("word/styles.xml")
        other_files = {name: z.read(name) for name in z.namelist() if name not in ("word/document.xml",)}

    root = ET.fromstring(doc_xml)
    body = root.find(f".//{{{ns_w}}}body")
    if body is None:
        return

    def paragraph_text(p: ET.Element) -> str:
        ts = p.findall(f".//{{{ns_w}}}t")
        return "".join([t.text or "" for t in ts])

    def make_text_run(text: str, bold: bool = False, size_half_points: int = 16) -> ET.Element:
        r = ET.Element(f"{{{ns_w}}}r")
        rpr = ET.SubElement(r, f"{{{ns_w}}}rPr")
        if bold:
            ET.SubElement(rpr, f"{{{ns_w}}}b")
        # Tables in IEEE/TDSC are typically slightly smaller and strictly Latin-wrapped.
        # Set explicit font/size/lang to avoid Word template/theme or East Asian wrapping quirks
        # that can break Latin words mid-token.
        rFonts = ET.SubElement(rpr, f"{{{ns_w}}}rFonts")
        rFonts.set(f"{{{ns_w}}}ascii", "Times New Roman")
        rFonts.set(f"{{{ns_w}}}hAnsi", "Times New Roman")
        rFonts.set(f"{{{ns_w}}}cs", "Times New Roman")
        rFonts.set(f"{{{ns_w}}}eastAsia", "Times New Roman")
        ET.SubElement(rpr, f"{{{ns_w}}}sz").set(f"{{{ns_w}}}val", str(size_half_points))
        ET.SubElement(rpr, f"{{{ns_w}}}szCs").set(f"{{{ns_w}}}val", str(size_half_points))
        lang = ET.SubElement(rpr, f"{{{ns_w}}}lang")
        lang.set(f"{{{ns_w}}}val", "en-US")
        lang.set(f"{{{ns_w}}}eastAsia", "en-US")
        lang.set(f"{{{ns_w}}}bidi", "en-US")
        t = ET.SubElement(r, f"{{{ns_w}}}t")
        # Preserve leading/trailing spaces
        if text.startswith(" ") or text.endswith(" "):
            t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        t.text = text
        return r

    def make_cell(text: str, bold: bool = False, width_twips: int | None = None, center: bool = False) -> ET.Element:
        tc = ET.Element(f"{{{ns_w}}}tc")
        tcpr = ET.SubElement(tc, f"{{{ns_w}}}tcPr")
        if width_twips is not None:
            tcW = ET.SubElement(tcpr, f"{{{ns_w}}}tcW")
            tcW.set(f"{{{ns_w}}}type", "dxa")
            tcW.set(f"{{{ns_w}}}w", str(max(1, int(width_twips))))
        p = ET.SubElement(tc, f"{{{ns_w}}}p")
        # Tighten paragraph spacing inside table cells (IEEE-like compactness).
        pPr = ET.SubElement(p, f"{{{ns_w}}}pPr")
        spacing = ET.SubElement(pPr, f"{{{ns_w}}}spacing")
        spacing.set(f"{{{ns_w}}}before", "0")
        spacing.set(f"{{{ns_w}}}after", "0")
        spacing.set(f"{{{ns_w}}}line", "240")
        spacing.set(f"{{{ns_w}}}lineRule", "auto")
        if center:
            ET.SubElement(pPr, f"{{{ns_w}}}jc").set(f"{{{ns_w}}}val", "center")

        r = make_text_run(text, bold=bold, size_half_points=16)
        p.append(r)
        return tc

    def _set_cell_bottom_border(tc: ET.Element, sz: str = "6") -> None:
        """
        Apply a bottom border to a table cell (used for the header midrule).
        Word border sizes are in eighths of a point.
        """
        tcpr = tc.find(f"{{{ns_w}}}tcPr")
        if tcpr is None:
            tcpr = ET.SubElement(tc, f"{{{ns_w}}}tcPr")
        borders = tcpr.find(f"{{{ns_w}}}tcBorders")
        if borders is None:
            borders = ET.SubElement(tcpr, f"{{{ns_w}}}tcBorders")
        bottom = borders.find(f"{{{ns_w}}}bottom")
        if bottom is None:
            bottom = ET.SubElement(borders, f"{{{ns_w}}}bottom")
        bottom.set(f"{{{ns_w}}}val", "single")
        bottom.set(f"{{{ns_w}}}sz", sz)
        bottom.set(f"{{{ns_w}}}space", "0")
        bottom.set(f"{{{ns_w}}}color", "000000")

    def _compute_column_widths_twips(matrix: list[list[str]], total_width_twips: int) -> list[int]:
        cols = max((len(r) for r in matrix), default=0)
        if cols <= 0:
            return []

        max_lens = [0] * cols
        for r in matrix:
            for i in range(cols):
                s = (r[i] if i < len(r) else "") or ""
                # Normalize whitespace (length heuristics depend on visible chars).
                s = re.sub(r"\s+", " ", s).strip()
                max_lens[i] = max(max_lens[i], len(s))

        # Heuristic weights: give more width to columns with longer content.
        # Cap to prevent a single long cell from starving other columns.
        weights = [max(3, min(40, l)) for l in max_lens]
        # Slightly prefer the first column (often "Protocol"/"Suite") to reduce ugly wraps.
        if weights:
            weights[0] = int(round(weights[0] * 1.2))

        min_w = 240  # 1/6 inch; prevents ultra-thin columns that trigger mid-word breaks
        total = max(1, sum(weights))
        raw = [int(round((w / total) * total_width_twips)) for w in weights]
        widths = [max(min_w, w) for w in raw]

        # Normalize sum exactly to total_width_twips.
        cur = sum(widths)
        if cur != total_width_twips and widths:
            widths[-1] += (total_width_twips - cur)
            if widths[-1] < min_w:
                # If we underflow, steal from earlier columns.
                deficit = min_w - widths[-1]
                widths[-1] = min_w
                for j in range(len(widths) - 1):
                    take = min(deficit, max(0, widths[j] - min_w))
                    widths[j] -= take
                    deficit -= take
                    if deficit <= 0:
                        break
        return widths

    def make_table(matrix: list[list[str]], total_width_twips: int, span2: bool) -> ET.Element:
        tbl = ET.Element(f"{{{ns_w}}}tbl")
        tblpr = ET.SubElement(tbl, f"{{{ns_w}}}tblPr")
        if table_style_id:
            ts = ET.SubElement(tblpr, f"{{{ns_w}}}tblStyle")
            ts.set(f"{{{ns_w}}}val", table_style_id)
        # Critical for IEEE/TDSC readability:
        # - Fixed total width (so Word doesn't "micro-fit" columns and break words mid-token)
        # - Explicit grid/column widths + cell widths
        tblW = ET.SubElement(tblpr, f"{{{ns_w}}}tblW")
        tblW.set(f"{{{ns_w}}}type", "dxa")
        tblW.set(f"{{{ns_w}}}w", str(max(1, int(total_width_twips))))
        ET.SubElement(tblpr, f"{{{ns_w}}}tblLayout").set(f"{{{ns_w}}}type", "fixed")

        # Booktabs-like three-line table borders:
        # - top rule
        # - header bottom rule (applied per-cell on first row)
        # - bottom rule
        # No vertical lines; no inner horizontal rules for body rows.
        borders = ET.SubElement(tblpr, f"{{{ns_w}}}tblBorders")
        for side in ("left", "right", "insideH", "insideV"):
            ET.SubElement(borders, f"{{{ns_w}}}{side}").set(f"{{{ns_w}}}val", "nil")
        for side in ("top", "bottom"):
            el = ET.SubElement(borders, f"{{{ns_w}}}{side}")
            el.set(f"{{{ns_w}}}val", "single")
            el.set(f"{{{ns_w}}}sz", "8")  # ~1pt
            el.set(f"{{{ns_w}}}space", "0")
            el.set(f"{{{ns_w}}}color", "000000")

        # Cell margins: tighten slightly (IEEE-like).
        cell_mar = ET.SubElement(tblpr, f"{{{ns_w}}}tblCellMar")
        for side in ("top", "bottom", "left", "right"):
            el = ET.SubElement(cell_mar, f"{{{ns_w}}}{side}")
            el.set(f"{{{ns_w}}}w", "60")  # twips
            el.set(f"{{{ns_w}}}type", "dxa")

        col_widths = _compute_column_widths_twips(matrix, total_width_twips=total_width_twips)
        if col_widths:
            tblGrid = ET.SubElement(tbl, f"{{{ns_w}}}tblGrid")
            for w in col_widths:
                ET.SubElement(tblGrid, f"{{{ns_w}}}gridCol").set(f"{{{ns_w}}}w", str(max(1, int(w))))

        for ri, row in enumerate(matrix):
            tr = ET.SubElement(tbl, f"{{{ns_w}}}tr")
            for ci, cell in enumerate(row):
                is_header = (ri == 0)
                width = col_widths[ci] if ci < len(col_widths) else None
                tc = make_cell(cell, bold=is_header, width_twips=width, center=is_header)
                # Midrule: underline the header row.
                if is_header:
                    _set_cell_bottom_border(tc, sz="6")
                tr.append(tc)
        return tbl

    def _ensure_ppr(p: ET.Element) -> ET.Element:
        pPr = p.find(f"{{{ns_w}}}pPr")
        if pPr is None:
            pPr = ET.Element(f"{{{ns_w}}}pPr")
            p.insert(0, pPr)
        return pPr

    def _attach_continuous_sectpr(p: ET.Element, cols: int) -> None:
        """
        Attach a continuous section break to an existing paragraph.
        Word's section breaks are represented as <w:sectPr> within the paragraph properties
        of the last paragraph of the previous section. Attaching here is more reliable than
        inserting standalone empty paragraphs (which can collapse layout).
        """
        pPr = _ensure_ppr(p)
        # Avoid double-applying.
        existing = pPr.find(f"{{{ns_w}}}sectPr")
        if existing is not None:
            pPr.remove(existing)
        sectPr = ET.SubElement(pPr, f"{{{ns_w}}}sectPr")
        ET.SubElement(sectPr, f"{{{ns_w}}}type").set(f"{{{ns_w}}}val", "continuous")
        cols_el = ET.SubElement(sectPr, f"{{{ns_w}}}cols")
        cols_el.set(f"{{{ns_w}}}num", str(cols))
        cols_el.set(f"{{{ns_w}}}space", "360")

    def _make_sect_break_para(cols: int) -> ET.Element:
        # Paragraph that carries a continuous section break (used for the "after table" switch-back).
        p = ET.Element(f"{{{ns_w}}}p")
        _attach_continuous_sectpr(p, cols=cols)
        return p

    # Iterate body children and replace placeholder paragraphs.
    children = list(body)
    for child in children:
        if child.tag != f"{{{ns_w}}}p":
            continue
        txt = paragraph_text(child)
        if "DOCX_TABLE_PLACEHOLDER::" not in txt:
            continue
        payload = txt.split("DOCX_TABLE_PLACEHOLDER::", 1)[1].strip()
        # Format: <label>::SPAN1|SPAN2
        parts = payload.split("::")
        label = parts[0].strip()
        span2 = (len(parts) >= 2 and parts[1].strip().upper() == "SPAN2")
        info = table_matrices.get(label) or {}
        matrix = info.get("matrix") if isinstance(info, dict) else info
        if matrix is None:
            matrix = []
        idx = list(body).index(child)
        body.remove(child)

        # If this table came from LaTeX table*, make it span both columns in Word by
        # attaching a continuous 1-col section break to the caption paragraph immediately
        # preceding the placeholder, then inserting a continuous 2-col break after the table.
        if span2:
            # Full-width table* section: 1 column section width ~= 6.5" (Letter - 1" margins both sides)
            total_twips = 9360
            tbl = make_table(matrix, total_width_twips=total_twips, span2=True)
            # Attach 1-col section break to previous paragraph (caption) if possible.
            prev = None
            if idx - 1 >= 0:
                prev = list(body)[idx - 1]
                if prev.tag == f"{{{ns_w}}}p":
                    _attach_continuous_sectpr(prev, cols=1)

            # Insert the table at the placeholder position.
            body.insert(idx, tbl)
            idx += 1
            # Switch back to 2 columns immediately after the table.
            body.insert(idx, _make_sect_break_para(cols=2))
        else:
            # Single-column tables inside a 2-column section: limit to one column width.
            # 6.5" text width -> (6.5" - 0.25" gap) / 2 ~= 3.125" => ~4500 twips.
            total_twips = 4500
            tbl = make_table(matrix, total_width_twips=total_twips, span2=False)
            body.insert(idx, tbl)

    # Write back into docx zip.
    tmp_out = docx_path.with_suffix(".tmp.docx")
    with zipfile.ZipFile(tmp_out, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr("word/document.xml", ET.tostring(root, encoding="utf-8", xml_declaration=True))
        for name, data in other_files.items():
            if name == "word/document.xml":
                continue
            z.writestr(name, data)
    tmp_out.replace(docx_path)


def expand_simple_macros(tex: str) -> str:
    # Expand \artifactdate from its \newcommand definition, if present.
    m = re.search(r"\\newcommand\{\\artifactdate\}\{([^}]*)\}", tex)
    if m:
        date = m.group(1).strip()
        # Remove the macro definition itself to avoid producing invalid TeX like:
        # \newcommand{2026-01-16}{2026-01-16}
        tex = re.sub(r"^\\newcommand\{\\artifactdate\}\{[^}]*\}\s*$", "", tex, flags=re.MULTILINE)
        # Replace only the standalone macro \artifactdate, not prefixes of other macros
        # like \artifactdateSystemImpact.
        tex = re.sub(r"\\artifactdate(?![A-Za-z])", date, tex)
    return tex


def replace_pdf_images_with_png(tex: str, figures_dir: Path) -> str:
    # Replace includegraphics{figures/foo.pdf} -> figures/foo.png if exists.
    def repl(m: re.Match) -> str:
        path = m.group(1)
        if path.endswith(".pdf"):
            png_path = Path(path).with_suffix(".png")
            if (figures_dir / png_path.name).exists():
                return "{" + str(Path(path).with_suffix(".png")).replace("\\", "/") + "}"
        return "{" + path + "}"

    tex = re.sub(r"\{(figures/[^}]+)\}", repl, tex)
    return tex


def replace_tikz_figure(tex: str, label: str, png_rel: str) -> str:
    """
    Replace the entire figure environment that contains the given \\label{...}
    AND a tikzpicture with a simple includegraphics figure using the provided PNG.
    """
    block = extract_figure_env_by_label(tex, label)
    if not block or "\\begin{tikzpicture}" not in block:
        return tex

    # Preserve caption text (first \caption{...})
    cap_m = re.search(r"\\caption\{([\s\S]*?)\}\s*", block, re.DOTALL)
    caption = cap_m.group(1).strip() if cap_m else ""

    # Preserve whether this was figure* (two-column) vs figure.
    is_star = block.startswith("\\begin{figure*}")
    env = "figure*" if is_star else "figure"

    replacement = (
        f"\\begin{{{env}}}[!t]\n"
        "\\centering\n"
        f"\\includegraphics[width=0.95\\linewidth]{{{png_rel}}}\n"
        + (f"\\caption{{{caption}}}\n" if caption else "")
        + f"\\label{{{label}}}\n"
        f"\\end{{{env}}}"
    )

    return tex.replace(block, replacement, 1)


def run(cmd: list[str], cwd: Path) -> None:
    subprocess.run(cmd, cwd=str(cwd), check=True)


def rasterize_pdf_to_png(pdf: Path, out_png: Path, dpi: int) -> None:
    """
    Rasterize a single-page PDF to a PNG using pdftocairo at the given DPI.
    Output is written exactly to out_png.
    """
    pdftocairo = shutil.which("pdftocairo")
    if not pdftocairo:
        raise RuntimeError("pdftocairo not found in PATH (required for PDF->PNG rasterization).")

    out_png.parent.mkdir(parents=True, exist_ok=True)
    base = out_png.with_suffix("")  # pdftocairo appends .png
    subprocess.run(
        [pdftocairo, "-png", "-r", str(dpi), "-singlefile", str(pdf), str(base)],
        check=True,
    )


def extract_figure_env_by_label(tex: str, label: str) -> str | None:
    """
    Best-effort extraction of the figure/figure* environment containing \\label{label}.
    """
    idx = tex.find(f"\\label{{{label}}}")
    if idx == -1:
        return None

    begin_star = tex.rfind("\\begin{figure*}", 0, idx)
    begin_plain = tex.rfind("\\begin{figure}", 0, idx)
    begin_idx = max(begin_star, begin_plain)
    if begin_idx == -1:
        return None

    if begin_idx == begin_star:
        end_idx = tex.find("\\end{figure*}", idx)
        if end_idx == -1:
            return None
        return tex[begin_idx : end_idx + len("\\end{figure*}")]

    end_idx = tex.find("\\end{figure}", idx)
    if end_idx == -1:
        return None
    return tex[begin_idx : end_idx + len("\\end{figure}")]


def build_standalone_tikz_pdf(docs: Path, tex_source: str, label: str, out_pdf: Path) -> bool:
    """
    Build a standalone PDF for a TikZ-based figure (so we can rasterize it with pdftocairo).
    Returns True on success.
    """
    block = extract_figure_env_by_label(tex_source, label)
    if not block or "\\begin{tikzpicture}" not in block:
        return False

    # Strip outer figure wrappers; keep content (resizebox, tikzpicture, etc.).
    inner = re.sub(r"^\\begin\{figure\*?\}\[[^\]]*\]\s*", "", block, flags=re.DOTALL)
    inner = re.sub(r"\\end\{figure\*?\}\s*$", "", inner, flags=re.DOTALL)
    # Remove caption/label (standalone render only)
    inner = re.sub(r"\\caption\{[\s\S]*?\}\s*", "", inner)
    inner = re.sub(rf"\\label\{{{re.escape(label)}\}}\s*", "", inner)

    standalone = (
        "\\documentclass[preview]{standalone}\n"
        "\\usepackage{graphicx}\n"
        "\\usepackage{tikz}\n"
        "\\usetikzlibrary{arrows.meta,positioning,shapes.geometric,calc,fit}\n"
        "\\begin{document}\n"
        + inner
        + "\n\\end{document}\n"
    )

    tmp_dir = docs / "_docx_tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    job = f"_standalone_{label.replace(':', '_')}"
    tex_path = tmp_dir / f"{job}.tex"
    tex_path.write_text(standalone, encoding="utf-8")

    try:
        subprocess.run(
            ["latexmk", "-pdf", "-interaction=nonstopmode", "-halt-on-error", "-jobname=" + job, tex_path.name],
            cwd=str(tmp_dir),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return False

    built_pdf = tmp_dir / f"{job}.pdf"
    if not built_pdf.exists():
        return False

    out_pdf.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built_pdf, out_pdf)
    return True


def expand_inputs(tex: str, docs: Path, max_depth: int = 3) -> str:
    """
    Expand \\input{...} directives for local files (best-effort) to improve DOCX conversion fidelity.
    """
    def _resolve(path: str) -> Path | None:
        path = path.strip()
        if not path:
            return None
        p = Path(path)
        if p.suffix == "":
            p = p.with_suffix(".tex")
        # allow relative paths under docs
        if not p.is_absolute():
            p = (docs / p).resolve()
        try:
            p.relative_to(docs.resolve())
        except Exception:
            return None
        return p if p.exists() else None

    out = tex
    for _ in range(max_depth):
        changed = False

        def repl(m: re.Match) -> str:
            nonlocal changed
            p = _resolve(m.group(1))
            if not p:
                return m.group(0)
            changed = True
            return p.read_text(encoding="utf-8", errors="ignore")

        out2 = re.sub(r"\\input\{([^}]+)\}", repl, out)
        out = out2
        if not changed:
            break
    return out


def normalize_tex_for_word(tex: str) -> str:
    """
    Fix common TeX patterns that turn into broken paths/identifiers in Word.
    """
    # Turn escaped underscores into literal underscores (pandoc tends to insert spaces otherwise).
    tex = tex.replace(r"\_", "_")
    # Replace common math symbols with Unicode to avoid unit/sign corruption.
    tex = tex.replace(r"$\mu$", "µ")
    tex = tex.replace(r"$\times$", "×")
    # IMPORTANT: only replace standalone commands (avoid corrupting macros like \multicolumn).
    tex = re.sub(r"\\times(?![A-Za-z])", "×", tex)
    tex = re.sub(r"\\mu(?![A-Za-z])", "µ", tex)
    return tex


def unwrap_pandocbounded(tex: str) -> str:
    """
    Pandoc's LaTeX writer sometimes wraps \\includegraphics in \\pandocbounded{...}.
    When converting LaTeX -> DOCX via pandoc, the LaTeX reader does NOT expand user macros,
    so we must unwrap it ourselves to keep images.
    """
    marker = r"\pandocbounded{"
    out: list[str] = []
    i = 0
    n = len(tex)

    while i < n:
        j = tex.find(marker, i)
        if j == -1:
            out.append(tex[i:])
            break
        out.append(tex[i:j])
        k = j + len(marker)
        # parse balanced braces starting at k (inside the opening '{')
        depth = 1
        start = k
        while k < n and depth > 0:
            ch = tex[k]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            k += 1
        content = tex[start : k - 1]  # exclude the closing '}'
        out.append(content)
        i = k
    return "".join(out)


def remove_braced_command(tex: str, command: str) -> str:
    """
    Remove occurrences of \\command{...} with balanced-brace parsing (handles nested braces).
    """
    marker = "\\" + command + "{"
    out: list[str] = []
    i = 0
    n = len(tex)
    while i < n:
        j = tex.find(marker, i)
        if j == -1:
            out.append(tex[i:])
            break
        out.append(tex[i:j])
        k = j + len(marker)
        depth = 1
        while k < n and depth > 0:
            ch = tex[k]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            k += 1
        # skip trailing whitespace
        while k < n and tex[k].isspace():
            k += 1
        i = k
    return "".join(out)


def extract_braced_command_content(tex: str, command: str) -> str | None:
    """
    Extract the balanced-brace content of the first occurrence of \\command{...}.
    Returns None if not found or malformed.
    """
    marker = "\\" + command + "{"
    j = tex.find(marker)
    if j == -1:
        return None
    k = j + len(marker)
    depth = 1
    n = len(tex)
    start = k
    while k < n and depth > 0:
        ch = tex[k]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        k += 1
    if depth != 0:
        return None
    return tex[start : k - 1]


def normalize_texttt_code_strings(tex: str) -> str:
    """
    Fix common PDF→Word break artifacts that originate from LaTeX \\texttt{...} with manual breakpoints,
    e.g., `Scripts/ run_ paper_ eval.sh` -> `Scripts/run_paper_eval.sh`.
    """
    def repl(m: re.Match) -> str:
        s = m.group(1)
        s = re.sub(r"/\s+", "/", s)
        s = re.sub(r"\s+/", "/", s)
        s = re.sub(r"_\s+", "_", s)
        s = re.sub(r"\s+_", "_", s)
        # Also remove spaces around dots in file names
        s = re.sub(r"\s*\.\s*", ".", s)
        return f"\\texttt{{{s}}}"

    return re.sub(r"\\texttt\{([^}]*)\}", repl, tex)


def strip_latex_commands(text: str, cite_map: dict[str, str] | None = None) -> str:
    """
    Roughly strip common LaTeX commands from caption text for DOCX.
    """
    s = text
    if cite_map is not None:
        # Normalize citations before removing braces.
        s = replace_cites(s, cite_map)
    s = re.sub(r"\\texttt\{([^}]*)\}", r"\1", s)
    s = re.sub(r"\\emph\{([^}]*)\}", r"\1", s)
    s = re.sub(r"\\mbox\{([^}]*)\}", r"\1", s)
    s = re.sub(r"\\url\{([^}]*)\}", r"\1", s)
    s = re.sub(r"\\allowbreak", "", s)
    s = s.replace("{", "").replace("}", "")
    s = re.sub(r"\s+", " ", s).strip()
    return s


def prefix_captions_for_word(tex: str, ref_map: dict[str, str], cite_map: dict[str, str]) -> str:
    """
    Prefix captions with IEEE-style markers for Word (Fig. N., Table N.).
    This is for DOCX export only (derived TeX), not the submission PDF.
    """
    def fig_repl(m: re.Match) -> str:
        cap = m.group(1).strip()
        lab = m.group(2).strip()
        n = ref_map.get(lab, "??")
        cap = strip_latex_commands(cap, cite_map=cite_map)
        return f"\\\\caption{{Fig. {n}. {cap}}}\\n\\\\label{{{lab}}}"

    out = tex
    out = re.sub(r"\\caption\{([\s\S]*?)\}\s*\\label\{(fig:[^}]+)\}", fig_repl, out)
    return out


def rewrite_bibliography_for_word(tex: str, cite_map: dict[str, str]) -> str:
    """
    Replace thebibliography/bibitem block with a Word-friendly REFERENCES section and [n] entries.
    """
    m = re.search(r"\\begin\{thebibliography\}\{[^}]*\}([\s\S]*?)\\end\{thebibliography\}", tex)
    if not m:
        return tex
    body = m.group(1)

    items: list[tuple[str, str]] = []
    parts = re.split(r"\\bibitem\{([^}]+)\}", body)
    # parts: [preamble, key1, content1, key2, content2, ...]
    for i in range(1, len(parts), 2):
        key = parts[i].strip()
        content = parts[i + 1].strip() if i + 1 < len(parts) else ""
        n = cite_map.get(key, "??")
        content = strip_latex_commands(content)
        # collapse whitespace
        content = re.sub(r"\s+", " ", content).strip()
        items.append((n, content))

    # Sort numerically when possible
    def _num_key(x: tuple[str, str]) -> tuple[int, str]:
        try:
            return (int(x[0]), x[0])
        except Exception:
            return (10**9, x[0])

    items.sort(key=_num_key)

    refs = ["\\section*{REFERENCES}"]
    for n, content in items:
        refs.append(f"[{n}] {content}")

    replacement = "\n\n".join(refs)
    return tex[: m.start()] + replacement + tex[m.end() :]


def tables_to_images_for_word(
    tex: str,
    docs: Path,
    ref_map: dict[str, str],
    cite_map: dict[str, str],
    dpi: int,
    out_dir: Path,
) -> str:
    """
    Convert LaTeX tables into raster images for DOCX export to avoid table data loss in pandoc.
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    table_pat = re.compile(r"\\begin\{table\*?\}[\s\S]*?\\end\{table\*?\}", re.DOTALL)

    def build_table_png(block: str) -> tuple[str | None, str | None, Path | None]:
        lab_m = re.search(r"\\label\{(tab:[^}]+)\}", block)
        cap_m = re.search(r"\\caption\{([\s\S]*?)\}", block)
        label = lab_m.group(1).strip() if lab_m else None
        caption = cap_m.group(1).strip() if cap_m else None
        if not label:
            return (None, None, None)

        # extract inner content (remove outer table env, caption, label)
        inner = re.sub(r"^\\begin\{table\*?\}(?:\[[^\]]*\])?\s*", "", block, flags=re.DOTALL)
        inner = re.sub(r"\\end\{table\*?\}\s*$", "", inner, flags=re.DOTALL)
        inner = remove_braced_command(inner, "caption")
        inner = re.sub(rf"\\label\{{{re.escape(label)}\}}\s*", "", inner)
        inner = replace_cites(inner, cite_map)
        inner = replace_refs(inner, ref_map)

        standalone = (
            "\\documentclass[preview]{standalone}\n"
            "\\usepackage{booktabs}\n"
            "\\usepackage{array}\n"
            "\\usepackage{calc}\n"
            "\\usepackage{amsmath,amssymb}\n"
            "\\usepackage{multirow}\n"
            "\\usepackage{makecell}\n"
            "\\newcommand{\\real}[1]{#1}\n"
            f"\\providecommand{{\\artifactdate}}{{{os.environ.get('ARTIFACT_DATE') or os.environ.get('SKYBRIDGE_ARTIFACT_DATE') or '2026-01-16'}}}\n"
            "\\providecommand{\\tightlist}{}\n"
            "\\begin{document}\n"
            "\\begin{minipage}{\\linewidth}\\centering\n"
            + inner
            + "\n\\end{minipage}\n"
            "\\end{document}\n"
        )

        tmp_dir = docs / "_docx_tmp"
        tmp_dir.mkdir(parents=True, exist_ok=True)
        safe = label.replace(":", "_")
        job = f"_standalone_{safe}"
        tex_path = tmp_dir / f"{job}.tex"
        tex_path.write_text(standalone, encoding="utf-8")

        try:
            subprocess.run(
                ["latexmk", "-pdf", "-interaction=nonstopmode", "-halt-on-error", "-jobname=" + job, tex_path.name],
                cwd=str(tmp_dir),
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            return (label, caption, None)

        pdf_path = tmp_dir / f"{job}.pdf"
        if not pdf_path.exists():
            return (label, caption, None)

        out_pdf = out_dir / f"tab_{safe}.pdf"
        shutil.copy2(pdf_path, out_pdf)
        out_png = out_dir / f"tab_{safe}.png"
        rasterize_pdf_to_png(out_pdf, out_png, dpi)
        return (label, caption, out_png)

    def repl(m: re.Match) -> str:
        block = m.group(0)
        label, caption, png = build_table_png(block)
        if not label or not png or not png.exists():
            return block  # fallback: keep original
        n = ref_map.get(label, "??")
        cap = strip_latex_commands(caption or "", cite_map=cite_map)
        # Pandoc is fragile around math in \textit{...}. Flatten math to plain text.
        # Examples:
        # - "$T_{connect}$" -> "T_connect"
        # - "50$\pm$20" -> "50±20"
        cap = cap.replace("\\pm", "±")
        cap = re.sub(r"\$([^$]*)\$", r"\1", cap)
        cap = cap.replace("$", "")
        cap = cap.replace("{", "").replace("}", "")
        cap = cap.replace("\\_", "_")
        rel = png.relative_to(docs).as_posix()
        # Word-friendly: caption line then image, avoiding broken table conversions.
        return (
            f"\n\\noindent\\textit{{Table {n}. {cap}}}\\par\n"
            f"\\includegraphics[width=\\linewidth]{{{rel}}}\\par\n"
        )

    return table_pat.sub(repl, tex)


def _strip_minipage_wrappers(s: str) -> str:
    # Remove common minipage wrappers used in table headers.
    s = re.sub(r"\\begin\{minipage\}\[[^\]]*\]\{\\linewidth\}\s*", "", s, flags=re.DOTALL)
    s = re.sub(r"\\begin\{minipage\}\{\\linewidth\}\s*", "", s, flags=re.DOTALL)
    s = re.sub(r"\\end\{minipage\}\s*", "", s, flags=re.DOTALL)
    return s


def simplify_tables_for_pandoc(tex: str) -> str:
    """
    Pandoc can produce empty/garbled Word tables from complex IEEE-style tabular specs.
    This pass rewrites tables into a simpler LaTeX tabular that pandoc reliably converts
    into real Word table objects (w:tbl) with populated cells.
    """
    def simplify_tabular(tab: str) -> str:
        # Normalize header/cell wrappers.
        tab = _strip_minipage_wrappers(tab)
        # Remove \noalign{} noise.
        tab = re.sub(r"\\noalign\{[^}]*\}", "", tab)
        # Replace booktabs rules with simple hlines for pandoc.
        tab = tab.replace("\\toprule", "\\hline")
        tab = tab.replace("\\midrule", "\\hline")
        tab = tab.replace("\\bottomrule", "\\hline")
        # Pandoc cannot reliably interpret booktabs midrule helpers.
        tab = re.sub(r"\\cmidrule\([^)]*\)\{[^}]*\}\s*", "", tab)
        tab = re.sub(r"\\cmidrule\{[^}]*\}\s*", "", tab)
        # Remove \multicolumn and \multirow constructs by expanding them to plain cells.
        # This trades visual fidelity for correctness + editability in Word.
        def _expand_multicolumn_in_row(row: str) -> str:
            # Only process rows that end with '\\'
            if "\\\\" not in row:
                return row
            parts = [p.strip() for p in row.split("&")]
            out: list[str] = []
            mc_re = re.compile(r"\\multicolumn\{(\d+)\}\{[^}]*\}\{([\s\S]*?)\}\s*$")
            mr_re = re.compile(r"\\multirow\{(\d+)\}\{[^}]*\}\{([\s\S]*?)\}\s*$")
            for cell in parts:
                # Expand multirow -> just content (no row spanning in Word export).
                m = mr_re.search(cell)
                if m:
                    cell = mr_re.sub(r"\\2", cell)
                m = mc_re.search(cell)
                if m:
                    try:
                        span = int(m.group(1))
                    except Exception:
                        span = 1
                    content = m.group(2).strip()
                    out.append(content)
                    for _ in range(max(0, span - 1)):
                        out.append("")
                else:
                    out.append(cell)
            return " & ".join(out)

        # Apply multicolumn expansion line-by-line.
        new_lines = []
        for ln in tab.splitlines():
            new_lines.append(_expand_multicolumn_in_row(ln))
        tab = "\n".join(new_lines)
        # Remove column spec complexity: replace the entire balanced {...} spec with plain l-columns.
        def count_cols(spec: str) -> int:
            i = 0
            cols = 0
            n = len(spec)

            def skip_braced(start: int) -> int:
                # spec[start] should be '{'
                j = start
                depth = 0
                while j < n:
                    if spec[j] == "{":
                        depth += 1
                    elif spec[j] == "}":
                        depth -= 1
                        if depth == 0:
                            return j + 1
                    j += 1
                return j

            while i < n:
                ch = spec[i]
                if ch in "lcr":
                    cols += 1
                    i += 1
                    continue
                if ch in "pmb" and i + 1 < n and spec[i + 1] == "{":
                    # p{..} / m{..} / b{..}
                    cols += 1
                    i = skip_braced(i + 1)
                    continue
                if ch == "@":
                    # @{...} alignment tweak
                    if i + 1 < n and spec[i + 1] == "{":
                        i = skip_braced(i + 1)
                    else:
                        i += 1
                    continue
                if ch == ">":
                    # >{...} modifier
                    if i + 1 < n and spec[i + 1] == "{":
                        i = skip_braced(i + 1)
                    else:
                        i += 1
                    continue
                if ch == "*":
                    # *{n}{spec} repetition
                    if i + 1 < n and spec[i + 1] == "{":
                        j = skip_braced(i + 1)
                        rep_raw = spec[i + 2 : j - 1]
                        try:
                            rep = int(rep_raw.strip())
                        except Exception:
                            rep = 1
                        if j < n and spec[j] == "{":
                            k = skip_braced(j)
                            inner = spec[j + 1 : k - 1]
                            cols += rep * count_cols(inner)
                            i = k
                            continue
                        i = j
                        continue
                # ignore pipes/spaces/other
                i += 1
            return cols

        begin_marker = "\\begin{tabular}{"
        bidx = tab.find(begin_marker)
        if bidx != -1:
            j = bidx + len(begin_marker)
            depth = 1
            while j < len(tab) and depth > 0:
                ch = tab[j]
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                j += 1
            full_begin = tab[bidx:j]  # includes closing }
            spec = tab[bidx + len(begin_marker) : j - 1]
            # Count columns by counting occurrences of p{...} or alignment tokens.
            cols = count_cols(spec)
            if cols == 0:
                first_row = re.search(r"\\begin\{tabular\}[\s\S]*?\n([^\n]+)", tab)
                if first_row:
                    cols = first_row.group(1).count("&") + 1
            cols = max(cols, 2)
            new_spec = "l" * cols
            tab = tab.replace(full_begin, f"\\begin{{tabular}}{{{new_spec}}}", 1)
        # Remove explicit raggedright declarations that confuse parsing.
        tab = re.sub(r"\\raggedright\s*", "", tab)
        # Collapse excessive whitespace.
        tab = re.sub(r"\n{3,}", "\n\n", tab)
        return tab

    # Rewrite each table environment's tabular.
    table_pat = re.compile(r"(\\begin\{table\*?\}[\s\S]*?\\end\{table\*?\})", re.DOTALL)

    def repl(m: re.Match) -> str:
        block = m.group(1)
        # Only touch blocks that contain tabular.
        if "\\begin{tabular}" not in block:
            return block
        # Simplify only the tabular portion.
        block = re.sub(r"(\\begin\{tabular\}[\s\S]*?\\end\{tabular\})", lambda mm: simplify_tabular(mm.group(1)), block)
        return block

    return table_pat.sub(repl, tex)


def to_roman(n: int) -> str:
    vals = [
        (1000, "M"),
        (900, "CM"),
        (500, "D"),
        (400, "CD"),
        (100, "C"),
        (90, "XC"),
        (50, "L"),
        (40, "XL"),
        (10, "X"),
        (9, "IX"),
        (5, "V"),
        (4, "IV"),
        (1, "I"),
    ]
    out = []
    for v, sym in vals:
        while n >= v:
            out.append(sym)
            n -= v
    return "".join(out) or "I"


def _prefix_caption_in_block(block: str, prefix: str) -> str:
    cidx = block.find("\\caption{")
    if cidx == -1:
        return block
    j = cidx + len("\\caption{")
    depth = 1
    while j < len(block) and depth > 0:
        if block[j] == "{":
            depth += 1
        elif block[j] == "}":
            depth -= 1
        j += 1
    caption = block[cidx + len("\\caption{") : j - 1]
    if caption.strip().startswith(prefix.split()[0]):
        return block
    new_cap = "\\caption{" + prefix + caption.strip() + "}"
    return block[:cidx] + new_cap + block[j:]


def prefix_table_and_figure_captions_in_envs(tex: str, ref_map: dict[str, str]) -> str:
    """
    Prefix captions in a **scoped** way (within each figure/table env only),
    avoiding false matches that can happen with naive lookahead scanning.
    """
    # Tables
    def table_repl(m: re.Match) -> str:
        block = m.group(1)
        lm = re.search(r"\\label\{(tab:[^}]+)\}", block)
        if not lm:
            return block
        lab = lm.group(1)
        num = ref_map.get(lab, "??")
        try:
            roman = to_roman(int(num))
        except Exception:
            roman = str(num)
        return _prefix_caption_in_block(block, f"TABLE {roman}. ")

    tex = re.sub(r"(\\begin\{table\*?\}[\s\S]*?\\end\{table\*?\})", table_repl, tex)

    # Figures
    def fig_repl(m: re.Match) -> str:
        block = m.group(1)
        lm = re.search(r"\\label\{(fig:[^}]+)\}", block)
        if not lm:
            return block
        lab = lm.group(1)
        num = ref_map.get(lab, "??")
        return _prefix_caption_in_block(block, f"Fig. {num}. ")

    tex = re.sub(r"(\\begin\{figure\*?\}[\s\S]*?\\end\{figure\*?\})", fig_repl, tex)
    return tex


def flatten_table_captions_for_pandoc(tex: str) -> str:
    """
    Pandoc often drops LaTeX table captions when producing DOCX.
    For DOCX export we turn \\caption{...}\\label{...} into an explicit paragraph
    directly above the tabular, so the caption exists as editable text in Word.
    """
    table_pat = re.compile(r"(\\begin\{table\*?\}[\s\S]*?\\end\{table\*?\})", re.DOTALL)

    def repl(m: re.Match) -> str:
        block = m.group(1)
        # Extract caption (balanced)
        cidx = block.find("\\caption{")
        if cidx == -1:
            return block
        j = cidx + len("\\caption{")
        depth = 1
        while j < len(block) and depth > 0:
            if block[j] == "{":
                depth += 1
            elif block[j] == "}":
                depth -= 1
            j += 1
        caption = block[cidx + len("\\caption{") : j - 1].strip()

        # Extract label (simple)
        lm = re.search(r"\\label\{(tab:[^}]+)\}", block)
        label = lm.group(1) if lm else None

        # Remove caption and label commands from block (best-effort)
        block_wo = block
        block_wo = remove_braced_command(block_wo, "caption")
        if label:
            block_wo = re.sub(rf"\\label\{{{re.escape(label)}\}}\s*", "", block_wo)

        # Insert explicit caption paragraph before first tabular
        ins = f"\\noindent\\textit{{{caption}}}\\par\n"
        tpos = block_wo.find("\\begin{tabular}")
        if tpos != -1:
            block_wo = block_wo[:tpos] + ins + block_wo[tpos:]
        else:
            block_wo = ins + block_wo
        return block_wo

    return table_pat.sub(repl, tex)

def postprocess_docx_ieee(docx_path: Path, author_lines: list[str] | None = None) -> None:
    """
    Make the DOCX visually closer to IEEE two-column PDF:
    - Two columns in the last section (w:cols)
    - Letter page size + reasonable margins
    - Default font Times New Roman, body 10pt, single spacing, compact paragraph spacing
    - Captions italic, 9pt
    - Headings black (remove theme accent color)
    """
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)

        with zipfile.ZipFile(docx_path, "r") as z:
            z.extractall(td_path)

        doc_xml_path = td_path / "word" / "document.xml"
        styles_xml_path = td_path / "word" / "styles.xml"
        numbering_xml_path = td_path / "word" / "numbering.xml"

        if doc_xml_path.exists():
            doc_xml = doc_xml_path.read_text("utf-8", errors="ignore")
            # Insert pgSz/pgMar/cols into the *final* sectPr if missing.
            def _sect_repl(m: re.Match) -> str:
                sect = m.group(0)
                insert = (
                    '<w:pgSz w:w="12240" w:h="15840"/>'
                    '<w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" '
                    'w:header="720" w:footer="720" w:gutter="0"/>'
                    '<w:cols w:num="2" w:space="360"/>'
                )
                if "<w:cols" in sect:
                    return sect
                # Put before footnotePr if present, else right after sectPr open.
                if "<w:footnotePr" in sect:
                    return sect.replace("<w:footnotePr", insert + "<w:footnotePr", 1)
                return sect.replace("<w:sectPr>", "<w:sectPr>" + insert, 1)

            doc_xml = re.sub(r"<w:sectPr>[\s\S]*?</w:sectPr>", _sect_repl, doc_xml, count=1)

            # Make front matter (Title/Author/Abstract/Keywords) single-column, then switch to 2-col at body.
            # We insert a continuous section break (1-col) at the Keywords paragraph (style FirstParagraph,
            # immediately before the first Heading1 "Introduction" paragraph).
            #
            # Word stores section breaks as a <w:sectPr> inside the paragraph properties of the last
            # paragraph in the previous section.
            ns_w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            try:
                import xml.etree.ElementTree as ET

                root = ET.fromstring(doc_xml)
                body = root.find(f"{{{ns_w}}}body")
                if body is not None:
                    paras = [p for p in body.findall(f"{{{ns_w}}}p")]

                    def _p_style(p):
                        pPr = p.find(f"{{{ns_w}}}pPr")
                        if pPr is None:
                            return None
                        ps = pPr.find(f"{{{ns_w}}}pStyle")
                        return ps.get(f"{{{ns_w}}}val") if ps is not None else None

                    def _p_text(p):
                        texts = []
                        for t in p.findall(f".//{{{ns_w}}}t"):
                            if t.text:
                                texts.append(t.text)
                        return "".join(texts).strip()

                    # Map style name <-> styleId from styles.xml (localized templates supported).
                    style_name_to_id: dict[str, str] = {}
                    style_id_to_name: dict[str, str] = {}
                    try:
                        if styles_xml_path.exists():
                            styles_bytes = styles_xml_path.read_bytes()
                            sroot = ET.fromstring(styles_bytes)
                            ns = {"w": ns_w}
                            for st in sroot.findall("w:style", ns):
                                sid = st.attrib.get(f"{{{ns_w}}}styleId")
                                name_el = st.find("w:name", ns)
                                name = name_el.attrib.get(f"{{{ns_w}}}val") if name_el is not None else None
                                if sid and name:
                                    style_name_to_id[name] = sid
                                    style_id_to_name[sid] = name
                    except Exception:
                        style_name_to_id = {}
                        style_id_to_name = {}

                    def _style_id(name: str, fallback: str) -> str:
                        # Case-insensitive match
                        for k, v in style_name_to_id.items():
                            if k.strip().lower() == name.strip().lower():
                                return v
                        return fallback

                    def _heading1_style_ids() -> set[str]:
                        out: set[str] = set()
                        for sid, name in style_id_to_name.items():
                            if name.strip().lower() == "heading 1":
                                out.add(sid)
                        # Common Word default id in some templates
                        out.add("Heading1")
                        return out

                    def _ensure_pPr(p):
                        pPr = p.find(f"{{{ns_w}}}pPr")
                        if pPr is None:
                            pPr = ET.Element(f"{{{ns_w}}}pPr")
                            p.insert(0, pPr)
                        return pPr

                    def _set_p_style(p, style_id: str) -> None:
                        pPr = _ensure_pPr(p)
                        ps = pPr.find(f"{{{ns_w}}}pStyle")
                        if ps is None:
                            ps = ET.SubElement(pPr, f"{{{ns_w}}}pStyle")
                        ps.set(f"{{{ns_w}}}val", style_id)

                    def _apply_num(p, num_id: str, ilvl: str) -> None:
                        pPr = _ensure_pPr(p)
                        numPr = pPr.find(f"{{{ns_w}}}numPr")
                        if numPr is None:
                            numPr = ET.SubElement(pPr, f"{{{ns_w}}}numPr")
                        il = numPr.find(f"{{{ns_w}}}ilvl")
                        if il is None:
                            il = ET.SubElement(numPr, f"{{{ns_w}}}ilvl")
                        il.set(f"{{{ns_w}}}val", ilvl)
                        nid = numPr.find(f"{{{ns_w}}}numId")
                        if nid is None:
                            nid = ET.SubElement(numPr, f"{{{ns_w}}}numId")
                        nid.set(f"{{{ns_w}}}val", num_id)

                    intro_idx = None
                    heading1_ids = _heading1_style_ids()
                    for i, p in enumerate(paras):
                        if (_p_style(p) in heading1_ids) and _p_text(p).strip().lower() == "introduction":
                            intro_idx = i
                            break

                    if intro_idx is not None and intro_idx > 0:
                        # The paragraph immediately before Introduction is where we put the sectPr.
                        kw_p = paras[intro_idx - 1]
                        kw_pPr = kw_p.find(f"{{{ns_w}}}pPr")
                        if kw_pPr is None:
                            kw_pPr = ET.Element(f"{{{ns_w}}}pPr")
                            kw_p.insert(0, kw_pPr)

                        # Avoid adding multiple times.
                        existing = kw_pPr.find(f"{{{ns_w}}}sectPr")
                        if existing is None:
                            sectPr = ET.SubElement(kw_pPr, f"{{{ns_w}}}sectPr")
                            ET.SubElement(sectPr, f"{{{ns_w}}}type").set(f"{{{ns_w}}}val", "continuous")
                            ET.SubElement(sectPr, f"{{{ns_w}}}pgSz").set(f"{{{ns_w}}}w", "12240")
                            sectPr.find(f"{{{ns_w}}}pgSz").set(f"{{{ns_w}}}h", "15840")
                            mar = ET.SubElement(sectPr, f"{{{ns_w}}}pgMar")
                            mar.set(f"{{{ns_w}}}top", "1080")
                            mar.set(f"{{{ns_w}}}right", "1080")
                            mar.set(f"{{{ns_w}}}bottom", "1080")
                            mar.set(f"{{{ns_w}}}left", "1080")
                            mar.set(f"{{{ns_w}}}header", "720")
                            mar.set(f"{{{ns_w}}}footer", "720")
                            mar.set(f"{{{ns_w}}}gutter", "0")
                            cols = ET.SubElement(sectPr, f"{{{ns_w}}}cols")
                            cols.set(f"{{{ns_w}}}num", "1")
                            cols.set(f"{{{ns_w}}}space", "360")

                    def _prepend_paragraph_text(p, prefix: str) -> None:
                        t = p.find(f".//{{{ns_w}}}t")
                        if t is not None:
                            t.text = prefix + (t.text or "")
                            return
                        r = p.find(f"{{{ns_w}}}r")
                        if r is None:
                            r = ET.SubElement(p, f"{{{ns_w}}}r")
                        t = ET.SubElement(r, f"{{{ns_w}}}t")
                        t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
                        t.text = prefix

                    # Figures are already prefixed in LaTeX as "Fig. N." (env-scoped),
                    # so we MUST NOT auto-prefix again here (it would create "Fig. 1. Fig. 1. ...").

                    # Insert IEEE-like author block lines (affiliation/email) right after the first Author paragraph.
                    if author_lines:
                        for i, p in enumerate(paras):
                            if _p_style(p) == "Author":
                                insert_at = i + 1
                                for line in author_lines:
                                    line = line.strip()
                                    if not line:
                                        continue
                                    np = ET.Element(f"{{{ns_w}}}p")
                                    pPr = ET.SubElement(np, f"{{{ns_w}}}pPr")
                                    ET.SubElement(pPr, f"{{{ns_w}}}pStyle").set(f"{{{ns_w}}}val", "Author")
                                    r = ET.SubElement(np, f"{{{ns_w}}}r")
                                    t = ET.SubElement(r, f"{{{ns_w}}}t")
                                    t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
                                    t.text = line
                                    body.insert(insert_at, np)
                                    insert_at += 1
                                break

                    # Reformat Abstract/Keywords to IEEE-style labels and remove the centered AbstractTitle line.
                    # AbstractTitle paragraph (style AbstractTitle) is removed; Abstract paragraph is prefixed with "Abstract—".
                    def _prepend_label(paragraph, label_text: str, bold: bool = False, italic: bool = False):
                        # Create a new run at the beginning.
                        r = ET.Element(f"{{{ns_w}}}r")
                        rPr = ET.SubElement(r, f"{{{ns_w}}}rPr")
                        if bold:
                            ET.SubElement(rPr, f"{{{ns_w}}}b")
                        if italic:
                            ET.SubElement(rPr, f"{{{ns_w}}}i")
                        t = ET.SubElement(r, f"{{{ns_w}}}t")
                        t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
                        t.text = label_text
                        paragraph.insert(0, r)

                    # Remove AbstractTitle
                    for p in list(paras):
                        if _p_style(p) == "AbstractTitle":
                            body.remove(p)
                            break

                    # Prefix Abstract
                    for p in paras:
                        if _p_style(p) == "Abstract":
                            _prepend_label(p, "Abstract— ", bold=True, italic=False)
                            break

                    # Prefix Keywords: treat the FirstParagraph immediately after Abstract as keywords.
                    # Set its style to IndexTerms (we will define this style in styles.xml).
                    for i, p in enumerate(paras):
                        if _p_style(p) == "Abstract":
                            if i + 1 < len(paras):
                                kw = paras[i + 1]
                                _prepend_label(kw, "Index Terms— ", bold=False, italic=True)
                                _set_p_style(kw, "IndexTerms")
                            break

                    # Enforce IEEE Transactions/Journals template caption styles (localized templates supported):
                    # - Table captions: "TABLE X." paragraphs -> "Table Title" (TRANS-JOUR) or "Table Caption"
                    # - Figure captions: "Fig. X." paragraphs -> "Figure Caption" (TRANS-JOUR) or "Image Caption"
                    table_caption_style = _style_id("Table Title", _style_id("Table Caption", "Caption"))
                    fig_caption_style = _style_id("Figure Caption", _style_id("Image Caption", "Caption"))
                    for p in paras:
                        txt = _p_text(p)
                        if not txt:
                            continue
                        if txt.startswith("TABLE ") or txt.startswith("Table "):
                            _set_p_style(p, table_caption_style)
                        elif txt.startswith("Fig. "):
                            _set_p_style(p, fig_caption_style)

                    # References styling: apply the template's "References" style to bibliography entries.
                    # Detect the REFERENCES heading then style subsequent paragraphs until the next Heading 1.
                    refs_style = _style_id("References", "BodyText")
                    in_refs = False
                    for p in paras:
                        t = _p_text(p)
                        st = _p_style(p)
                        if (st in heading1_ids) and t.strip().lower() in {"references", "reference"}:
                            in_refs = True
                            continue
                        if in_refs and (st in heading1_ids):
                            in_refs = False
                        if in_refs:
                            # don't touch empty lines
                            if t.strip():
                                _set_p_style(p, refs_style)

                    # Apply IEEE-like multi-level heading numbering (Roman for sections, A/B/C for subsections).
                    # Important: do NOT number unnumbered sections (REFERENCES/Acknowledgment/etc.).
                    heading_num_id = "2001"
                    unnumbered = {
                        "REFERENCES",
                        "Acknowledgment",
                        "ACKNOWLEDGMENT",
                        "Data and Artifact Availability",
                        "Conflict of Interest",
                        "APPENDIX",
                    }
                    for p in paras:
                        st = _p_style(p)
                        if st not in ("Heading1", "Heading2", "Heading3"):
                            continue
                        txt = _p_text(p)
                        if not txt:
                            continue
                        if txt.strip() in unnumbered:
                            continue
                        # Skip already-numbered headings (e.g., "I. INTRODUCTION")
                        if re.match(r"^\s*[IVXLCDM]+\.\s+", txt):
                            continue
                        if re.match(r"^\s*[A-Z]\.\s+", txt) and st != "Heading1":
                            continue

                        if st == "Heading1":
                            _apply_num(p, heading_num_id, "0")
                        elif st == "Heading2":
                            _apply_num(p, heading_num_id, "1")
                        else:
                            _apply_num(p, heading_num_id, "2")

                    # Convert "TABLE ..." caption paragraphs into Word field-based captions so they are editable
                    # and can be auto-renumbered by Word/production.
                    #
                    # Input (from pandoc): a paragraph whose visible text begins with "TABLE II. ..."
                    # Output: "TABLE " + SEQ Table \\* ROMAN + ". " + caption rest
                    def _clear_runs_keep_ppr(paragraph):
                        for child in list(paragraph):
                            if child.tag != f"{{{ns_w}}}pPr":
                                paragraph.remove(child)

                    def _append_text_run(paragraph, text: str):
                        r = ET.SubElement(paragraph, f"{{{ns_w}}}r")
                        t = ET.SubElement(r, f"{{{ns_w}}}t")
                        t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
                        t.text = text

                    def _append_seq_field(paragraph, seq_name: str, switches: str, placeholder: str = "I"):
                        fld = ET.SubElement(paragraph, f"{{{ns_w}}}fldSimple")
                        fld.set(f"{{{ns_w}}}instr", f" SEQ {seq_name} {switches} ")
                        r = ET.SubElement(fld, f"{{{ns_w}}}r")
                        t = ET.SubElement(r, f"{{{ns_w}}}t")
                        t.text = placeholder

                    for p in paras:
                        txt = _p_text(p)
                        m = re.match(r"^\\s*TABLE\\s+[IVXLCDM]+\\.\\s*(.*)$", txt)
                        if not m:
                            continue
                        rest = m.group(1).strip()
                        _set_p_style(p, "Caption")
                        _clear_runs_keep_ppr(p)
                        _append_text_run(p, "TABLE ")
                        _append_seq_field(p, "Table", "\\\\* ROMAN", "I")
                        _append_text_run(p, ". " + rest)

                    doc_xml = ET.tostring(root, encoding="utf-8", xml_declaration=False).decode("utf-8")
            except Exception:
                # If XML manipulation fails, keep the doc_xml as-is (best-effort).
                pass

            doc_xml_path.write_text(doc_xml, "utf-8")

        if styles_xml_path.exists():
            styles = styles_xml_path.read_text("utf-8", errors="ignore")

            # docDefaults: Times New Roman 10pt, single spacing, no extra after-spacing
            styles = re.sub(
                r"(<w:docDefaults>[\s\S]*?<w:rPrDefault>[\s\S]*?<w:rPr>)[\s\S]*?(</w:rPr>[\s\S]*?</w:rPrDefault>)",
                r"\1"
                r'<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>'
                r'<w:sz w:val="20"/><w:szCs w:val="20"/>'
                r'<w:lang w:val="en-US"/>'
                r"\2",
                styles,
                count=1,
            )
            styles = re.sub(
                r"(<w:pPrDefault>[\s\S]*?<w:pPr>)[\s\S]*?(</w:pPr>[\s\S]*?</w:pPrDefault>)",
                r'\1<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>\2',
                styles,
                count=1,
            )

            # BodyText spacing: compact and single-spaced
            styles = re.sub(
                r"(<w:style[^>]*w:styleId=\"BodyText\"[\s\S]*?<w:pPr>)[\s\S]*?(</w:pPr>)",
                r'\1<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>\2',
                styles,
                count=1,
            )

            # Caption: italic, 9pt, compact spacing
            def _caption_repl(m: re.Match) -> str:
                block = m.group(0)
                # spacing
                block = re.sub(
                    r"<w:spacing[^>]*/>",
                    '<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>',
                    block,
                )
                # ensure rPr has Times + 8pt (closer to IEEE figure/table captions)
                if "<w:rPr>" in block:
                    block = block.replace(
                        "<w:rPr>",
                        '<w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>'
                        '<w:sz w:val="16"/><w:szCs w:val="16"/>',
                        1,
                    )
                return block

            styles = re.sub(
                r"<w:style[^>]*w:styleId=\"Caption\"[\s\S]*?</w:style>",
                _caption_repl,
                styles,
                count=1,
            )

            def _patch_style(styles_xml: str, style_id: str, patch_fn) -> str:
                m = re.search(
                    rf"(<w:style[^>]*w:styleId=\"{re.escape(style_id)}\".*?</w:style>)",
                    styles_xml,
                    flags=re.DOTALL,
                )
                if not m:
                    return styles_xml
                old = m.group(1)
                new = patch_fn(old)
                return styles_xml.replace(old, new, 1)

            # Title: closer to IEEE (24pt Times, bold)
            def _title_patch(block: str) -> str:
                block = re.sub(
                    r"<w:rFonts[^>]*/>",
                    '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>',
                    block,
                )
                block = re.sub(r"<w:sz\s+[^>]*w:val=\"\d+\"[^>]*/>", "<w:sz w:val=\"48\"/>", block)
                block = re.sub(r"<w:szCs\s+[^>]*w:val=\"\d+\"[^>]*/>", "<w:szCs w:val=\"48\"/>", block)
                if "<w:b" not in block:
                    block = block.replace("<w:rPr>", "<w:rPr><w:b/>", 1)
                return block

            styles = _patch_style(styles, "Title", _title_patch)

            # Author: 11pt Times, centered, not inheriting Title size.
            def _author_patch(block: str) -> str:
                block = re.sub(r"<w:basedOn\s+w:val=\"[^\"]+\"\s*/>", "<w:basedOn w:val=\"Normal\"/>", block)
                block = re.sub(r"<w:sz\s+[^>]*w:val=\"\d+\"[^>]*/>", "<w:sz w:val=\"22\"/>", block)
                block = re.sub(r"<w:szCs\s+[^>]*w:val=\"\d+\"[^>]*/>", "<w:szCs w:val=\"22\"/>", block)
                block = re.sub(
                    r"<w:rFonts[^>]*/>",
                    '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>',
                    block,
                )
                # Ensure author isn't bold (some templates inherit from Title).
                block = re.sub(r"<w:b[^>]*/>", "", block)
                if "<w:rFonts" not in block:
                    block = block.replace(
                        "<w:rPr>",
                        '<w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>',
                        1,
                    )
                if "<w:jc" not in block:
                    block = block.replace("<w:pPr>", "<w:pPr><w:jc w:val=\"center\"/>", 1)
                # Compact spacing for author block lines
                if "<w:spacing" not in block:
                    block = block.replace("<w:pPr>", '<w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>', 1)
                return block

            styles = _patch_style(styles, "Author", _author_patch)

            # Abstract: 9pt Times, single spaced, no extra before/after.
            def _abstract_repl(m: re.Match) -> str:
                block = m.group(0)
                block = re.sub(r"<w:sz w:val=\"\\d+\"\\s*/>", "<w:sz w:val=\"18\"/>", block)
                block = re.sub(r"<w:szCs w:val=\"\\d+\"\\s*/>", "<w:szCs w:val=\"18\"/>", block)
                # spacing to 0
                block = re.sub(r"<w:spacing[^>]*/>", '<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>', block)
                if "<w:rFonts" not in block:
                    block = block.replace("<w:rPr>", '<w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>', 1)
                return block

            styles = re.sub(
                r"<w:style[^>]*w:styleId=\"Abstract\"[\s\S]*?</w:style>",
                _abstract_repl,
                styles,
                count=1,
            )

            # Headings: force Times New Roman and black (remove theme accent color)
            def _heading_repl(m: re.Match) -> str:
                block = m.group(0)
                block = re.sub(r"<w:color[^>]*/>", "", block)
                if "<w:rPr>" in block:
                    block = block.replace(
                        "<w:rPr>",
                        "<w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:cs=\"Times New Roman\" w:eastAsia=\"Times New Roman\"/>",
                        1,
                    )
                return block

            for hid in ["Heading1", "Heading2", "Heading3", "Heading4", "Heading5", "Heading6"]:
                styles = re.sub(
                    rf"<w:style[^>]*w:styleId=\"{hid}\"[\s\S]*?</w:style>",
                    _heading_repl,
                    styles,
                    count=1,
                )

            # Tighten heading sizes/spacings closer to IEEE Transactions Word template.
            def _heading_size_patch(block: str, size_val: str, italic: bool = False, small_caps: bool = False) -> str:
                # size (half-points)
                block = re.sub(r"<w:sz\s+[^>]*w:val=\"\d+\"[^>]*/>", f"<w:sz w:val=\"{size_val}\"/>", block)
                block = re.sub(r"<w:szCs\s+[^>]*w:val=\"\d+\"[^>]*/>", f"<w:szCs w:val=\"{size_val}\"/>", block)
                # ensure rPr exists
                if "<w:rPr>" in block and "<w:sz" not in block:
                    block = block.replace("<w:rPr>", f"<w:rPr><w:sz w:val=\"{size_val}\"/><w:szCs w:val=\"{size_val}\"/>", 1)
                # italic / small caps toggles
                if italic and "<w:i" not in block:
                    block = block.replace("<w:rPr>", "<w:rPr><w:i/>", 1)
                if (not italic):
                    block = re.sub(r"<w:i[^>]*/>", "", block)
                if small_caps and "<w:smallCaps" not in block:
                    block = block.replace("<w:rPr>", "<w:rPr><w:smallCaps/>", 1)
                # spacing: modest before, none after
                if "<w:pPr>" in block and "<w:spacing" not in block:
                    block = block.replace("<w:pPr>", '<w:pPr><w:spacing w:before="120" w:after="0" w:line="240" w:lineRule="auto"/>', 1)
                return block

            styles = _patch_style(styles, "Heading1", lambda b: _heading_size_patch(b, "20", italic=False, small_caps=True))
            styles = _patch_style(styles, "Heading2", lambda b: _heading_size_patch(b, "20", italic=True, small_caps=False))
            styles = _patch_style(styles, "Heading3", lambda b: _heading_size_patch(b, "20", italic=False, small_caps=False))

            # Add a dedicated IndexTerms style if missing; base on BodyText but slightly smaller like Abstract.
            if "w:styleId=\"IndexTerms\"" not in styles:
                idx_style = (
                    '<w:style w:type="paragraph" w:styleId="IndexTerms">'
                    '<w:name w:val="Index Terms"/>'
                    '<w:basedOn w:val="BodyText"/>'
                    '<w:qFormat/>'
                    '<w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>'
                    '<w:rPr>'
                    '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman" w:eastAsia="Times New Roman"/>'
                    '<w:sz w:val="18"/><w:szCs w:val="18"/>'
                    '</w:rPr>'
                    "</w:style>"
                )
                styles = styles.replace("</w:styles>", idx_style + "</w:styles>", 1)

            styles_xml_path.write_text(styles, "utf-8")

        # Inject a dedicated heading numbering definition (Roman / Letters / Decimal).
        if numbering_xml_path.exists():
            try:
                import xml.etree.ElementTree as ET

                ns_w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                root = ET.parse(numbering_xml_path).getroot()

                # Avoid duplicating if we already injected.
                if root.find(f".//{{{ns_w}}}num[@{{{ns_w}}}numId='2001']") is None:
                    abstract_id = "20001"
                    num_id = "2001"

                    absnum = ET.Element(f"{{{ns_w}}}abstractNum")
                    absnum.set(f"{{{ns_w}}}abstractNumId", abstract_id)
                    ET.SubElement(absnum, f"{{{ns_w}}}multiLevelType").set(f"{{{ns_w}}}val", "multilevel")

                    # Level 0: I.
                    lvl0 = ET.SubElement(absnum, f"{{{ns_w}}}lvl")
                    lvl0.set(f"{{{ns_w}}}ilvl", "0")
                    ET.SubElement(lvl0, f"{{{ns_w}}}start").set(f"{{{ns_w}}}val", "1")
                    ET.SubElement(lvl0, f"{{{ns_w}}}numFmt").set(f"{{{ns_w}}}val", "upperRoman")
                    ET.SubElement(lvl0, f"{{{ns_w}}}lvlText").set(f"{{{ns_w}}}val", "%1.")
                    ET.SubElement(lvl0, f"{{{ns_w}}}lvlJc").set(f"{{{ns_w}}}val", "left")
                    ppr0 = ET.SubElement(lvl0, f"{{{ns_w}}}pPr")
                    ET.SubElement(ppr0, f"{{{ns_w}}}ind").set(f"{{{ns_w}}}left", "0")

                    # Level 1: A.
                    lvl1 = ET.SubElement(absnum, f"{{{ns_w}}}lvl")
                    lvl1.set(f"{{{ns_w}}}ilvl", "1")
                    ET.SubElement(lvl1, f"{{{ns_w}}}start").set(f"{{{ns_w}}}val", "1")
                    ET.SubElement(lvl1, f"{{{ns_w}}}numFmt").set(f"{{{ns_w}}}val", "upperLetter")
                    ET.SubElement(lvl1, f"{{{ns_w}}}lvlText").set(f"{{{ns_w}}}val", "%2.")
                    ET.SubElement(lvl1, f"{{{ns_w}}}lvlJc").set(f"{{{ns_w}}}val", "left")
                    ppr1 = ET.SubElement(lvl1, f"{{{ns_w}}}pPr")
                    ET.SubElement(ppr1, f"{{{ns_w}}}ind").set(f"{{{ns_w}}}left", "0")

                    # Level 2: 1)
                    lvl2 = ET.SubElement(absnum, f"{{{ns_w}}}lvl")
                    lvl2.set(f"{{{ns_w}}}ilvl", "2")
                    ET.SubElement(lvl2, f"{{{ns_w}}}start").set(f"{{{ns_w}}}val", "1")
                    ET.SubElement(lvl2, f"{{{ns_w}}}numFmt").set(f"{{{ns_w}}}val", "decimal")
                    ET.SubElement(lvl2, f"{{{ns_w}}}lvlText").set(f"{{{ns_w}}}val", "%3.")
                    ET.SubElement(lvl2, f"{{{ns_w}}}lvlJc").set(f"{{{ns_w}}}val", "left")
                    ppr2 = ET.SubElement(lvl2, f"{{{ns_w}}}pPr")
                    ET.SubElement(ppr2, f"{{{ns_w}}}ind").set(f"{{{ns_w}}}left", "0")

                    root.append(absnum)

                    num = ET.Element(f"{{{ns_w}}}num")
                    num.set(f"{{{ns_w}}}numId", num_id)
                    ET.SubElement(num, f"{{{ns_w}}}abstractNumId").set(f"{{{ns_w}}}val", abstract_id)
                    root.append(num)

                    numbering_xml_path.write_text(ET.tostring(root, encoding="utf-8", xml_declaration=True).decode("utf-8"), "utf-8")
            except Exception:
                pass

        # Repack DOCX
        tmp_out = docx_path.with_suffix(".tmp.docx")
        with zipfile.ZipFile(tmp_out, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for fp in td_path.rglob("*"):
                if fp.is_file():
                    z.write(fp, fp.relative_to(td_path).as_posix())
        tmp_out.replace(docx_path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs-dir", required=True, help="Docs directory containing .tex/.aux and figures/")
    ap.add_argument("--tex", default="IEEE_Paper_SkyBridge_Compass_patched.tex", help="Main LaTeX file name")
    ap.add_argument("--aux", default="IEEE_Paper_SkyBridge_Compass_patched.aux", help="Main AUX file name")
    ap.add_argument("--supp-aux", default="supplementary.aux", help="Supplementary AUX file name (optional)")
    ap.add_argument("--out-docx", default="IEEE_Paper_SkyBridge_Compass_patched.docx", help="Output DOCX file name")
    ap.add_argument("--backup-existing", action="store_true", help="Backup existing output docx with timestamp suffix")
    ap.add_argument(
        "--reference-doc",
        default=None,
        help=(
            "Reference DOCX (Word template) to control styles. "
            "If omitted, the exporter auto-selects trans_jour.docx (IEEE Transactions / TDSC recommended) "
            "when present under the docs dir, otherwise falls back to _pandoc_reference.docx."
        ),
    )
    ap.add_argument("--figure-dpi", type=int, default=450, help="Rasterization DPI for figures (recommended 300–600)")
    ap.add_argument(
        "--rasterize-tables",
        action="store_true",
        help="Rasterize LaTeX tables into images (NOT suitable for IEEE TDSC; use only as last-resort preview).",
    )
    args = ap.parse_args()

    docs = Path(args.docs_dir).expanduser().resolve()
    # Auto-select the TDSC/IEEE Transactions Word template if present.
    # This keeps the exported DOCX visually aligned with the TDSC/IEEEtran PDF.
    reference_doc = args.reference_doc
    if reference_doc is None:
        if (docs / "trans_jour.docx").exists():
            reference_doc = "trans_jour.docx"
        else:
            reference_doc = "_pandoc_reference.docx"

    tex_path = docs / args.tex
    aux_path = docs / args.aux
    supp_aux_path = docs / args.supp_aux
    figures_dir = docs / "figures"
    docx_fig_dir = docs / "_docx_figs"

    if not tex_path.exists():
        raise FileNotFoundError(tex_path)
    if not aux_path.exists():
        raise FileNotFoundError(aux_path)
    if not figures_dir.exists():
        raise FileNotFoundError(figures_dir)

    ref_map, cite_map = parse_aux(aux_path)
    if supp_aux_path.exists():
        supp_ref_map, _ = parse_aux(supp_aux_path)
        ref_map = merge_maps(ref_map, supp_ref_map)

    src = tex_path.read_text(encoding="utf-8", errors="ignore")

    # Extract author affiliation/email lines from supplementary.tex (clean, simple author block).
    author_lines: list[str] = []
    try:
        supp_tex = (docs / "supplementary.tex").read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"\\author\{([\s\S]*?)\}", supp_tex)
        if m:
            raw = m.group(1)
            parts = [p.strip() for p in raw.split("\\\\") if p.strip()]
            # Skip first part if it's just the author name (already present in DOCX).
            if parts:
                # Heuristic: first segment likely contains the name.
                parts = parts[1:]
            # Normalize common prefixes
            for p in parts:
                p = re.sub(r"\s+", " ", p).strip()
                author_lines.append(p)
    except Exception:
        author_lines = []

    # Expand \input{...} to avoid losing tables/figures during conversion.
    src = expand_inputs(src, docs)
    src = normalize_tex_for_word(src)

    # 0) Remove PDF text-extraction helpers that pandoc doesn't load.
    # They matter for PDF, not for DOCX, and can cause include-file warnings.
    src = re.sub(r"^\\input\{glyphtounicode\}\s*$", "", src, flags=re.MULTILINE)
    src = re.sub(r"^\\pdfgentounicode=1\s*$", "", src, flags=re.MULTILINE)

    # 0b) Strip IEEEtran wrappers that rely on brace-scoped arguments.
    # Pandoc's LaTeX reader is easily derailed by these wrappers even if LaTeX itself can handle them.
    # We keep the abstract/keywords contents but remove the wrapper macro call.
    src = src.replace("\\IEEEtitleabstractindextext{%", "")
    src = src.replace("\\IEEEtitleabstractindextext{", "")

    # 0c) Rasterize all figure PDFs with pdftocairo into a dedicated folder for DOCX embedding.
    # This makes Word figures visually closer to the final PDF rendering (consistent rasterizer).
    docx_fig_dir.mkdir(parents=True, exist_ok=True)
    for pdf in sorted(figures_dir.glob("*.pdf")):
        rasterize_pdf_to_png(pdf, docx_fig_dir / (pdf.stem + ".png"), args.figure_dpi)

    # TikZ-only figures: generate standalone PDFs and rasterize them as well (best-effort).
    # If extraction/build fails, fall back to existing PNGs.
    arch_pdf = docx_fig_dir / "fig_architecture.pdf"
    if build_standalone_tikz_pdf(docs, src, "fig:architecture", arch_pdf):
        rasterize_pdf_to_png(arch_pdf, docx_fig_dir / "fig_architecture.png", args.figure_dpi)
    elif (figures_dir / "fig_architecture.png").exists():
        shutil.copy2(figures_dir / "fig_architecture.png", docx_fig_dir / "fig_architecture.png")

    sm_pdf = docx_fig_dir / "fig_state_machines.pdf"
    if build_standalone_tikz_pdf(docs, src, "fig:state-machines", sm_pdf):
        rasterize_pdf_to_png(sm_pdf, docx_fig_dir / "fig_state_machines.png", args.figure_dpi)
    elif (figures_dir / "fig_state_machines_tikz.png").exists():
        shutil.copy2(figures_dir / "fig_state_machines_tikz.png", docx_fig_dir / "fig_state_machines.png")
    elif (figures_dir / "fig_state_machines.png").exists():
        shutil.copy2(figures_dir / "fig_state_machines.png", docx_fig_dir / "fig_state_machines.png")

    # 1) Swap PDF figures for PNG where available (DOCX embedding)
    # Prefer pdftocairo raster outputs in _docx_figs/ when possible.
    def _swap_fig_pdf(m: re.Match) -> str:
        path = m.group(1)
        if path.endswith(".pdf"):
            stem = Path(path).with_suffix("").name
            candidate = docx_fig_dir / f"{stem}.png"
            if candidate.exists():
                return "{_docx_figs/" + candidate.name + "}"
        # fallback: keep original path (pandoc may still resolve pngs next to it)
        return "{" + path + "}"

    src = re.sub(r"\{(figures/[^}]+)\}", _swap_fig_pdf, src)

    # 2) Replace TikZ figures with pre-rendered PNGs
    # Architecture figure (tikz) -> fig_architecture.png
    if (docx_fig_dir / "fig_architecture.png").exists():
        src = replace_tikz_figure(src, "fig:architecture", "_docx_figs/fig_architecture.png")
    # State machines figure (tikz) -> fig_state_machines_tikz.png (preferred) or fig_state_machines.png
    if (docx_fig_dir / "fig_state_machines.png").exists():
        src = replace_tikz_figure(src, "fig:state-machines", "_docx_figs/fig_state_machines.png")

    # 2b) Tables: IEEE TDSC requires editable Word tables (not images).
    # Pandoc's LaTeX reader is unreliable for complex IEEE tabular constructs.
    # Strategy:
    # - Prefix captions (TABLE X. / Fig. Y.) using LaTeX label numbers.
    # - Extract labeled tables into placeholders and store a cell-matrix per table label.
    # - Let pandoc convert the rest of the document.
    # - Post-process the produced DOCX to inject true w:tbl tables at placeholders.
    #
    # Rasterization remains available behind a flag for debugging only (NOT for submission).
    src = prefix_table_and_figure_captions_in_envs(src, ref_map)
    src, table_matrices = extract_labeled_tables_as_placeholders(src, ref_map=ref_map, cite_map=cite_map)
    if args.rasterize_tables:
        src = tables_to_images_for_word(
            src,
            docs=docs,
            ref_map=ref_map,
            cite_map=cite_map,
            dpi=args.figure_dpi,
            out_dir=docx_fig_dir,
        )
    # Best-effort simplification for any remaining (unlabeled) LaTeX tables.
    src = simplify_tables_for_pandoc(src)
    # Keep captions as explicit paragraphs (pandoc sometimes drops table captions).
    src = flatten_table_captions_for_pandoc(src)

    # 3) Resolve \ref/\cite to concrete numbers (stabilize evidence chain)
    src = expand_simple_macros(src)
    src = strip_latex_softbreaks(src)
    src = normalize_texttt_code_strings(src)
    src = unwrap_pandocbounded(src)
    src = replace_refs(src, ref_map)
    src = replace_cites(src, cite_map)

    # 3b) Rewrite bibliography to IEEE Word-friendly REFERENCES section with [n] items.
    src = rewrite_bibliography_for_word(src, cite_map)

    # 4) Reduce IEEEtran-only wrappers that confuse conversion
    src = src.replace("\\IEEEdisplaynontitleabstractindextext", "")
    # Exact wrapper used in this paper:
    src = src.replace(
        "\\IEEEraisesectionheading{\\section{Introduction}\\label{sec:introduction}}",
        "\\section{Introduction}\\label{sec:introduction}",
    )
    # IEEEtran sometimes leaves an extra closing brace after IEEEkeywords in Pandoc-generated LaTeX.
    src = src.replace("\\end{IEEEkeywords}}", "\\end{IEEEkeywords}")

    # Derived LaTeX input for docx conversion
    derived_tex = docs / "_docx_export.tex"
    derived_tex.write_text(src, encoding="utf-8")

    out_docx = docs / args.out_docx
    if args.backup_existing and out_docx.exists():
        ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
        backup = out_docx.with_name(out_docx.stem + f"_BACKUP_{ts}" + out_docx.suffix)
        shutil.copy2(out_docx, backup)

    # Reference DOCX controls Word styles. Prefer IEEE Journals template if provided.
    ref_docx = (docs / reference_doc) if not Path(reference_doc).is_absolute() else Path(reference_doc)
    if not ref_docx.exists():
        # Fallback: create a default reference docx if missing (best-effort).
        # pandoc prints the binary reference.docx to stdout; write to file.
        with open(ref_docx, "wb") as f:
            subprocess.run(["pandoc", "--print-default-data-file", "reference.docx"], cwd=str(docs), check=True, stdout=f)

    # Convert to DOCX
    run(
        [
            "pandoc",
            str(derived_tex.name),
            "-f",
            "latex",
            "-t",
            "docx",
            "-o",
            str(out_docx.name),
            "--resource-path",
            ".:figures:_docx_figs:tables:supp_tables",
            "--reference-doc",
            str(ref_docx.name if ref_docx.parent == docs else str(ref_docx)),
        ],
        cwd=docs,
    )

    # Inject real Word tables at placeholders (ensures editability for IEEE TDSC).
    # Prefer the reference template's "Normal Table" style (TRANS-JOUR), else fallback.
    try:
        with zipfile.ZipFile(ref_docx) as z:
            styles_bytes = z.read("word/styles.xml")
        table_style_id = (
            style_id_by_name_xml(styles_bytes, "Normal Table")
            or style_id_by_name_xml(styles_bytes, "Table")
            or None
        )
    except Exception:
        table_style_id = None
    inject_tables_into_docx(out_docx, table_matrices, table_style_id=table_style_id)

    # Make Word output visually closer to IEEE two-column look.
    postprocess_docx_ieee(out_docx, author_lines=author_lines)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())


