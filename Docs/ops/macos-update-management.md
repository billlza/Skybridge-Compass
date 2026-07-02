# macOS Update Management

Last verified: 2026-05-26

This document defines how SkyBridge Compass Pro discovers and publishes macOS
updates outside the Mac App Store.

## Release Authority

The app does not trust GitHub by itself. GitHub Releases is only the HTTPS asset
host for two files:

```text
SkyBridgeCompassPro-<version>.dmg
macos-stable.json
```

Trust comes from all of these checks:

- the DMG is signed with `Developer ID Application`;
- Apple notarization is accepted and the ticket is stapled to the DMG;
- `macos-stable.json` is signed with Ed25519;
- the signing key id and public key are compiled into
  `SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS`;
- the manifest points to a GitHub Releases HTTPS URL and marks
  `distribution=developer-id`, `package_format=dmg`, and `notarized=true`;
- the manifest `sequence` is monotonic and rollback is rejected by the app.

Unsigned manifests, unknown key ids, invalid signatures, HTTP URLs, unnotarized
packages, non-DMG packages, and sequence rollback all fail closed.

## Version Fields

Use these fields consistently:

```text
CFBundleShortVersionString  user-visible version, for example 1.0.0
CFBundleVersion             app build string, currently may be dotted
manifest.sequence           positive Int64 anti-rollback sequence
```

`manifest.sequence` must only increase. `Scripts/publish_macos_update_release.sh`
uses `CFBundleVersion` when it is a positive integer. If the build is dotted
such as `1.0.0`, it uses the current UTC timestamp in `yyyyMMddHHmmss` form.
For deterministic release trains, pass `--sequence <int64>` explicitly.

## Key Management

The manifest private key must never be committed. Store it outside the
repository, for example:

```text
~/.config/skybridge/update-manifest-ed25519-2026-05.seed
```

The file contains a base64-encoded 32-byte Ed25519 seed and must be readable
only by the release user. The public key is safe to commit in
`Sources/SkyBridgeCompassApp/Info.plist` and
`XcodeSupport/SkyBridgeCompassMac/Info.plist`.

To publish from GitHub Actions, configure these secrets:

```text
SKYBRIDGE_UPDATE_MANIFEST_KEY_ID
SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64
```

The workflow only publishes update assets when `publish_update_release=true`.

## Publish Flow

Build, sign, notarize, and staple the app and DMG:

```bash
SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=web_session \
SKYBRIDGE_REQUIRE_APP_GROUPS=1 \
SKYBRIDGE_REQUIRE_WIDGET_EXTENSION=1 \
bash Scripts/build_dmg.sh \
  --identity "Developer ID Application: Zi ang Li (YKUPL7Z869)" \
  --notarize-app \
  --notarize-dmg \
  --require-notarization
```

Verify the notarized artifacts:

```bash
xcrun stapler validate "dist/SkyBridge Compass Pro.app"
xcrun stapler validate "dist/SkyBridgeCompassPro-1.0.0.dmg"
spctl --assess --type execute --verbose=4 "dist/SkyBridge Compass Pro.app"
spctl --assess --type open --verbose=4 "dist/SkyBridgeCompassPro-1.0.0.dmg"
```

Publish the stable update assets:

```bash
bash Scripts/publish_macos_update_release.sh \
  --repository billlza/Skybridge-Compass \
  --tag stable \
  --app-path "dist/SkyBridge Compass Pro.app" \
  --dmg-path "dist/SkyBridgeCompassPro-1.0.0.dmg" \
  --key-id skybridge-release-ed25519-2026-05-local \
  --private-key-file "$HOME/.config/skybridge/update-manifest-ed25519-2026-05.seed"
```

The publisher verifies stapling before manifest generation, uploads both assets
with `gh release upload --clobber`, downloads them back, and checks that the
downloaded DMG hash matches the manifest `sha256`.

## App Behavior

The `Check for Updates` UI fetches `SKYBRIDGE_UPDATE_MANIFEST_URL`, verifies the
manifest signature, validates freshness and sequence, then compares
`version/build` with the running app. When an update is available, the app opens
the notarized DMG URL. It does not install silently.

## CI Requirements

The release workflow uses GitHub-hosted `macos-26` with:

```text
Xcode 26.6
Apple Swift 6.3.3
```

Do not downgrade `swift-tools-version` below `6.3`. The release readiness gate
calls `Scripts/verify_xcode_toolchain.sh` and fails if Xcode, Swift, or the
SwiftPM manifests drift from this baseline.
