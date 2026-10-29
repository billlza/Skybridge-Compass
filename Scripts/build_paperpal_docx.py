#!/usr/bin/env python3
"""
Build a Paperpal-friendly DOCX with an IEEE-like layout.

Goal:
- Clean Word structure (no PDF-style textboxes), so AIGC detectors don't get confused.
- Keep figures (including TikZ ones) by rasterizing TikZ blocks to PNG.
- Apply a lightweight IEEE-ish layout: Letter page, Times New Roman 10pt, and 2 columns
  starting from "Introduction" (title/abstract stay single-column).

This script does NOT try to produce a pixel-perfect IEEE PDF clone in Word.
It optimizes for readable, structurally clean DOCX while remaining close to IEEE style.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from copy import deepcopy
from pathlib import Path
from typing import Optional
import xml.etree.ElementTree as ET


def _run(cmd: list[str], *, cwd: Optional[Path] = None) -> None:
    subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=True)


def _which_or_die(name: str, *, hint: Optional[str] = None) -> str:
    resolved = shutil.which(name)
    if resolved:
        return resolved
    message = f"Missing required command: {name}"
    if hint:
        message += f" ({hint})"
    raise RuntimeError(message)


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _extract_figure_block(tex: str, *, label: str) -> str:
    label_token = f"\\label{{{label}}}"
    label_idx = tex.find(label_token)
    if label_idx < 0:
        raise RuntimeError(f"Could not find label token: {label_token}")

    # Find the nearest preceding \begin{figure} / \begin{figure*}.
    begin_iter = list(re.finditer(r"\\begin\{figure\*?\}", tex[:label_idx]))
    if not begin_iter:
        raise RuntimeError(f"Could not find figure begin for label {label}")

    begin_match = begin_iter[-1]
    begin_token = begin_match.group(0)
    env_match = re.search(r"\\begin\{(figure\*?)\}", begin_token)
    if not env_match:
        raise RuntimeError(f"Could not parse figure env from token: {begin_token}")
    env = env_match.group(1)

    end_token = f"\\end{{{env}}}"
    end_idx = tex.find(end_token, label_idx)
    if end_idx < 0:
        raise RuntimeError(f"Could not find matching {end_token} for label {label}")

    end_idx_end = end_idx + len(end_token)
    return tex[begin_match.start() : end_idx_end]


def _extract_tikz_picture(block: str) -> str:
    m = re.search(r"(\\begin\{tikzpicture\}.*?\\end\{tikzpicture\})", block, flags=re.S)
    if not m:
        raise RuntimeError("Could not find tikzpicture in figure block")
    return m.group(1)

def _extract_all_tikz_pictures(block: str) -> list[str]:
    pics = re.findall(r"(\\begin\{tikzpicture\}.*?\\end\{tikzpicture\})", block, flags=re.S)
    if not pics:
        raise RuntimeError("Could not find tikzpicture blocks in figure block")
    return pics


def _extract_figure_body_before_caption(block: str) -> str:
    # Extract everything after \centering up to (but excluding) \caption{...}
    m = re.search(r"\\centering\s*(.*?)\\caption\s*\{", block, flags=re.S)
    if not m:
        raise RuntimeError("Could not locate figure body before caption")
    return m.group(1).strip()


def _render_tikz_to_png(
    *,
    tikz_body: str,
    out_png: Path,
    build_dir: Path,
    document_preamble: str,
) -> None:
    tex_name = out_png.with_suffix("").name + ".tex"
    pdf_name = out_png.with_suffix("").name + ".pdf"

    tex_path = build_dir / tex_name
    pdf_path = build_dir / pdf_name

    tex_doc = "\n".join(
        [
            r"\documentclass[tikz,border=2pt]{standalone}",
            r"\usepackage{graphicx}",
            r"\usepackage{tikz}",
            r"\usetikzlibrary{arrows.meta,positioning,shapes.geometric,calc}",
            document_preamble.rstrip(),
            r"\begin{document}",
            tikz_body.strip(),
            r"\end{document}",
            "",
        ]
    )

    _write_text(tex_path, tex_doc)

    pdflatex = _which_or_die("pdflatex", hint="Install MacTeX (pdflatex)")
    pdftocairo = _which_or_die("pdftocairo", hint="Install poppler (pdftocairo)")

    _run([pdflatex, "-interaction=nonstopmode", "-halt-on-error", tex_path.name], cwd=build_dir)

    out_base = out_png.with_suffix("")
    _run(
        [
            pdftocairo,
            "-png",
            "-r",
            "300",
            "-singlefile",
            pdf_path.name,
            str(out_base),
        ],
        cwd=build_dir,
    )

    if not out_png.exists():
        raise RuntimeError(f"Expected PNG not found: {out_png}")


def _preprocess_tex_for_pandoc(
    *,
    tex: str,
    architecture_png_rel: str,
    state_machine_initiator_png_rel: str,
    state_machine_responder_png_rel: str,
) -> str:
    # 1) Drop PDF unicode helpers (pandoc can't include local tex includes reliably).
    tex = re.sub(r"^\s*\\input\{glyphtounicode\}\s*$", r"% \\input{glyphtounicode} (disabled for docx)", tex, flags=re.M)
    tex = re.sub(r"^\s*\\pdfgentounicode=.*$", r"% \\pdfgentounicode (disabled for docx)", tex, flags=re.M)

    # 2) Unwrap IEEE's abstract/keywords wrapper (pandoc ignores unknown macro arguments).
    tex = tex.replace(r"\IEEEtitleabstractindextext{%", "")
    tex = tex.replace(r"\end{IEEEkeywords}}", r"\end{IEEEkeywords}")
    tex = re.sub(r"^\s*\\IEEEdisplaynontitleabstractindextext\s*$", "", tex, flags=re.M)

    # 3) Convert IEEEkeywords to a simple paragraph marker for Word.
    tex = tex.replace(r"\begin{abstract}", r"\noindent\textbf{Abstract—} ")
    tex = tex.replace(r"\end{abstract}", "\n")
    tex = tex.replace(r"\begin{IEEEkeywords}", r"\noindent\textbf{Index Terms—} ")
    tex = tex.replace(r"\end{IEEEkeywords}", "\n")

    # 4) Make Introduction visible as a normal section to pandoc.
    tex = re.sub(
        r"\\IEEEraisesectionheading\{\\section\{Introduction\}\\label\{([^}]+)\}\}",
        r"\\section{Introduction}\\label{\1}",
        tex,
    )

    # 5) Switch embedded PDF figures to PNG for pandoc (PDF figures are often dropped).
    tex = re.sub(r"(figures/fig_[^}]+)\.pdf(\})", r"\1.png\2", tex)

    # 6) Replace TikZ-only figures with rendered PNGs (keeps original diagram shapes).
    arch_block = _extract_figure_block(tex, label="fig:architecture")
    arch_cap = re.search(r"(\\caption\{.*?\}\s*\\label\{fig:architecture\})", arch_block, flags=re.S)
    if not arch_cap:
        raise RuntimeError("Could not extract architecture caption/label")
    arch_repl = "\n".join(
        [
            r"\begin{figure*}[!t]",
            r"\centering",
            rf"\pandocbounded{{\includegraphics[keepaspectratio,width=\textwidth]{{{architecture_png_rel}}}}}",
            arch_cap.group(1).strip(),
            r"\end{figure*}",
        ]
    )
    tex = tex.replace(arch_block, arch_repl)

    sm_block = _extract_figure_block(tex, label="fig:state-machines")
    sm_cap = re.search(r"(\\caption\{.*?\}\s*\\label\{fig:state-machines\})", sm_block, flags=re.S)
    if not sm_cap:
        raise RuntimeError("Could not extract state-machines caption/label")
    sm_repl = "\n".join(
        [
            r"\begin{figure}[!t]",
            r"\centering",
            rf"\pandocbounded{{\includegraphics[keepaspectratio,width=\columnwidth]{{{state_machine_initiator_png_rel}}}}}",
            r"\vspace{2mm}",
            rf"\pandocbounded{{\includegraphics[keepaspectratio,width=\columnwidth]{{{state_machine_responder_png_rel}}}}}",
            sm_cap.group(1).strip(),
            r"\end{figure}",
        ]
    )
    tex = tex.replace(sm_block, sm_repl)

    # 7) Normalize citations to numeric bracket form so pandoc doesn't drop them.
    def _cite_repl(match: re.Match[str]) -> str:
        raw = match.group(1)
        keys = [k.strip() for k in raw.split(",") if k.strip()]
        nums: list[str] = []
        for k in keys:
            m = re.fullmatch(r"ref(\d+)", k)
            if not m:
                nums.append(k)
            else:
                nums.append(m.group(1))
        if all(n.isdigit() for n in nums):
            return ", ".join(f"[{n}]" for n in nums)
        return f"[{', '.join(nums)}]"

    tex = re.sub(r"\\cite\{([^}]+)\}", _cite_repl, tex)

    # 8) Turn thebibliography into plain paragraphs with explicit labels.
    tex = re.sub(r"\\begin\{thebibliography\}\{[^}]*\}", r"\\section*{REFERENCES}", tex)
    tex = re.sub(r"\\end\{thebibliography\}", "", tex)
    tex = re.sub(r"\\bibitem\{ref(\d+)\}\s*", r"\n\\par\\noindent [\1] ", tex)

    return tex


def _patch_docx_ieeeish(docx_path: Path) -> None:
    W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    ns = {"w": W_NS}

    def qn(tag: str) -> str:
        return f"{{{W_NS}}}{tag}"

    # Prefer standard prefixes in output (some DOCX readers are picky).
    ET.register_namespace("w", W_NS)
    ET.register_namespace("r", "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
    ET.register_namespace("a", "http://schemas.openxmlformats.org/drawingml/2006/main")
    ET.register_namespace("wp", "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing")
    ET.register_namespace("pic", "http://schemas.openxmlformats.org/drawingml/2006/picture")
    ET.register_namespace("m", "http://schemas.openxmlformats.org/officeDocument/2006/math")

    with zipfile.ZipFile(docx_path, "r") as z:
        files = {name: z.read(name) for name in z.namelist()}

    if "word/document.xml" not in files or "word/styles.xml" not in files:
        raise RuntimeError("DOCX missing expected parts (word/document.xml, word/styles.xml)")

    doc_root = ET.fromstring(files["word/document.xml"])
    body = doc_root.find("w:body", ns)
    if body is None:
        raise RuntimeError("Invalid DOCX: missing w:body")

    # --- Section/layout: 2 columns from Introduction onward ---
    paragraphs = body.findall("w:p", ns)

    def para_text(p: ET.Element) -> str:
        return "".join((t.text or "") for t in p.findall(".//w:t", ns)).strip()

    intro_idx: Optional[int] = None
    for i, p in enumerate(paragraphs):
        if para_text(p).lower() == "introduction":
            intro_idx = i
            break

    end_sectpr = body.find("w:sectPr", ns)
    if end_sectpr is None:
        end_sectpr = ET.SubElement(body, qn("sectPr"))

    # Set page to Letter and reasonable margins.
    pgSz = end_sectpr.find("w:pgSz", ns)
    if pgSz is None:
        pgSz = ET.SubElement(end_sectpr, qn("pgSz"))
    pgSz.set(qn("w"), "12240")   # 8.5in * 1440
    pgSz.set(qn("h"), "15840")   # 11in * 1440

    pgMar = end_sectpr.find("w:pgMar", ns)
    if pgMar is None:
        pgMar = ET.SubElement(end_sectpr, qn("pgMar"))
    # 0.75in margins (approx IEEE look) => 1080 twips.
    for k in ("top", "bottom", "left", "right"):
        pgMar.set(qn(k), "1080")
    pgMar.set(qn("header"), "720")
    pgMar.set(qn("footer"), "720")
    pgMar.set(qn("gutter"), "0")

    cols = end_sectpr.find("w:cols", ns)
    if cols is None:
        cols = ET.SubElement(end_sectpr, qn("cols"))
    cols.set(qn("num"), "2")
    cols.set(qn("space"), "360")  # 0.25in column gap

    if intro_idx is not None and intro_idx > 0:
        # Insert a "continuous" section break BEFORE Introduction:
        # - Section 1 (title/abstract): single-column
        # - Section 2 (body): uses end_sectpr (2 columns)
        prev = paragraphs[intro_idx - 1]
        pPr = prev.find("w:pPr", ns)
        if pPr is None:
            pPr = ET.SubElement(prev, qn("pPr"))

        # Avoid adding multiple section breaks if script re-runs.
        existing = pPr.find("w:sectPr", ns)
        if existing is None:
            s1 = ET.SubElement(pPr, qn("sectPr"))
            t = ET.SubElement(s1, qn("type"))
            t.set(qn("val"), "continuous")

            # Copy page settings from end section for consistency (but keep 1 col).
            for child_tag in ("pgSz", "pgMar"):
                src = end_sectpr.find(f"w:{child_tag}", ns)
                if src is not None:
                    s1.append(deepcopy(src))
            c1 = ET.SubElement(s1, qn("cols"))
            c1.set(qn("num"), "1")

    # --- Styles: Times New Roman 10pt for Normal ---
    styles_root = ET.fromstring(files["word/styles.xml"])
    body_style_ids = {"Normal", "BodyText", "FirstParagraph", "Compact", "BlockText"}
    font_only_style_ids = {"Title", "Author", "Heading1", "Heading2", "ImageCaption", "TableCaption", "CaptionedFigure"}

    def ensure_fonts(style: ET.Element) -> ET.Element:
        rPr = style.find("w:rPr", ns)
        if rPr is None:
            rPr = ET.SubElement(style, qn("rPr"))
        rFonts = rPr.find("w:rFonts", ns)
        if rFonts is None:
            rFonts = ET.SubElement(rPr, qn("rFonts"))
        for attr in ("ascii", "hAnsi", "cs", "eastAsia"):
            rFonts.set(qn(attr), "Times New Roman")
        return rPr

    def set_body_defaults(style: ET.Element) -> None:
        rPr = ensure_fonts(style)

        sz = rPr.find("w:sz", ns)
        if sz is None:
            sz = ET.SubElement(rPr, qn("sz"))
        sz.set(qn("val"), "20")  # 10pt in half-points

        szCs = rPr.find("w:szCs", ns)
        if szCs is None:
            szCs = ET.SubElement(rPr, qn("szCs"))
        szCs.set(qn("val"), "20")

        pPr = style.find("w:pPr", ns)
        if pPr is None:
            pPr = ET.SubElement(style, qn("pPr"))

        jc = pPr.find("w:jc", ns)
        if jc is None:
            jc = ET.SubElement(pPr, qn("jc"))
        jc.set(qn("val"), "both")  # justify

        spacing = pPr.find("w:spacing", ns)
        if spacing is None:
            spacing = ET.SubElement(pPr, qn("spacing"))
        spacing.set(qn("before"), "0")
        spacing.set(qn("after"), "0")

    for st in styles_root.findall("w:style", ns):
        style_id = st.get(qn("styleId"))
        if not style_id:
            continue
        if style_id in body_style_ids:
            set_body_defaults(st)
        elif style_id in font_only_style_ids:
            ensure_fonts(st)

    # Write a new docx atomically.
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / docx_path.name
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for name, content in files.items():
                if name == "word/document.xml":
                    out = ET.tostring(doc_root, encoding="utf-8", xml_declaration=True)
                    z.writestr(name, out)
                elif name == "word/styles.xml":
                    out = ET.tostring(styles_root, encoding="utf-8", xml_declaration=True)
                    z.writestr(name, out)
                else:
                    z.writestr(name, content)
        shutil.move(str(tmp), str(docx_path))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repo root (defaults to Scripts/..).",
    )
    args = parser.parse_args()

    project_dir: Path = args.project_dir.resolve()
    docs_dir = project_dir / "Docs"
    figures_dir = project_dir / "figures"
    build_dir = project_dir / ".build" / "paperpal_docx"
    build_dir.mkdir(parents=True, exist_ok=True)

    src_tex = docs_dir / "TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
    if not src_tex.exists():
        raise RuntimeError(f"Source tex not found: {src_tex}")

    pandoc = shutil.which("pandoc") or "/opt/homebrew/bin/pandoc"
    if not Path(pandoc).exists():
        raise RuntimeError("pandoc not found (install pandoc or ensure it is on PATH)")

    tex = _read_text(src_tex)

    # Extract TikZ for architecture and state machines, render to PNG.
    arch_block = _extract_figure_block(tex, label="fig:architecture")
    arch_tikz = _extract_tikz_picture(arch_block)

    sm_block = _extract_figure_block(tex, label="fig:state-machines")
    sm_pics = _extract_all_tikz_pictures(sm_block)
    if len(sm_pics) < 2:
        raise RuntimeError("Expected two tikzpicture blocks for state machines figure")

    # Keep fonts consistent with paper (Times via mathptmx). Not required for graphics,
    # but helps match the PDF look for labels.
    preamble = r"\usepackage{mathptmx}"

    arch_png = figures_dir / "fig_architecture_tikz.png"
    sm_init_png = figures_dir / "fig_state_machine_initiator_tikz.png"
    sm_resp_png = figures_dir / "fig_state_machine_responder_tikz.png"

    _render_tikz_to_png(tikz_body=arch_tikz, out_png=arch_png, build_dir=build_dir, document_preamble=preamble)
    _render_tikz_to_png(tikz_body=sm_pics[0], out_png=sm_init_png, build_dir=build_dir, document_preamble=preamble)
    _render_tikz_to_png(tikz_body=sm_pics[1], out_png=sm_resp_png, build_dir=build_dir, document_preamble=preamble)

    # Create pandoc-friendly tex.
    pre_tex = _preprocess_tex_for_pandoc(
        tex=tex,
        architecture_png_rel="figures/fig_architecture_tikz.png",
        state_machine_initiator_png_rel="figures/fig_state_machine_initiator_tikz.png",
        state_machine_responder_png_rel="figures/fig_state_machine_responder_tikz.png",
    )
    pre_tex_path = build_dir / "paperpal_docx.tex"
    _write_text(pre_tex_path, pre_tex)

    # Run pandoc from Docs so relative table paths resolve (Docs/figures -> ../figures).
    tmp_docx = build_dir / "paperpal_raw.docx"
    _run(
        [
            pandoc,
            str(pre_tex_path),
            "-f",
            "latex",
            "-t",
            "docx",
            "-o",
            str(tmp_docx),
            "--resource-path",
            f"{docs_dir}:{project_dir}:{figures_dir}",
        ],
        cwd=docs_dir,
    )

    if not tmp_docx.exists():
        raise RuntimeError("pandoc did not produce a DOCX output")

    # Apply IEEE-ish Word layout tweaks.
    _patch_docx_ieeeish(tmp_docx)

    # Backup and write final docx to Docs/.
    out_docx = docs_dir / "IEEE_Paper_SkyBridge_Compass_patched.docx"
    backups = project_dir / ".build" / "docx_backups"
    backups.mkdir(parents=True, exist_ok=True)
    if out_docx.exists():
        shutil.copy2(out_docx, backups / f"{out_docx.stem}.pre_paperpal{out_docx.suffix}")
    shutil.copy2(tmp_docx, out_docx)

    print(f"Wrote: {out_docx}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
