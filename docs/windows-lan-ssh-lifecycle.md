# Windows Direct-LAN SSH Lifecycle Gate

This gate proves one fail-closed Mac-to-Windows SSH management path over the declared physical LAN. It is independent from the Windows reverse relay and from UU remote access. Success on one path must not be used as evidence for another path, and the scripts do not implement LAN-to-relay-to-UU fallback.

The gate is management-channel evidence only. It does not prove SkyBridge signaling, pairing, product transport, authenticated remote frames, audio, input effects, or transferred file bytes.

## Ownership boundary

The lifecycle has three source-controlled parts:

- `Scripts/register-windows-lan-ssh-access.ps1` is the Windows-local provisioning transaction. It preserves the existing relay account, validates a candidate `sshd_config`, applies only an explicitly requested configuration, firewall, and authorized-key change, validates the installed state, and rolls back on failure. Its evidence class is `private-provisioning`, and its `accepted` field is always `false`.
- `Scripts/verify-windows-lan-ssh-lifecycle.ps1` has two production modes. Elevated Windows `-ServerAudit` mode composes the registration script's active `-VerifyOnly` authority and emits a fresh private wrapper that is never accepted. Mac live mode binds that wrapper to a numeric source, target, interface, prefix, host pin, client identity, and SSH algorithm contract, then runs only a short non-administrative session audit through that exact SSH connection.
- `Scripts/test-windows-lan-ssh-lifecycle.ps1` validates the evaluator, public projection, forbidden trust fallbacks, and registration/verifier static contracts. Fixture mode can prove evaluator behavior only; fixture evidence is never accepted.

Registration, Windows server audit, and Mac live verification are deliberately separate. Neither of the two Windows-local artifacts can mark the lifecycle accepted. Only a successful Mac live verifier run can do that.

## Required topology

Live acceptance requires all of the following:

- canonical numeric Mac and Windows IPv4 addresses in the declared prefix;
- a distinct source and target;
- the declared Mac interface mapped by macOS to an active physical hardware port;
- the declared address and prefix installed on that interface;
- the numeric target routed directly through that interface, with no router next hop;
- a resolved link-layer neighbor on the same interface after the SSH connection;
- `BindAddress` and `BindInterface` fixed to that source and interface.

DNS names, `.local` aliases, proxy routes, tunnel interfaces, SSH aliases, and route substitution are not accepted. The Windows listener set must be exactly loopback plus the frozen Windows LAN address. Loopback remains available for the independently managed reverse relay account, while the LAN account is source-bound to the frozen Mac address.

## Trust bootstrap

The verifier never discovers, creates, updates, or repairs `known_hosts`. Before the first live run:

1. On the Windows machine, inspect the local ED25519 host public key with an independently controlled session:

   ```powershell
   ssh-keygen.exe -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub -E sha256
   ```

2. Compare that Windows-local digest with the value supplied to `-ExpectedWindowsHostKeyFingerprint`.
3. Through a separate, explicit provisioning step, create a durable file under the Mac account's `.ssh` directory containing exactly one active record for the numeric Windows target and an `ssh-ed25519` key. Do not derive trust from an unauthenticated network observation.
4. Independently record the Mac client identity digest from `ssh-keygen -lf <identity-file> -E sha256` and supply it through `-ExpectedIdentityKeyFingerprint`.

The verifier requires the private identity to be a non-symlink, owner-owned mode `0600` file. The durable host-pin file must be a non-symlink owned by the current user, must not be group- or world-writable, and must contain exactly one active record. Every parent from each protected file to the user-profile boundary must retain the same owner/inode chain, contain no symlink, and be neither group- nor world-writable. A second pin, an RSA pin, an alias, a different digest, or a temporary pin file fails closed.

This check is intentionally strict. If the current `.ssh` directory is mode `0720`, or another parent is group-writable, live verification fails. Review the account/group ownership implications before changing permissions; the verifier never runs `chmod` on an SSH authority path.

## Windows provisioning

Run registration in an elevated Windows PowerShell session. The LAN and relay accounts must already exist, be enabled local SAM accounts, be distinct, and be non-administrative. Registration does not create accounts, reset passwords, or change group membership.

First run preflight without changing state:

```powershell
Scripts\register-windows-lan-ssh-access.ps1 `
    -VerifyOnly `
    -LanAccountName <lan-account> `
    -RelayAccountName <relay-account> `
    -WindowsLanAddress <windows-ipv4> `
    -MacLanAddress <mac-ipv4> `
    -LanPrefixLength <prefix-length> `
    -LanInterfaceAlias <windows-physical-interface> `
    -LanAuthorizedPublicKey "ssh-ed25519 <public-key>" `
    -ExpectedLanPublicKeyFingerprint SHA256:<independent-client-key-digest> `
    -LanPublicKeyProvenanceRef <approved-key-record-reference> `
    -ExpectedWindowsHostKeyFingerprint SHA256:<independent-host-key-digest> `
    -EvidencePath <private-registration-evidence.json>
```

Apply only after the preflight inputs and reported conflicts have been reviewed:

```powershell
Scripts\register-windows-lan-ssh-access.ps1 `
    -Apply `
    -LanAccountName <lan-account> `
    -RelayAccountName <relay-account> `
    -WindowsLanAddress <windows-ipv4> `
    -MacLanAddress <mac-ipv4> `
    -LanPrefixLength <prefix-length> `
    -LanInterfaceAlias <windows-physical-interface> `
    -LanAuthorizedPublicKey "ssh-ed25519 <public-key>" `
    -ExpectedLanPublicKeyFingerprint SHA256:<independent-client-key-digest> `
    -LanPublicKeyProvenanceRef <approved-key-record-reference> `
    -ExpectedWindowsHostKeyFingerprint SHA256:<independent-host-key-digest> `
    -DisableConflictingRuleName <reviewed-rule-name> `
    -EvidencePath <private-registration-evidence.json>
```

Do not pass `-DisableConflictingRuleName` speculatively. Each name is an explicit authorization to disable one conflicting inbound rule and is included in the rollback transaction.

The SSH port is fixed at `22`. The managed `sshd` policy requires public-key authentication, disables password and keyboard-interactive authentication, disables forwarding and user-controlled environment hooks, and disables alternate authorization sources such as `AuthorizedKeysCommand`, trusted user CAs, and authorized-principals commands/files. Candidate and installed effective configurations are checked for both the LAN account and relay account. The firewall rule is bound to the signed `sshd` executable and `sshd` service as well as the exact interface, addresses, Private profile, TCP, and port.

## Fresh Windows server audit

The LAN account is intentionally non-administrative and cannot inspect SYSTEM-owned host keys, firewall filters, service configuration, or protected ACLs. Do not elevate that account and do not broaden those ACLs for remote auditing.

Immediately before Mac live verification, run the verifier in an elevated Windows PowerShell session:

```powershell
Scripts\verify-windows-lan-ssh-lifecycle.ps1 `
    -ServerAudit `
    -WindowsLanAddress <windows-ipv4> `
    -MacLanAddress <mac-ipv4> `
    -LanPrefixLength <prefix-length> `
    -WindowsLanInterfaceAlias <windows-physical-interface> `
    -WindowsAccountName <lan-account> `
    -RelayAccountName <relay-account> `
    -ExpectedWindowsAccountSid <windows-lan-account-sid> `
    -ExpectedRelayAccountSid <windows-relay-account-sid> `
    -LanAuthorizedPublicKey "ssh-ed25519 <public-key>" `
    -ExpectedIdentityKeyFingerprint SHA256:<independent-client-key-digest> `
    -LanPublicKeyProvenanceRef <approved-key-record-reference> `
    -ExpectedWindowsHostKeyFingerprint SHA256:<independent-host-key-digest> `
    -PrivateEvidencePath <private-server-audit.json>
```

`-ServerAudit` invokes the source-adjacent registration script with `-VerifyOnly`; it does not maintain a second ACL/firewall/`sshd` implementation. The registration authority requires the installed configuration to equal its validated candidate and verifies the service, Microsoft signer, executable/config/authorized-key hashes, exact keys and ACLs, two listeners, LAN and relay effective policies, and exact non-conflicting firewall rule. The wrapper adds a nonce, process-time bounds, canonical source-script hashes, and the raw private registration artifact. Its `accepted` value is always `false`.

Transfer the private wrapper to the Mac through an independently controlled path, set its mode to `0600`, and independently carry the printed whole-file SHA-256 digest. Mac live mode rejects a stale wrapper, a digest mismatch, a source-manifest mismatch, a binding mismatch, or an artifact not generated inside the recorded `-VerifyOnly` invocation. The default freshness window is five minutes.

## Live verification

Run the acceptance gate on the Mac after the durable host pin has been independently established:

```powershell
pwsh ./Scripts/verify-windows-lan-ssh-lifecycle.ps1 `
    -WindowsLanAddress <windows-ipv4> `
    -MacLanAddress <mac-ipv4> `
    -LanPrefixLength <prefix-length> `
    -MacLanInterface <mac-physical-interface> `
    -WindowsLanInterfaceAlias <windows-physical-interface> `
    -WindowsAccountName <lan-account> `
    -RelayAccountName <relay-account> `
    -ExpectedWindowsAccountSid <windows-account-sid> `
    -ExpectedRelayAccountSid <windows-relay-account-sid> `
    -LanPublicKeyProvenanceRef <approved-key-record-reference> `
    -IdentityFile <absolute-private-key-path> `
    -ExpectedIdentityKeyFingerprint SHA256:<independent-client-key-digest> `
    -KnownHostsPath <absolute-durable-pin-path> `
    -ExpectedWindowsHostKeyFingerprint SHA256:<independent-host-key-digest> `
    -ServerAuditEvidencePath <absolute-private-server-audit-path> `
    -ExpectedServerAuditSha256 <independently-carried-hex-digest> `
    -PrivateEvidencePath <private-evidence.json> `
    -PublicEvidencePath <public-evidence.json>
```

The verifier executes the equivalent of a fresh SSH configuration with all of these properties fixed:

- `-F /dev/null`;
- fixed Apple-owned absolute executables for SSH, key inspection, route/interface/ARP inspection, `stat`, `chmod`, and code-signature verification; each executable is root-owned, non-writable by group/other, and validly Apple-signed;
- numeric target, explicit port, `BindAddress`, and `BindInterface`;
- `BatchMode=yes`, `IdentitiesOnly=yes`, and `IdentityAgent=none`;
- public-key authentication only, with zero password prompts;
- `StrictHostKeyChecking=yes`, the gate-owned durable pin, no global host file, and `UpdateHostKeys=no`;
- ED25519 host and client key algorithms only;
- `KexAlgorithms=mlkem768x25519-sha256` with the negotiated algorithm verified from verbose SSH diagnostics;
- no proxy command, proxy jump, agent forwarding, port forwarding, local command, or TTY.

The remote executable is the absolute `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, whose hash and valid Microsoft signature are bound into the fresh server audit. The server-audit wrapper also requires and binds the built-in `cmd.exe` OpenSSH default-shell behavior so an arbitrary registry-selected shell cannot silently reinterpret the audit command.

The SSH remote command is read-only and deliberately non-privileged. Its script is delivered through SSH standard input, is bounded to 4 KiB, and returns an exact-field JSON record containing only:

- Windows platform presence;
- the logged-in account name and SID match;
- confirmation that the logged-in token is not administrative;
- `SSH_CONNECTION` endpoints matching the frozen Mac source, Windows target, and destination port.

Protected service, signer, listener, ACL, key, effective-policy, and firewall facts come only from the fresh, independently hashed Windows server-audit wrapper. Remote JSON is merged through an exact allowlist, so it cannot overwrite Mac route, pin, algorithm, or server-audit authority fields.

Any missing field, unexpected value, command failure, algorithm mismatch, or extra authority fails the gate. There is no downgrade or retry with a different route, credential, pin, or algorithm.

## Evidence contract

Server-audit mode writes one private artifact with restrictive Windows ACLs. It contains the registration `-VerifyOnly` artifact and source/runtime bindings, but always reports `accepted=false` and `notNetworkSessionProof=true`.

Mac live mode writes two artifacts atomically:

- Private evidence contains the frozen addresses, interfaces, account identity, paths, key digests, structured observations, and hashes of SSH diagnostics. On macOS it is written with mode `0600`.
- Public evidence contains only generic check results, failure codes, the negotiated KEX name when that check passed, the private-evidence SHA-256 digest, and proof-boundary flags. It contains no address, hostname, account name, SID, filesystem path, key fingerprint, or raw SSH diagnostic.

Both output targets must be new files under the current user's home, outside `.ssh`, distinct under case-insensitive comparison, and unable to alias a source, input, server-audit artifact, SSH key/pin, or fixed system executable. Their existing parent chains must be owner-controlled, non-writable by group/other, and free of symlinks. The verifier snapshots those parents before SSH and rechecks them before writing. Console output reports only write booleans and the private whole-file digest; it does not print absolute evidence paths.

The identity, durable pin, server-audit wrapper, physical route binding, and Apple tool manifest are also snapshotted before SSH and revalidated after the authenticated session. A byte, inode, metadata, parent-chain, route, tool, or freshness change prevents `accepted=true`.

`accepted=true` requires `mode=live`, a fresh independently hashed server audit, and every Mac route/pin/SSH/session check to pass. Server-audit and fixture modes always emit `accepted=false`, even when their own evaluation passes.

The following fields keep the management proof from being promoted into product evidence:

- `notProductTransportProof=true`
- `notRemoteFrameProof=true`
- `notInputEffectProof=true`
- `notFileTransferProof=true`

## Regression test

Run the static and evaluator suite on macOS or Windows PowerShell 7:

```powershell
pwsh -NoProfile -NonInteractive -File Scripts/test-windows-lan-ssh-lifecycle.ps1
```

The suite covers a passing two-layer evaluator fixture that remains unaccepted, route mismatch, an extra host pin, an RSA host pin, a stale or differently hashed server audit, an administrative SSH token, a failed server firewall contract (including an `Any` profile case), an `SSH_CONNECTION` mismatch, both macOS ARP output formats, public-evidence canary redaction, exact remote-field merging, forbidden trust discovery, forbidden `known_hosts` writes, Windows PowerShell 5.1 API compatibility guards, and registration rollback/source-binding contracts.

The elevated Windows `-ServerAudit` path is designed for the built-in Windows PowerShell 5.1 runtime as well as PowerShell 7. A repository-level Parser/fixture run does not replace a Windows-local runtime execution of registration `-VerifyOnly` and `-ServerAudit` against the real service, ACL, firewall, and listener state.
