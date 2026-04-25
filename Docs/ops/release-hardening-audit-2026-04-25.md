# Release Hardening Audit - 2026-04-25

## Scope

This checkpoint reviewed the remaining release branch changes before committing them together. The audit focused on:

- remote desktop LAN/P2P bootstrap and stream reliability
- current-path trust and KEM identity binding
- Supabase auth risk guard and login audit semantics
- iOS test-lane membership and remote desktop regressions
- macOS Developer ID signing, notarization, DMG packaging, and readiness gates

## Closed Issues

- Restored persisted macOS auth-session recovery during startup.
- Restored current-path local binding provisioning from the active device identity instead of existing-only cached values.
- Made ScreenCaptureKit system-audio setup degrade to video-only when audio output/start fails.
- Kept QR/code identity trust provider active for PQC inbound/rekey handshakes.
- Added timeout protection to iOS file-transfer listener startup without double-resuming continuations.
- Restored trusted, connected macOS LAN fallback eligibility for iOS remote desktop entry.
- Removed PR-controlled signing/notary secret exposure from macOS release readiness workflow.
- Removed committed Apple account identifiers from notary documentation.
- Changed auth login risk handling to use an independent `attempt_type=login` bucket while still issuing audit tickets and recording login attempts.
- Made login risk guard failures fail closed instead of silently continuing without an audit ticket.
- Fixed Python 3.9 compatibility in the iOS test configuration checker.

## Regression Guards

- `RegistrationSecurityServiceTests` now asserts login attempts are recorded in a separate login pool, do not consume registration quota, and successful logins do not count toward login failure limits.
- `auth_login_guard_acceptance.sql` now verifies login guard ticket issuance and login attempt recording.
- `test_check_ios_test_configuration.sh` covers missing test target membership, missing host-app build target, and launch-action drift.
- iOS regression tests cover the trusted live macOS LAN remote desktop eligibility fallback.

## Verification

Passed on 2026-04-25:

- `git diff --check`
- `swift test`
- `swift test --filter RegistrationSecurityServiceTests`
- `swift test --filter KeychainManagerSupabaseConfigTests`
- `npm run check && npm test` in `Server/skybridge-signaling`
- `Scripts/test_package_build_policy.sh`
- `Scripts/test_signing_entitlements_helpers.sh`
- `Scripts/test_xcodebuild_helpers.sh`
- `Scripts/test_check_ios_test_configuration.sh`
- `SkyBridge Compass iOS/Scripts/test_lane_ios.sh`
- `Scripts/build_dmg.sh --notarize-app --notarize-dmg --require-notarization`
- `Scripts/check_macos_release_readiness.sh --require-notarization`

## Release Artifact

- App bundle: `dist/SkyBridge Compass Pro.app`
- DMG: `dist/SkyBridgeCompassPro-1.0.0.dmg`
- Desktop copy: `/Users/bill/Desktop/SkyBridgeCompassPro-1.0.0.dmg`

Both the app zip and DMG notarization submissions were accepted, stapling succeeded, and the macOS release readiness gate passed.
