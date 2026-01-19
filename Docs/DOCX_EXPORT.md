### DOCX export (version-aligned with the IEEE PDF)

This folder contains an automated exporter that regenerates a **clean Word `.docx`** from the **current LaTeX source** used to build the IEEE PDF, keeping:

- **Figure/Table numbers aligned** (resolved from `.aux`)
- **Cross-references aligned** (including Supplementary labels via `supplementary.aux`)
- **Figures embedded** (PDF/TikZ replaced with pre-rendered PNGs in `Docs/figures/`)
- **IEEE-like layout** in Word (two columns, Times New Roman, 10pt body text, compact spacing)

#### Prerequisites (macOS)

- `pandoc` (installed; check with `pandoc --version`)

#### Run

From the `Docs/` directory:

```bash
python3 export_docx.py --docs-dir "/Users/bill/Desktop/SkyBridge Compass Pro release/Docs" --backup-existing --figure-dpi 450
```

Outputs:

- `IEEE_Paper_SkyBridge_Compass_patched.docx` (overwritten)
- A timestamped backup: `IEEE_Paper_SkyBridge_Compass_patched_BACKUP_YYYYMMDD_HHMMSS.docx`

#### Notes

- The exporter intentionally strips IEEEtran wrapper macros that Word doesn’t need (e.g., `\IEEEtitleabstractindextext`).
- If you add new TikZ figures, pre-render a PNG into `Docs/figures/` and the exporter can be extended similarly.


