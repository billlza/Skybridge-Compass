# macOS Release Packaging Runbook

Last verified: 2026-07-19

This runbook records the only supported release packaging path for SkyBridge
Compass Pro on macOS. Its purpose is to prevent four regressions that are easy
to reintroduce:

- shipping the smaller native `SkyBridgeCompassMac` app bundle instead of the
  SwiftPM executable runtime bundle
- shipping a bundle that looks like it contains WebRTC but is missing the app
  executable/resources required by the WebRTC path
- replacing the correct app icon with an inset or cached icon variant
- fixing only `Contents/Info.plist` while the executable still embeds a stale
  Info.plist, which macOS TCC will crash on launch
- shipping a Mac-side P2P fix without proving the signed, notarized app can
  reconnect to the same iPhone after Bonjour/name/OS-version metadata drift

## Golden Command

Use the release script as the entry point:

```bash
Scripts/build_dmg.sh --notarize-app --notarize-dmg --require-notarization
```

For an already-built Release product, this reuse path is allowed:

```bash
Scripts/build_dmg.sh --skip-build --notarize-dmg --require-notarization
```

The successful output artifacts are:

```text
dist/SkyBridge Compass Pro.app
dist/SkyBridgeCompassPro-1.0.0.dmg
~/Desktop/SkyBridgeCompassPro-1.0.0.dmg
```

## Correct Build Source

The release app must be assembled from an explicit Release executable product.
The default release path uses SwiftPM Release because Xcode Package schemes can
emit ambiguous macOS/Catalyst destination warnings on Xcode 26:

```text
.build/arm64-apple-macosx/release/SkyBridgeCompassApp
SkyBridgePackagingBuildSource = swiftpm_release
SkyBridgePackagingBuildScheme = SkyBridgeCompassApp
SkyBridgePackagingBuildConfiguration = Release
```

An Xcode workspace Release executable remains valid when the destination is
warning-free:

```text
.swiftpm/xcode/package.xcworkspace
scheme: SkyBridgeCompassApp
configuration: Release
product: ~/Library/Developer/Xcode/DerivedData/SkyBridgeCompassPro-Release/Build/Products/Release/SkyBridgeCompassApp
```

The native Xcode app target `SkyBridgeCompassMac` is not the release runtime.
It may be built to provide the Widget extension, but its `.app` bundle must not
be copied as the final app. The bad-signature smell is an app around 126 MB with
an 83 MB main binary. The expected release smell is an app around 175-180 MB
with a 113 MB main binary.

The final app Info.plist must record a release provenance:

```text
SkyBridgePackagingBuildSource = swiftpm_release or xcode_release
SkyBridgePackagingBuildScheme = SkyBridgeCompassApp
SkyBridgePackagingBuildConfiguration = Release
SkyBridgePackagingBuildProductPath = .../SkyBridgeCompassApp
```

## Mandatory Payload

The final `.app` must contain all of these:

```text
Contents/MacOS/SkyBridgeCompassApp
Contents/Frameworks/WebRTC.framework
Contents/Resources/SkyBridgeCompassApp_SkyBridgeCompassApp.bundle
Contents/Resources/SkyBridgeCompassApp_SkyBridgeCore.bundle
Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex
Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper/com.skybridge.PowerMetricsHelper
Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper.plist
```

WebRTC must be both linked by the executable and present under
`Contents/Frameworks`:

```bash
otool -L "dist/SkyBridge Compass Pro.app/Contents/MacOS/SkyBridgeCompassApp" | rg WebRTC
test -e "dist/SkyBridge Compass Pro.app/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
```

The executable must include the standard Frameworks rpath:

```bash
otool -l "dist/SkyBridge Compass Pro.app/Contents/MacOS/SkyBridgeCompassApp" \
  | awk '/LC_RPATH/{flag=1;next} flag&&/path/{print;flag=0}'
```

Expected rpaths include:

```text
@executable_path/../Frameworks
@executable_path/../lib
```

## TCC Privacy Plist Rule

`Sources/SkyBridgeCompassApp/Info.plist` is the source of truth for both the
outer app plist and the executable-embedded plist. Do not patch only
`dist/.../Contents/Info.plist` or `/Applications/.../Contents/Info.plist`.

The executable itself must contain these keys:

```text
NSBluetoothAlwaysUsageDescription
NSLocalNetworkUsageDescription
NSCameraUsageDescription
NSMicrophoneUsageDescription
NSLocationWhenInUseUsageDescription
```

Verify with:

```bash
strings -a "dist/SkyBridge Compass Pro.app/Contents/MacOS/SkyBridgeCompassApp" \
  | rg "NSBluetoothAlwaysUsageDescription|NSLocalNetworkUsageDescription|NSCameraUsageDescription|NSMicrophoneUsageDescription|NSLocationWhenInUseUsageDescription"
```

If the app crashes with a report saying:

```text
Namespace TCC
The app's Info.plist must contain an NSBluetoothAlwaysUsageDescription key
```

the fix is to rebuild `SkyBridgeCompassApp` from
`Sources/SkyBridgeCompassApp/Info.plist`, not to edit the installed app bundle.

## Correct Icon Assets

The canonical macOS icon artwork source lives in:

```text
Sources/SkyBridgeCompassApp/Resources/AppIconMaster.png
```

Generate derived assets only through:

```bash
Scripts/regenerate_app_icons.sh
```

For the cross-platform macOS/iOS icon invariants, see
`Docs/ops/app-icon-asset-governance.md`. The important split is that macOS keeps
the recovered transparent pre-rounded artwork, while iOS launcher icons must be
generated as opaque full-square PNGs from the cropped alpha bounding box.

Correct derived assets as verified on 2026-05-31:

```text
979d15acb9367e86256d383e0c9f6d27e2e6e17725664178703672c9164c5c82  Sources/SkyBridgeCompassApp/Resources/AppIconMaster.png
979d15acb9367e86256d383e0c9f6d27e2e6e17725664178703672c9164c5c82  Sources/SkyBridgeCompassApp/Resources/AppIcon.png
979d15acb9367e86256d383e0c9f6d27e2e6e17725664178703672c9164c5c82  Sources/SkyBridgeCompassApp/Resources/AppIconDock.png
979d15acb9367e86256d383e0c9f6d27e2e6e17725664178703672c9164c5c82  Sources/SkyBridgeCompassApp/Resources/AppIcon.icon/Assets/Image.png
bd2c0d852163d99f2ff683f5c5767f24419770d832e5f82d244d9af24d3d77e6  Sources/SkyBridgeCompassApp/Resources/AppIcon.icns
bd2c0d852163d99f2ff683f5c5767f24419770d832e5f82d244d9af24d3d77e6  Sources/SkyBridgeCompassApp/Resources/AppIconDock.icns
270943495835f20e8520e72c14fa4b41d013e7b2f73038b91c2bb3882b96f76c  Sources/SkyBridgeCompassApp/Resources/AppIcon.icon/icon.json
```

`AppIconMaster.png` is the recovered canonical artwork source. `AppIcon.png`,
`AppIconDock.png`, `BrandIcon.png`, `app_icon.png`,
`Assets.xcassets/BrandIcon.imageset/BrandIcon.png`, and
`AppIcon.icon/Assets/Image.png` are generated outputs. Those PNG outputs must be
byte-for-byte identical after regeneration. The visually correct icon is the
blue-bottom compass icon recovered from the historical `979d15ac...` app-icon
artifact. If Finder shows a smaller icon nested inside another rounded
rectangle, reject that build and regenerate from `AppIconMaster.png`.

Both `AppIcon.icns` and `AppIconDock.icns` are generated compatibility outputs
and must include 512x512 and 1024x1024 representations.

The packaged macOS app plist must point at the precomposed ICNS:

```text
CFBundleIconFile = AppIcon.icns
```

For the packaged macOS app, the correct runtime icon path is:

```text
Sources/SkyBridgeCompassApp/Resources/AppIconMaster.png
  -> Scripts/regenerate_app_icons.sh
  -> Sources/SkyBridgeCompassApp/Resources/AppIcon.icns
  -> SkyBridge Compass Pro.app/Contents/Resources/AppIcon.icns
  -> CFBundleIconFile = AppIcon.icns
  -> LaunchServices / NSApplication.shared.applicationIconImage
```

`Sources/SkyBridgeCompassApp/Resources/AppIcon.icon` and
`Sources/SkyBridgeCompassApp/Resources/Assets.xcassets` are source inputs only.
They must stay in source control, but they must not be copied into
`SkyBridge Compass Pro.app/Contents/Resources/`. The final app bundle should
contain only the full-size precomposed `AppIcon.icns` plus runtime
`BrandIcon.png` for visible brand UI; it must not contain flattened Icon Composer
source files such as `icon.json` or `Image.png`, raw PNG aliases, or asset
catalog sources.

Do not set `NSApplication.shared.applicationIconImage` from bundled
`AppIcon.png`, `AppIcon.icns`, `AppIconDock.png`, or `AppIconDock.icns` in the
packaged app startup path. The launched app icon should come back through
LaunchServices as `NSApplication.shared.applicationIconImage` after
`CFBundleIconFile = AppIcon.icns` resolves the precomposed ICNS.

Do not recover icons from `/Applications`, Finder cache, temporary DMG staging
folders, or old `dist` bundles.

## Release Verification

After packaging, run the readiness gate:

```bash
Scripts/check_macos_release_readiness.sh \
  --require-notarization \
  --launch-timeout 30 \
  --steady-state 8 \
  --app-path "dist/SkyBridge Compass Pro.app" \
  --dmg-path "dist/SkyBridgeCompassPro-1.0.0.dmg" \
  --connectivity-artifact-dir "Artifacts/<real-device-connectivity-matrix>" \
  --p2p-remote-artifact-dir "Artifacts/<real-device-p2p-remote-smoke>" \
  --file-transfer-artifact-dir "Artifacts/<real-device-file-transfer-smoke>"
```

This gate runs the Rust CLI operator check-surface coverage threshold
(`>=88%`), the Mac/iOS connectivity matrix check, real-device performance
checks for P2P remote and file transfer, and a `leaks` scan against the
launched app process. The 88% threshold is an
operator check-surface gate, not Rust line or branch coverage.

Useful manual size and payload check:

```bash
du -sh \
  "dist/SkyBridge Compass Pro.app" \
  "dist/SkyBridge Compass Pro.app/Contents/MacOS/SkyBridgeCompassApp" \
  "dist/SkyBridge Compass Pro.app/Contents/Frameworks/WebRTC.framework" \
  "dist/SkyBridge Compass Pro.app/Contents/Resources/SkyBridgeCompassApp_SkyBridgeCompassApp.bundle" \
  "dist/SkyBridgeCompassPro-1.0.0.dmg"
```

Expected scale from the 2026-05-12 known-good package:

```text
175M  dist/SkyBridge Compass Pro.app
113M  dist/SkyBridge Compass Pro.app/Contents/MacOS/SkyBridgeCompassApp
26M   dist/SkyBridge Compass Pro.app/Contents/Frameworks/WebRTC.framework
14M   dist/SkyBridge Compass Pro.app/Contents/Resources/SkyBridgeCompassApp_SkyBridgeCompassApp.bundle
68M   dist/SkyBridgeCompassPro-1.0.0.dmg
```

Size is a smell, not the contract. The contract is the build source metadata,
the linked/present WebRTC framework, the app resource bundle, the embedded TCC
keys, signing validity, notarization/stapling, and launch smoke.

## Update Discovery Contract

The in-app Check for Updates flow is backed by a GitHub Releases manifest, not
a placeholder alert. Release builds must point
`SKYBRIDGE_UPDATE_MANIFEST_URL` at the manifest in the explicitly marked Latest
immutable macOS Release:

```text
https://github.com/billlza/Skybridge-Compass/releases/latest/download/macos-stable.json
```

The manifest must be signed with Ed25519. The app verifies the detached
signature with the public keys in
`SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS` before comparing versions or
opening the DMG URL. Unsigned manifests, untrusted key ids, insecure URLs,
non-Developer-ID distributions, and packages not marked notarized are rejected
fail-closed.

The signing private key must live outside the repository, for example in a
release keychain item or a GitHub/self-hosted-runner secret. Do not commit the
private key. The release readiness script also rejects update metadata that is
not a GitHub Releases HTTPS asset or that lacks trusted public-key material.

Operational publishing details live in
[`Docs/ops/macos-update-management.md`](macos-update-management.md).
The supported publisher requires a pre-pushed
`macos-v<semver>-build-<build>` tag bound to the exact source SHA, publishes the
DMG, signed manifest, and public-redacted evidence archive together from a
verified draft, and verifies GitHub release and per-asset attestations after the
single publication transition. It never mutates the legacy `stable` Release or
replaces an asset. Existing clients that still use the legacy stable URL require
an explicit bridge-update or manual-upgrade plan before that manifest expires.

## P2P Identity Drift Gate

P2P release fixes must survive device metadata drift after iOS/macOS updates,
Xcode updates, reboot, and transport changes between Wi-Fi and wired device
tunnels. Treat OS/app version, Bonjour instance text, display labels, and
transport as mutable metadata. They must not become the protocol identity used
for strict PQC trust or KEM bootstrap.

For Mac-side P2P/file-transfer fixes, the release is not accepted until the
signed, notarized DMG has passed the real-device CLI with a Mac-initiated
reconnect transfer:

```bash
SKYBRIDGE_SMOKE_MAC_DMG_PATH="$HOME/Desktop/SkyBridgeCompassPro-1.0.0.dmg" \
SKYBRIDGE_SMOKE_USER_REALISTIC=1 \
SKYBRIDGE_SMOKE_MAC_HOST_MODE=signed-app \
SKYBRIDGE_SMOKE_REQUIRE_MAC_INITIATED_RECONNECT=1 \
SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="X-Wing" \
cargo run --manifest-path rust/Cargo.toml -p skybridge -- \
  smoke suite \
  --profile real-device-file-transfer \
  --real-device-id <iOS CoreDevice UDID> \
  --timeout-seconds 1200
```

Required proof markers:

- Mac status log contains `mac-reconnect connect-start`, `mac-reconnect
  connected`, and `mac-reconnect outbound-complete`.
- iOS status log contains `mac-reconnect inbound-complete`.
- Final status contains `success`, `suite=X-Wing`, and `macReconnect=1`.
- If Mac discovery reports `deviceId=- unique=bonjour:...`, strict PQC must
  still recover the trusted KEM record through alias repair. A fallback to
  Classic is a release-blocking regression, even if the transfer path appears
  to connect.

### Classic File-Transfer Session Freshness

Mac-initiated reconnect can leave two valid-looking session sources for the
same iPhone: an older inbound classic-transfer snapshot and the fresh live P2P
connection that just completed X-Wing. File-transfer metadata and receipt HMAC
must be derived from the freshest matching authenticated source. A stale
snapshot must not override a live connection for the same identity and
endpoint.

Regression signature:

- macOS status stops at `mac-reconnect connected` and then fails with
  `receipt_wait_auth_failed`.
- System log shows a tiny TCP transfer, usually metadata out and a failure
  receipt in, rather than full file bytes.
- iOS status remains at `mac-reconnect wait-inbound` and never reaches
  `mac-reconnect inbound-complete`.

The real-device CLI gate above is the authoritative check. Unit coverage must
also keep
`FileTransferManagerSecurityTests.testClassicTransferSessionSourceResolutionPrefersFreshLiveConnectionOverOlderSnapshot`
passing so future route/session refactors do not reintroduce stale-key
selection.

### Mac-Initiated Reconnect Route Binding

Mac reconnect must not treat `host:`, `peer:`, Bonjour names, display names, or
version-decorated labels as stable peer identity. Those values are route hints
only. After the control channel authenticates, the fresh live P2P connection
must publish a classic-transfer session snapshot whose aliases include:

- the authenticated pairing-identity `deviceId`;
- the normalized handshake peer id;
- the Bonjour/endpoint aliases used to dial the target;
- the resolved host/IP currently backing the NWConnection;
- the advertised `fileTransferPort`.

The real-device CLI must log `mac-reconnect outbound-route-probe` before the
Mac reconnect transfer. `mac-reconnect outbound-route-probe missing` followed
by `No Authenticated Route for Target Peer` means the control channel connected
before the authenticated file-transfer route became visible, or the reconnect
target only carried a mutable Bonjour/display alias such as
`bonjour:iPhone@local.`. Route resolution must wait briefly for the fresh route
and then prefer stable authenticated aliases, falling back to the verified
target display name only after alias matching misses. If the first route is
`presence:inbound`, the CLI must fail fast because that means the Mac is about
to replay an old inbound route instead of the fresh authenticated reconnect
session. Keep
`FileTransferManagerSecurityTests.testClassicTransferCandidateForReconnectConnectionCarriesStableIdentityAndResolvedEndpoint`
and
`FileTransferRouteResolutionTests.testActivePeerRoutesPreferAuthenticatedSessionOverInboundPresenceForReconnect`
and
`FileTransferRouteResolutionTests.testResolveActivePeerRoutesFallsBackToPreferredNameWhenReconnectUsesBonjourAlias`
passing.

### Notarization Stapler Reliability

Apple notarization can return `Accepted` while `xcrun stapler staple` times out
against CloudKit. Treat that as an infrastructure retry case, not as a license
to ship an unstapled artifact. `Scripts/notarytool_helpers.sh` retries stapling
before failing; after any retry, independently validate both artifacts:

```bash
xcrun stapler validate "dist/SkyBridge Compass Pro.app"
xcrun stapler validate "dist/SkyBridgeCompassPro-1.0.0.dmg"
```

## Do Not

- Do not publish a bundle copied from `SkyBridgeCompassMac.app`.
- Do not treat a present `WebRTC.framework` alone as proof that WebRTC is
  working; the executable and app resource bundle must also be the correct
  runtime.
- Do not edit only the installed app in `/Applications`.
- Do not patch only the outer `Contents/Info.plist` for TCC keys.
- Do not replace the icon from screenshots, Finder thumbnails, cached icons, or
  old DMG staging output.
- Do not remove `SkyBridgeCompassApp_SkyBridgeCompassApp.bundle` to make the app
  smaller.
