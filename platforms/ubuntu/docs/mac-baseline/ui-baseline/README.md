# UI Baseline Checklist (Pixel Parity)

Use fixed capture conditions:

- Window size: `1200x800`
- Theme: Light and Dark
- Locale: `en-US` (secondary pass: `zh-CN`)
- Scale factor: 100%
- Font rendering: default system stack, hinting unchanged
- Capture order: Login → Dashboard → Devices → Transfers → Settings → Tray/Notifications

Pages to capture:

1. Login
2. Dashboard
3. Devices
4. Transfers
5. Settings
6. Tray / notifications entry states

For each page, verify:

- Typography hierarchy (title/body/caption)
- Spacing/padding grid
- Corner radius and borders
- Interactive states (hover/pressed/disabled)
- Status colors and icon alignment

## Diff gate recommendation

- Default threshold: pixel mismatch ratio `<= 0.5%` per screenshot
- Hard fail threshold: pixel mismatch ratio `> 1.0%`
- Any mismatch in critical areas (primary buttons, status pills, error banners) is blocking even if global ratio passes

## Required artifact bundle

- Ubuntu screenshot set (light + dark)
- Mac baseline screenshot set (light + dark)
- Diff outputs and summary JSON
- Reviewer sign-off attached to release note / PR

## Capture naming + automated diff

- Capture manifest: `docs/mac-baseline/ui-baseline/capture-manifest.json`
- Screenshot naming: `<capture-id>.png` (for example `UI-CAP-001.png`)
- Directory layout (recommended):
  - `docs/mac-baseline/ui-baseline/screenshots/ubuntu/`
  - `docs/mac-baseline/ui-baseline/screenshots/mac/`
  - `docs/mac-baseline/ui-baseline/reports/<run-id>/`

Run automated diff:

```bash
python3 docs/mac-baseline/ui-baseline/compare_screenshots.py \
  --ubuntu-dir docs/mac-baseline/ui-baseline/screenshots/ubuntu \
  --mac-dir docs/mac-baseline/ui-baseline/screenshots/mac \
  --out-dir docs/mac-baseline/ui-baseline/reports/latest
```

Outputs:

- `summary.json`: machine-readable gate result
- `summary.md`: reviewer-friendly table
- `diff/*.png`: per-capture highlighted difference overlays

## Deterministic Ubuntu capture flow

The Ubuntu build now exposes a fixture-based capture mode for every matrix row, including:

- `UI-CAP-013`: USB inventory
- `UI-CAP-014`: Remote desktop sessions
- `UI-CAP-015`: Monitor snapshot

Generate the full Ubuntu screenshot set and diff it in one command:

```bash
python3 scripts/capture_ui_baseline.py --allow-missing
```

Useful flags:

- `--capture-id UI-CAP-014` to run a single fixture
- `--skip-compare` to only emit Ubuntu PNGs
- `--skip-build` to reuse the last binary
- `--profile release` to test release rendering

Headless Linux runners are supported when `xvfb-run` is available; the script enables it automatically when `DISPLAY` is absent.
