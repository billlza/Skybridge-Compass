# Final Pre-Submit Checklist (2026-02-17)

## A. Locked Baseline
- [x] Artifact date pinned: `ARTIFACT_DATE=2026-01-23`.
- [x] Main manuscript mirrors are identical:
  - `Docs/tdsc_submission/paper.tex`
  - `Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex`
  - `Docs/tdsc_submission/TDSC-2026-01-0318_paper.tex`

## B. Typography Polish (Deep pass completed on 2026-02-17)
- [x] High-risk overfull table issue fixed in supplementary cross-platform contract table.
- [x] Reproducibility sections rewritten for better line-breaking (shorter sentences + command/path wrapping).
- [x] Additional deep pass applied to main-paper hotspots (G5 proof sketch, claim-scope/external-validity section, kernel cross-check, and real-network micro-study).
- [x] Current log quality snapshot:
  - Main log: `LaTeX Warning = 0`, `Overfull \\hbox = 0`, `Underfull \\hbox = 24`
  - Supplementary log: `LaTeX Warning = 0`, `Overfull \\hbox = 0`, `Underfull \\hbox = 17`
- [x] Underfull vbox in supplementary removed (`Underfull \\vbox = 0`).

## C. Automated Gate Chain (Executed 2026-02-17)
- [x] Paper consistency gate
  - Command: `ARTIFACT_DATE=2026-01-23 bash Scripts/check_paper_consistency.sh`
  - Result: `Consistency check passed` (artifact tag/commit `817e11aa5806`).
- [x] Numeric consistency gate
  - Command: `ARTIFACT_DATE=2026-01-23 python3 Scripts/check_numeric_consistency.py`
  - Result: `Numeric consistency check passed`.
- [x] iOS minor-version matrix gate
  - Command: `ARTIFACT_DATE=2026-01-23 python3 Scripts/check_ios_minor_matrix.py --output Artifacts/ios_minor_matrix_2026-01-23.md`
  - Result: `passed (mode=pragmatic)`.
- [x] Top-tier gate (full chain, includes compile gate)
  - Command: `ARTIFACT_DATE=2026-01-23 bash Scripts/check_top_tier_gate.sh`
  - Result: `Top-tier gate completed successfully`.

## D. Build Outputs
- [x] Main PDF: `Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf`
- [x] Supplementary PDF: `Docs/TDSC-2026-01-0318_supplementary.pdf`
- [x] Latest archived build: `out/paper_20260217_181814.pdf`

## E. Final Manual Read-Through (completed 2026-02-17)
- [x] Read main PDF end-to-end (claims/limitations/cross-refs).
- [x] Read supplementary PDF end-to-end (commands, filenames, table captions).
- [x] Confirm title/abstract/keywords and author/affiliation block are final.
- [x] Confirm portal package contents match this exact build.
- [x] Submission package prepared and hash-verified:
  - `out/submission_package_20260217_1824/`
  - `out/submission_package_20260217_1824/SHA256SUMS.txt`

## F. One-Command Final Recheck (right before upload)
```bash
cd "/Users/bill/Desktop/SkyBridge Compass Pro release"
ARTIFACT_DATE=2026-01-23 bash Scripts/check_top_tier_gate.sh
```
