# Windows OpenSSH PQ KEX Gate

This document is the local co-debug SSH evidence contract. It proves only that the Windows OpenSSH service can negotiate a post-quantum or hybrid SSH key exchange for the SSH management channel. It is not SkyBridge product transport evidence and it must not be used as a substitute for WebRTC helper, WinClient runtime, Mac product AppControl, or peer-trust persistence proof.

## Scope

The gate covers:

- local OpenSSH client support for `mlkem768x25519-sha256`, `sntrup761x25519-sha512`, or `sntrup761x25519-sha512@openssh.com`.
- pinned Windows SSH host key fingerprint before any KEX evidence is accepted; scanned host key records that do not match the expected fingerprint must not be written to the temporary `known_hosts` file used for the proof connection.
- forced PQ-only SSH negotiation with `KexAlgorithms=<pq-only-list>`.
- actual negotiated algorithm from `ssh -vvv`, not only version strings or config text.

The gate does not cover:

- SkyBridge WebRTC DataChannel proof.
- WinClient product runtime composition.
- Mac product AppControl ping/pong.
- peer trust persistence.
- relay key policy. Relay policy must be checked separately with `restrict`, `port-forwarding`, and `permitlisten` negative tests.

## Current Upgrade Path

Windows in-box OpenSSH can lag behind GitHub Win32-OpenSSH. When the server does not advertise PQ/hybrid KEX in `ssh -Q kex` or `sshd -T`, use the Microsoft documented upgrade path:

1. Confirm an alternate access path exists because upgrading temporarily stops `sshd`.
2. Back up `C:\ProgramData\ssh`, including `sshd_config`, `administrators_authorized_keys`, and `ssh_host_*_key`.
3. Install the signed Win32-OpenSSH GitHub release MSI or ZIP.
4. Verify `sshd` points to `C:\Program Files\OpenSSH\sshd.exe` or the current GitHub install path.
5. Verify `ssh -Q kex` and `sshd -T` include `mlkem768x25519-sha256` or `sntrup761x25519-sha512`.
6. Prove actual negotiation with `Scripts\verify-openssh-pq-kex.ps1`.

Win32-OpenSSH `10.0.0.0p2-Preview` is explicitly a preview release. Treat it as a local co-debug hardening choice unless a later stable release is approved for production use.

## Required Evidence Command

Run from a client that can reach the Windows `sshd` service:

```powershell
Scripts\verify-openssh-pq-kex.ps1 `
    -HostName <windows-host> `
    -UserName <windows-ssh-user> `
    -ExpectedHostKeyFingerprint <SHA256:...> `
    -IdentityFile <private-key> `
    -EvidencePath artifacts\openssh-pq-kex.json
```

If the client cannot authenticate but the goal is only to prove the server negotiated PQ/hybrid KEX before authentication, use:

```powershell
Scripts\verify-openssh-pq-kex.ps1 `
    -HostName localhost `
    -ExpectedHostKeyFingerprint <SHA256:...> `
    -AllowAuthenticationFailureAfterKex `
    -EvidencePath artifacts\openssh-pq-kex-localhost.json
```

Passing evidence requires:

- `hostKeyPinned=true`.
- `pinnedKnownHostsRecordCount` greater than zero and `pinnedHostKeyFingerprints` containing only the expected fingerprint accepted for the proof connection.
- `negotiatedKexAlgorithm` equals one of the required PQ/hybrid algorithms.
- command success, unless `-AllowAuthenticationFailureAfterKex` is explicitly used and the log shows KEX completed before public-key authentication failure.
- no fallback to `curve25519`, ECDH, or DH.

## Product Proof Boundary

After OpenSSH PQ KEX is fixed, WebRTC status is still separate:

- helper data plane: `Scripts\verify-windows-mac-webrtc-helper-live.ps1`, then `Scripts\verify-windows-webrtc-proof.ps1` and `Scripts\verify-rust-webrtc-proof-cli.ps1`.
- WinClient runtime transport path: `Scripts\verify-windows-mac-webrtc-session-live.ps1 -UseWindowsProductRuntime`.
- Mac product AppControl: `Scripts\verify-windows-current-path-product-control-appcontrol-live.ps1`.
- peer trust persistence: not yet proven by the helper proof; it needs explicit trusted-peer persistence evidence.

Do not mark the product WebRTC objective complete from OpenSSH PQ KEX evidence alone.

## Sources

- OpenSSH post-quantum cryptography notes: https://www.openssh.org/pq.html
- Win32-OpenSSH release `10.0.0.0p2-Preview`: https://github.com/PowerShell/Win32-OpenSSH/releases/tag/10.0.0.0p2-Preview
- Microsoft OpenSSH upgrade guide: https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/upgrade-in-box-openssh-to-latest-openssh-release
