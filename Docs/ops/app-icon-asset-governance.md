# App Icon Asset Governance

Last verified: 2026-05-31

This document is the source-of-truth contract for SkyBridge Compass app icons.
Do not recover icon assets from Finder caches, installed apps, old DMG staging
folders, screenshots, or temporary generated files.

## Canonical Source

The canonical artwork source is:

```text
Sources/SkyBridgeCompassApp/Resources/AppIconMaster.png
```

The canonical source hash at the time of this record is:

```text
979d15acb9367e86256d383e0c9f6d27e2e6e17725664178703672c9164c5c82  Sources/SkyBridgeCompassApp/Resources/AppIconMaster.png
```

All derived icon assets must be regenerated from this file with:

```bash
Scripts/regenerate_app_icons.sh
```

Manual edits to generated icon PNGs, ICNS files, or asset-catalog slots are not
allowed. Regenerate the whole set instead.

## Protected File Set

Treat these paths as a single locked icon set. A pull request or local change
that touches any generated path without also running the regeneration and
verification scripts is invalid.

```text
Sources/SkyBridgeCompassApp/Resources/AppIconMaster.png
Sources/SkyBridgeCompassApp/Resources/AppIcon.png
Sources/SkyBridgeCompassApp/Resources/AppIconDock.png
Sources/SkyBridgeCompassApp/Resources/BrandIcon.png
Sources/SkyBridgeCompassApp/Resources/SidebarBrandIcon.png
Sources/SkyBridgeCompassApp/Resources/app_icon.png
Sources/SkyBridgeCompassApp/Resources/AppIcon.icns
Sources/SkyBridgeCompassApp/Resources/AppIconDock.icns
Sources/SkyBridgeCompassApp/Resources/AppIcon.icon/Assets/Image.png
Sources/SkyBridgeCompassApp/Resources/Assets.xcassets/BrandIcon.imageset/BrandIcon.png
SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/AppIcon.appiconset/*.png
SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/BrandIcon.imageset/BrandIcon.png
```

The review rule is intentionally strict:

- Do not update one icon slot by hand.
- Do not replace a PNG with a screenshot, Finder thumbnail, DMG artifact, or
  installed app resource.
- Do not use `AppIconMaster.svg` as the source of truth; it is legacy context,
  not the current accepted artwork.
- Do not "fix" iOS by copying the transparent macOS PNGs into
  `AppIcon.appiconset`; iOS launcher icons must remain opaque RGB outputs.
- If the desired visual identity changes, replace `AppIconMaster.png`, run the
  scripts below, inspect both macOS and iOS output, then update this document's
  hash record in the same commit.

## macOS Contract

macOS keeps the recovered pre-rounded transparent artwork as the runtime brand
source:

```text
Sources/SkyBridgeCompassApp/Resources/AppIcon.png
Sources/SkyBridgeCompassApp/Resources/AppIconDock.png
Sources/SkyBridgeCompassApp/Resources/BrandIcon.png
Sources/SkyBridgeCompassApp/Resources/app_icon.png
Sources/SkyBridgeCompassApp/Resources/AppIcon.icon/Assets/Image.png
Sources/SkyBridgeCompassApp/Resources/Assets.xcassets/BrandIcon.imageset/BrandIcon.png
```

Those PNG files must remain byte-for-byte identical to `AppIconMaster.png`.
`SidebarBrandIcon.png` is the only generated PNG derivative that intentionally
differs; it is optically cropped and sharpened for the compact sidebar grid.

The packaged macOS app uses the precomposed ICNS path:

```text
CFBundleIconFile = AppIcon.icns
```

The release bundle must not contain source inputs such as `AppIconMaster.png`,
`AppIcon.icon`, `Assets.xcassets`, raw alias PNGs, or stale app-icon SVGs.

## iOS Contract

iOS app icons must be opaque full-square RGB PNGs. iOS applies the final rounded
mask itself, so the iOS `AppIcon.appiconset` must not reuse the Mac transparent
padding as-is and must not fill that padding with an arbitrary dark or light
background.

The required iOS generation flow is:

```text
AppIconMaster.png
  -> crop the alpha bounding box
  -> fit the cropped artwork to the full-square iOS canvas
  -> flatten residual transparency to an edge-sampled background
  -> resize into every AppIcon.appiconset slot
```

This prevents the recurring "icon inside another icon" failure where the Mac
pre-rounded tile appears inset inside the iOS system-rounded icon.

The iOS in-app `BrandIcon.imageset/BrandIcon.png` is not the app launcher icon;
it intentionally matches the canonical Mac `AppIcon.png` so in-app branding
stays consistent.

## Required Verification

Before committing any icon asset change, run:

```bash
Scripts/regenerate_app_icons.sh
Scripts/verify_app_icons.sh
xcodebuild \
  -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' \
  -scheme 'SkyBridgeCompass-iOS' \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`Scripts/verify_app_icons.sh` fails if:

- canonical macOS PNG outputs drift from `AppIconMaster.png`
- `SidebarBrandIcon.png` stops being the dedicated small-size derivative
- iOS AppIcon slots contain alpha, wrong dimensions, extra PNGs, or pixels that
  do not match the full-square crop pipeline
- generated ICNS files drift from the canonical full-size representation set

When checking an installed iOS build, delete the old app before reinstalling.
iOS caches home-screen icons aggressively, and an incremental reinstall can show
a stale icon even when the asset catalog is correct.
