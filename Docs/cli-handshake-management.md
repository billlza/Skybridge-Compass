# Native handshake configuration — CLI 0.4.0-dev.6

This development feature implements `skybridge tui` → `/handshake` and the scriptable `skybridge crossnet handshake` family. It uses native SkyBridge settings and protocol services. It does not invoke XCTest, LLDB, Device Hub, iPhone Mirroring, or system UI automation. Apple UI automation permissions remain a separate OS-controlled facility.

## Interactive flow

Run `skybridge tui`. `/devices` selects a nearby target; without a target, `/handshake` configures the Mac only. With a target it explicitly offers both devices or local scope, then lists Q-Periapt, X-Wing, ML-KEM-768 (pure PQC), and Classic. Availability is read from each selected runtime. Classic is visible and disabled under the product's strict-PQC policy. Selection uses numbered input; Enter cancels without a write.

The user chooses whether to use the configuration on the next connection or reconnect immediately. Existing session cipher suites remain distinct from saved configuration and provider read-back. `/status` shows those values independently. `/connect` uses normal USB-priority connection selection. `/send <path>` uses the existing live transfer progress and verified receiver-receipt completion path; paths containing spaces are entered as plain text, not shell code. `/revoke` revokes this Mac's persistent management grant on the selected peer.

## Script commands

```sh
skybridge crossnet handshake list --json
skybridge crossnet handshake status --to DEVICE_REF --json
skybridge crossnet handshake set xwing --scope both --to DEVICE_REF --reconnect --json
skybridge crossnet handshake set qperiapt --scope local --json
skybridge crossnet handshake revoke --to DEVICE_REF --json
```

A physical USB target does not require a same-LAN discovery record:

```sh
skybridge crossnet handshake status \
  --usb USB_UDID --peer-id PAIRED_PROTOCOL_UUID \
  --expected-fingerprint FULL_LOWERCASE_PROTOCOL_SHA256 --json
skybridge crossnet handshake set qperiapt --scope both --reconnect \
  --usb USB_UDID --peer-id PAIRED_PROTOCOL_UUID \
  --expected-fingerprint FULL_LOWERCASE_PROTOCOL_SHA256 --json
```

`--to` and `--usb` are mutually exclusive. Use `crossnet usb devices` for physical inventory. Device family, UDID, discovery names, and endpoints select a route; they never grant identity authority. An explicit USB route has no network fallback. Automatic target routing checks USB first. The Mac app's existing operator/account gate remains in force.

## Native authorization and transaction boundaries

Configuration management has its own signed request/response exchange on the existing bounded bootstrap transport. This lets already paired devices align KEM preferences even while their preferred suites differ. Only a currently trusted, pinned ML-DSA identity can use it; neither management nor suite selection enrolls a device, rotates its primary identity, or relaxes strict PQC. Public identity/configuration metadata is signed, not encrypted, on this pre-handshake channel. Files and application data still require the ordinary authenticated encrypted session.

The remote device prompts the first time with Allow once, Always allow this paired identity, or Reject. The persistent grant is stored in the app's existing Keychain service and bound to the peer UUID plus full identity fingerprint. iPhone/iPad users can revoke a device's management permission under Settings → PQC security → CLI handshake configuration management. Prompt dismissal, timeout (60 seconds), cancellation, missing storage, and invalid trust reject the change.

A status response issues a cryptographically random, single-use challenge tied to requester identity, responder fingerprint, configuration revision, and a 120-second expiry. Applies/revocations consume that challenge before asynchronous work. Challenges disappear on restart. The service retains at most 128 outstanding challenges and at most eight per peer. A signed request has a maximum 120-second validity window. Configuration applies revalidate identity, trust, permission, expiry, cancellation, revision, and busy state at the commit boundary after provider preparation.

Both-device scope checks local availability before writing remotely, then applies the remote and local settings with revision checks and provider read-back. This is an explicitly reported two-step operation, not a distributed atomic transaction. A failure after remote success leaves that result visible and does not overwrite a later local edit through an automatic rollback. Transfer activity blocks changes. Reconnection is a separate explicit step and is only reported successful when the actual authenticated session matches the selected profile.

A mutation is never automatically resent to another endpoint after an uncertain response. Management exchange waits up to 110 seconds for an apply; local IPC waits up to 180 seconds. If the connection or response is lost, inspect status before issuing another change. An older app without the management endpoint is reported unavailable rather than controlled through a hidden debugger fallback.

## Result contract

Successful `--json` responses go to stdout. Failed operations return a nonzero exit and one JSON document on stderr, with the per-device state under `report`. The result includes `local`, `remote`, `local_applied`, `remote_applied`, `partial`, errors per side, management transport, and the actual negotiated session suite/transport. A saved preference is never presented as a new handshake or file-transfer acceptance.

Validation and immutable candidate identities are retained in `Artifacts/handshake-cli-20260927/`. Unit/IPC tests, compilation, signing, installation, real device grant reuse, USB negotiation, and receiver-confirmed file transfer are separate acceptance gates. Prior small-file success on an older candidate does not establish acceptance of these new binaries.


## Physical acceptance follow-up (2026-09-27)

The initial signed candidates exposed three integration errors before successful remote configuration: provider read-back used the general factory rather than the Q-aware handshake selector; management identity validation used a raw-key hash rather than the established algorithm-bound fingerprint; native `id:UUID` identifiers needed canonicalization to the management wire UUID. The failed live operations and three failing regression cases are retained in `Artifacts/handshake-cli-20260927/acceptance-r1/`. The repairs reuse `ProtocolIdentityBinding.computeFingerprint`, validate key encoding, canonicalize only the identity wrapper, and read back the actual handshake provider. No trust records are reset. Candidate repair and physical acceptance remain separately recorded.


From CLI 0.4.0-dev.7, `/send` can show the native receiver prompt and apply an explicit file decision through a separate grant. `/approvals` inspects that permission and pending requests. See [file approval semantics and current receiver scope](cli-file-approval-contract.md); handshake-only grants do not permit file acceptance.
