# Final Pre-Submit Checklist (2026-02-16)

## A. Locked Artifact Baseline
- [x] `ARTIFACT_DATE` fixed to `2026-01-23` for all paper-facing outputs.
- [x] Real-network aggregation regenerated:
  - `Artifacts/realnet_microstudy_2026-01-23.csv`
  - `Docs/supp_tables/s9_realnet_microstudy.tex`
- [x] Real-network rows now include:
  - `wifi_direct` (non-overlay, EC2 direct on TCP 443)
  - `ec2_ssh_tunnel` (overlay-mediated)
  - `hotspot_ssh_tunnel` (overlay-mediated)
- [x] Kernel-emulation artifact present:
  - `Artifacts/network_emulation_kernel_2026-01-23.csv`
  - `Docs/supp_tables/s10_kernel_emulation.tex`
- [x] iOS minor-version matrix gate passed:
  - `Artifacts/ios_minor_matrix_2026-01-23.md`

## B. Paper Consistency and Build
- [x] Main text updated to match current real-network evidence:
  - `Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex`
- [x] Tables/figures regenerated:
  - `python3 Scripts/make_tables.py`
  - `python3 Scripts/generate_ieee_figures.py`
- [x] PDFs regenerated:
  - `Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf`
  - `Docs/TDSC-2026-01-0318_supplementary.pdf`
- [x] Top-tier gate passed:
  - `ARTIFACT_DATE=2026-01-23 bash Scripts/check_top_tier_gate.sh`

## C. Environment Cleanup
- [x] Remote temporary E2E listeners cleaned (EC2):
  - no listeners on `443/44444/8443/9443/5001`.
- [x] Local system proxies disabled for measurement integrity (manual confirmed during run).

## D. Manual Final Review Before Submission
- [ ] Read final main PDF once end-to-end (fig/table references, claim wording, limitations).
- [ ] Read supplementary PDF once end-to-end (commands, filenames, reproducibility notes).
- [x] Confirm no stale text claiming "overlay only" in network section.
- [ ] Confirm title/abstract/keywords exactly match intended submission version.
- [ ] Confirm bibliography and citation formatting match venue requirements.
- [ ] Confirm author list, affiliations, and acknowledgments/funding text.
- [ ] Confirm anonymization policy (if required by track) is satisfied.
- [x] Prepare and verify submission package files required by the venue portal.
  - `out/submission_package_20260217_0047/`
  - `out/submission_package_20260217_0047/SHA256SUMS.txt`

## E. Optional One-Command Recheck (Before Upload)
```bash
cd "/Users/bill/Desktop/SkyBridge Compass Pro release"
ARTIFACT_DATE=2026-01-23 bash Scripts/check_top_tier_gate.sh
```

## F. Sign-off
- [ ] Technical sign-off (you)
- [ ] Writing/presentation sign-off
- [ ] Submission upload sign-off
