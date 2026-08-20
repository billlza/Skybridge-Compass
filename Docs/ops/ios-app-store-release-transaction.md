# iOS / iPadOS App Store release transaction

This runbook publishes iOS `1.0.2 (2)` from the **same** `xcarchive` that passed
physical iPhone/iPad acceptance. It deliberately separates four gates:

1. create one clean-source production archive and a `release-testing` IPA;
2. run physical acceptance against that IPA and bind every evidence manifest to
   the archive identity;
3. export the same archive with the `app-store-connect` method;
4. upload only through a separate, explicitly confirmed command.

An archive identity uses SHA-256 only as a Level-1 reliability check to detect an
accidental cross-run archive or IPA substitution. It does not replace Apple code
signing, provisioning-profile validation, protected-environment approval, or App
Store Connect authentication.

## 1. Produce and seal one candidate

Start from the frozen, committed, clean release revision:

```bash
bash Scripts/build_ios_release_candidate.sh
bash Scripts/finalize_ios_release_archive_identity.sh
```

The second command creates
`.sandbox-home/release-candidate/ios-release-archive-identity.json`. It verifies:

- App and Widget are both `1.0.2 (2)`;
- source commit, source-input digest, repository, Release configuration,
  `HAS_APPLE_PQC_SDK`, and production surface match the candidate acceptance;
- the release-testing IPA still matches its formal product proof;
- the archive contains only regular files/directories and has one deterministic
  tree identity.

Do not mutate, rebuild, re-sign, or replace that archive after sealing it.

## 2. Bind physical acceptance to that archive

Every formal physical producer must install the app extracted from the sealed
candidate's release-testing IPA. It must not create another archive. Each of the
four final `release-acceptance.json` files must include this exact object, copied
from `ios-release-archive-identity.json`:

```json
{
  "iosReleaseArchive": {
    "schemaVersion": 1,
    "identityPurpose": "detect-accidental-cross-run-mismatch",
    "archiveTreeSha256": "<identity value>",
    "releaseTestingIpaSha256": "<identity value>",
    "appExecutableUUIDs": [
      {"architecture": "arm64", "uuid": "<identity value>"}
    ],
    "widgetExecutableUUIDs": [
      {"architecture": "arm64", "uuid": "<identity value>"}
    ],
    "debugSymbolsVerified": true,
    "sourceInputDigest": "<identity value>",
    "releaseVersion": "1.0.2",
    "releaseBuild": "2"
  }
}
```

Set the same two absolute inputs for every producer invocation:

```bash
export SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY=/absolute/release-candidate/ios-release-archive-identity.json
export SKYBRIDGE_IOS_RELEASE_TESTING_IPA=/absolute/release-candidate/export/SkyBridgeCompass-iOS.ipa

python3 Scripts/ios_physical_release_acceptance.py verify-product \
  --identity "$SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$SKYBRIDGE_IOS_RELEASE_TESTING_IPA"
```

Formal P2P and WebRTC producer modes, and the user-realistic file-transfer mode,
fail before launch when either input is absent or mismatched. They safely extract
and install that IPA; their `xcodebuild` archive/export/build paths are confined
to diagnostic modes and cannot become acceptance eligible. The connectivity
matrix producer must receive these same inputs and use the already installed
sealed product. A producer must bind its private pre-cleanup manifest before
public redaction, then finalize both copies with the same identity:

```bash
python3 Scripts/ios_physical_release_acceptance.py bind-manifest \
  --identity "$SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY" \
  --manifest /absolute/private-evidence/release-acceptance.json

python3 Scripts/finalize_release_acceptance_manifests.py \
  --private-manifest /absolute/private-evidence/release-acceptance.json \
  --public-manifest /absolute/public-evidence/release-acceptance.json \
  --archive-identity "$SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY"
```

The finalizer refuses an eligible manifest without the exact binding and never
adds a missing binding on behalf of a producer.

The required evidence directories are:

- `real-device-connectivity-matrix-public-redacted`
- `real-device-p2p-remote-smoke-public-redacted`
- `real-device-webrtc-smoke-public-redacted`
- `real-device-file-transfer-smoke-public-redacted`

After all four formal validators pass, finalize their exact binding:

```bash
python3 Scripts/ios_physical_release_acceptance.py create \
  --identity /absolute/release-candidate/ios-release-archive-identity.json \
  --release-testing-ipa /absolute/release-candidate/export/SkyBridgeCompass-iOS.ipa \
  --evidence-root /absolute/physical-evidence-root \
  --acceptance /absolute/release-candidate/ios-physical-release-acceptance.json
```

This command reruns the formal validators and fails if any evidence is incomplete,
ineligible, from another source revision, or bound to another archive/IPA.

When dispatching `real-device-release-gate`, supply both
`ios_archive_identity` and `ios_release_testing_ipa` as the same absolute files
used above. Staging and the post-archive validation repeat both checks; changing
the IPA or any one of the four manifest bindings makes the workflow fail closed.

## 3. Configure App Store Connect credentials

Keep the API private key outside the repository. Supply all three values only at
the command/workflow boundary:

- absolute path to `AuthKey_<KEY_ID>.p8`, owned by the current user and mode
  `0600` or stricter;
- the 10-character App Store Connect key ID;
- the issuer UUID.

The exporter validates the key without printing its contents or credential
references. The protected workflow expects environment secrets containing the
local runner key path, key ID, and issuer ID; it does not store the `.p8` content
in the repository or upload it as an artifact.

## 4. Export the accepted archive, without uploading

Use a fresh output directory under the repository `.sandbox-home` or the runner's
temporary root whose basename starts with `skybridge-ios-release-`:

```bash
bash Scripts/export_ios_app_store_product.sh \
  --archive /absolute/release-candidate/SkyBridgeCompass-iOS.xcarchive \
  --archive-identity /absolute/release-candidate/ios-release-archive-identity.json \
  --release-testing-ipa /absolute/release-candidate/export/SkyBridgeCompass-iOS.ipa \
  --physical-acceptance /absolute/release-candidate/ios-physical-release-acceptance.json \
  --evidence-root /absolute/physical-evidence-root \
  --output-dir /private/tmp/skybridge-ios-release-app-store \
  --api-key-path /absolute/AuthKey_<KEY_ID>.p8 \
  --api-key-id <KEY_ID> \
  --api-issuer-id <ISSUER_UUID>
```

The export options are fixed to:

- `method=app-store-connect`
- `destination=export`
- `signingStyle=automatic`
- `manageAppVersionAndBuildNumber=false`
- Team `YKUPL7Z869`
- external TestFlight/App Store eligibility retained
- symbols included

The verifier then checks the App and Widget signature chains, Apple Distribution
team/identity, non-device-bound App Store profiles, profile/certificate binding,
profile expiry, production entitlements, exact `1.0.2 (2)`, source provenance,
production compilation surface, and absence of binary test hooks. It also
recomputes the accepted archive identity and requires App/Widget dSYMs whose
UUIDs match their executables. Success writes
`ios-app-store-export-verification.json` and explicitly reports that no upload
was performed.

The `ios-app-store-export` workflow performs only this export on the protected
real-device runner under the `release-ios-app-store-export` approval environment.
It retains only the redacted log and verification JSON as workflow artifacts;
the IPA remains in the requested protected-runner output directory.

## 5. Explicit external upload

Review `ios-app-store-export-verification.json` and obtain explicit publication
approval. Only then run the separate upload command:

```bash
bash Scripts/upload_ios_app_store_product.sh --confirm-upload \
  --export-dir /private/tmp/skybridge-ios-release-app-store/export \
  --verification /private/tmp/skybridge-ios-release-app-store/ios-app-store-export-verification.json \
  --api-key-path /absolute/AuthKey_<KEY_ID>.p8 \
  --api-key-id <KEY_ID> \
  --api-issuer-id <ISSUER_UUID>
```

Without `--confirm-upload`, the command exits before reading credentials or using
the network. The exporter never calls this uploader. A successful upload only
means Apple accepted the transfer; processing, App/Widget version/build,
entitlements, privacy declarations, symbols/dSYM processing, TestFlight review,
and App Review submission remain separate App Store Connect gates.

## External readiness gates

Do not claim App Store release completion until all of these are current:

- physical iPhone and iPad acceptance from the sealed release-testing IPA;
- four archive-bound evidence manifests and finalized physical acceptance;
- protected export environment and externally supplied API identity available;
- verified App Store export from the same archive;
- explicit upload approval;
- App Store Connect processing succeeds and the processed `1.0.2 (2)` build is
  inspected before TestFlight distribution or review submission.
