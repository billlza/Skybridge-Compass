# Apple formal product evidence

Apple release acceptance is product-only. The formal producers are:

- `Scripts/run_formal_ios_identity_lifecycle.sh`, run once for the immutable
  production identity lifecycle;
- `Scripts/run_formal_product_evidence_session.sh`, run once for each of
  `connectivity`, `p2p`, `webrtc`, and `file-transfer`.

The older `run_real_device_*_smoke.sh` programs remain diagnostic-only. Their
helpers, testing compilation conditions, environment triggers, status labels,
media-doctor output, and synthetic inputs can never enter the formal file set.

## Immutable product inputs

Build the signed/notarized Mac candidate and sealed iOS archive first. Every
formal run verifies the same exact inputs before launch:

- `macos-release-candidate.json`, `SkyBridge Compass Pro.app`, and its DMG;
- the sealed iOS archive identity and matching release-testing IPA;
- the physical device's `devicectl` identifier and `xcdevice` UDID.

The producer does not rebuild, re-sign, notarize, upload, or publish. It
extracts the app from the sealed IPA, installs that exact app with
`devicectl device install app`, then validates exactly one installation-result
record and a post-install query for bundle, version, build, remote app path,
and executable UUIDs. A process snapshot must prove the app absent before each
owned fresh launch. Launch uses the verified persistent identifier, no launch
arguments, no child environment, and no terminate-existing option.

## One-time production identity lifecycle

ML-DSA-87 + Secure Enclave identity creation is not repeated for every evidence
kind. Run `run_formal_ios_identity_lifecycle.sh` once:

1. The first ordinary product launch commits a newly created identity only
   after the normal Settings/rotation receipt and runtime self-test succeed.
2. The exact process is stopped and absence is proven.
3. A different fresh launch restores the same immutable Keychain authority and
   completes a real signing self-test.
4. The typed extractor privately joins the stable `id1:` reference, exact
   install, launch identities, and sealed archive.

The private output is mode `0700` and contains a mode-`0600` lifecycle binding.
It is sensitive and must never be uploaded. The public lifecycle proof uses
only the artifact-local alias `identity-1`; it contains no stable fingerprint,
raw key, device identifier, session, address, account, or path. The transaction
never clears Keychain and never recreates an established identity.

## Per-kind ordinary product runs

Each kind uses a new ordinary iOS launch. That exact process must emit a
restored identity terminal followed by a current-path handshake binding. The
session extractor privately proves its `id1:` matches the one-time lifecycle,
then requires the bound `ev1:` to occur in this run's paired product log. The
public per-kind proof again contains only `identity-1` and the current `ev1:`.

Use the normal product UI and complete these fixed contracts:

- Connectivity: three paired success profiles `xwing/xwing`, `xwing/pqc`, and
  `pqc/xwing`, plus one correctly signed classic strict-PQC rejection at each
  shipping responder. The classic stimulus is not a shipping endpoint.
- P2P: two different authenticated X-Wing sessions. In A, iOS initiates and Mac
  responds with the real notice/panel/user approval, peer renderer ACK, applied
  input, and normal disconnect. In B, Mac initiates and iOS responds; both
  endpoints authenticate and disconnect normally.
- WebRTC: exact selected relay path and authenticated X-Wing rekey on both
  endpoints; two to four cumulative RTP samples per endpoint over at least 30
  seconds, with video/audio frames or packets and bytes strictly increasing.
  Mac additionally proves real notice approval, peer renderer receipt, applied
  input, and hidden panel on disconnect.
- File transfer: one paired authenticated P2P session and two distinct transfer
  references: Mac-to-iOS and iOS-to-Mac. Both endpoints emit Started/Completed
  from complementary normal Send/Accept UI, nonempty payload, verified
  integrity, authenticated receipt, completed UI, and normal disconnect.

Each process/session has a 20-event hard bound. Product OSLog exposes no raw
ID, IP, path, name, key, coordinate, or exact file byte count. `noticeHidden=1`
is valid only for the Mac session whose real panel lifecycle was captured; iOS
and short non-notice owners use `not-applicable`.

TCC, SAS, suite selection, and user approval remain explicit manual actions.
The producer does not click, auto-approve, inject trust, or modify preferences.

## Fixed public artifact contract

Every finalized kind contains exactly:

- `mac-product-session.log`
- `mac-product-session-capture.json`
- `ios-product-session.log`
- `ios-product-session-capture.json`
- `ios-product-installation-capture.json`
- `ios-production-identity-proof.json`
- `macos-release-candidate.json`
- `release-acceptance.json`

Raw unified-log rows, device IDs, audit tokens, remote installed-app paths, and
the lifecycle binding stay private. Both physical identifiers are supplied to
the public materializer as redaction tokens. Schema validators run before
copying fixed records and again after materialization. The scanner explicitly
rejects any `id1:<32hex>` stable identity reference.

## Monotonic finalization

The order is fail-closed:

1. verify immutable candidate/archive inputs and one-time lifecycle proof;
2. install exact sealed app and prove pre-launch absence;
3. launch normal products and capture exact PID/process-owned OSLog;
4. stop both owned processes and prove absence;
5. validate paired typed logs, current identity binding, installation capture,
   candidate source equality, and archive/IPA binding;
6. derive a red pre-cleanup manifest (`eligible=false`, `cleanup=false`,
   `diagnostic=true`);
7. materialize and scan the public fixed file set;
8. finalize private first, verify it, then finalize public;
9. run the complete acceptance validator against the original sealed inputs.

No caller JSON can set a verified/eligible field. SHA-256 values already used
by candidate and archive identities detect accidental cross-run byte mismatch;
they are not treated as a new security boundary.

## Commands

One-time lifecycle:

```bash
Scripts/run_formal_ios_identity_lifecycle.sh \
  --private-output-dir /absolute/private-identity-lifecycle \
  --public-output-dir /absolute/public-identity-lifecycle \
  --ios-archive-identity /absolute/ios-release-archive-identity.json \
  --ios-release-testing-ipa /absolute/SkyBridgeCompass-iOS-release-testing.ipa \
  --ios-device-id DEVICECTL-ID \
  --ios-device-udid XCDEVICE-UDID
```

One per kind:

```bash
Scripts/run_formal_product_evidence_session.sh \
  --kind connectivity \
  --artifact-dir /absolute/private-connectivity \
  --public-artifact-dir /absolute/public-connectivity \
  --candidate-manifest /absolute/candidate/macos-release-candidate.json \
  --candidate-app "/absolute/candidate/SkyBridge Compass Pro.app" \
  --candidate-dmg /absolute/candidate/SkyBridgeCompassPro-1.0.2.dmg \
  --ios-archive-identity /absolute/ios-release-archive-identity.json \
  --ios-release-testing-ipa /absolute/SkyBridgeCompass-iOS-release-testing.ipa \
  --ios-device-id DEVICECTL-ID \
  --ios-device-udid XCDEVICE-UDID \
  --identity-lifecycle-binding /absolute/private-identity-lifecycle/ios-production-identity-lifecycle-binding.json \
  --identity-lifecycle-proof /absolute/public-identity-lifecycle/ios-production-identity-lifecycle-proof.json \
  --expected-source-repository owner/repository \
  --expected-source-sha 0000000000000000000000000000000000000000
```

Repeat the second command with new destinations for `p2p`, `webrtc`, and
`file-transfer`, reusing the immutable lifecycle inputs without rotating or
deleting the identity.
