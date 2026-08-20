# macOS Update Management

Last verified: 2026-07-19

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
CFBundleVersion             positive integer build identifier
manifest.sequence           positive Int64 anti-rollback sequence
```

`manifest.sequence` must only increase. `Scripts/publish_macos_update_release.sh`
requires a positive integer `CFBundleVersion` and requires `manifest.sequence`
to equal that exact build for an official immutable release. It does not invent
a timestamp fallback. This keeps the app bundle, signed manifest, tag, and
anti-rollback order on one deterministic release identity.

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

The workflow only publishes update assets when `publish_update_release=true`
and the operator also supplies the exact `publish_release_tag`. The producer
workflow path, event, and seven accepted evidence artifact names are fixed in
the workflow; callers cannot substitute a weaker producer or evidence set.

## Publish Flow

Build, sign, notarize, and staple the app and DMG:

```bash
: "${SKYBRIDGE_RELEASE_BUILD_ID:?set the positive numeric build from the release tag}"
SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=web_session \
SKYBRIDGE_REQUIRE_APP_GROUPS=1 \
SKYBRIDGE_REQUIRE_WIDGET_EXTENSION=1 \
bash Scripts/build_dmg.sh \
  --build-id "$SKYBRIDGE_RELEASE_BUILD_ID" \
  --identity "Developer ID Application: Zi ang Li (YKUPL7Z869)" \
  --notarize-app \
  --notarize-dmg \
  --require-notarization
```

Verify the notarized artifacts:

```bash
xcrun stapler validate "dist/SkyBridge Compass Pro.app"
xcrun stapler validate "dist/SkyBridgeCompassPro-1.0.2.dmg"
spctl --assess --type execute --verbose=4 "dist/SkyBridge Compass Pro.app"
spctl --assess --type open --verbose=4 "dist/SkyBridgeCompassPro-1.0.2.dmg"
```

Create and push the unique annotated release tag before invoking the publisher.
The tag must exactly match the packaged version and numeric build and must point
to the source commit being released:

```bash
source_sha="$(git rev-parse HEAD)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/SkyBridge Compass Pro.app/Contents/Info.plist')"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' 'dist/SkyBridge Compass Pro.app/Contents/Info.plist')"
tag="macos-v${version}-build-${build}"
git tag -a "$tag" "$source_sha" -m "SkyBridge Compass Pro ${version} (${build})"
git push origin "refs/tags/${tag}"
```

Then publish the immutable update release from a clean checkout, using the
public-redacted evidence archive produced by the release-readiness workflow:

```bash
bash Scripts/publish_macos_update_release.sh \
  --repository billlza/Skybridge-Compass \
  --tag "$tag" \
  --expected-source-sha "$source_sha" \
  --app-path "dist/SkyBridge Compass Pro.app" \
  --dmg-path "dist/SkyBridgeCompassPro-1.0.2.dmg" \
  --evidence-provenance-path "Artifacts/release-gate/release-artifact-run-provenance.json" \
  --evidence-asset "dist/macos-release-evidence.tar.gz" \
  --key-id skybridge-release-ed25519-2026-05-local \
  --private-key-file "$HOME/.config/skybridge/update-manifest-ed25519-2026-05.seed"
```

The publisher rejects `stable`, an absent or mismatched tag, an existing draft
or published Release, a dirty checkout, a source-SHA mismatch, duplicate or
linked asset files, and any version/build/tag disagreement. It validates the
DMG, notarization, signed manifest, and evidence files locally. The producer-run
provenance must bind the same repository and source SHA, the fixed producer
workflow/event, and the exact seven unexpired artifact names with GitHub SHA-256
digests. The publisher stages immutable copies and records every release asset
SHA-256 before making a remote mutation.
Before creating the draft, it also calls GitHub's immutable-releases repository
endpoint using API version `2026-03-10` and requires `enabled=true`; a repository
with immutability disabled is not allowed to enter the publication transaction.

It then creates one draft with every asset attached. While the release is still
a draft, it verifies the exact asset-name set, downloads every asset, rechecks
every SHA-256, and reruns manifest validation against the downloaded DMG. Only a
complete verified draft is published and marked Latest. After publication, it
requires `isImmutable=true`, repeats the complete read-back, runs
`gh release verify`, and runs `gh release verify-asset` for every staged file.
There is no asset replacement path and no `--clobber` operation. A failure
before publication leaves an unpublished draft for audit; that draft must be
deleted after investigation and must never be resumed or reused.
The workflow retains the resulting `macos-stable.publish-proof.json` as a
separate 90-day Actions artifact; it records the source SHA, exact asset names
and hashes, immutable state, and attestation results without changing the
already-published Release.

The historical `stable` Release is a legacy discovery pointer and is not
modified by this publisher. New clients should discover the manifest through:

```text
https://github.com/billlza/Skybridge-Compass/releases/latest/download/macos-stable.json
```

Clients already shipped with the `/releases/download/stable/` URL cannot learn
the new endpoint from a uniquely tagged release. Before the legacy manifest
expires, they need either one explicitly approved bridge update on the old
channel or a documented manual upgrade. Do not silently mutate the old channel
as part of a new immutable release.

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
