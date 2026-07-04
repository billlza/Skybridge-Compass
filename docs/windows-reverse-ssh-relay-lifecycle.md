# Windows Reverse SSH Relay Lifecycle Gate

This gate proves the Windows OpenSSH reverse relay used for remote co-debugging is task-owned, pinned, and fail-closed. It is management-channel evidence only. It does not satisfy WebRTC helper proof, WinClient runtime transport proof, Mac product AppControl acceptance, or peer-trust persistence.

## Boundary

The lifecycle is split into three scripts:

- `Scripts/start-windows-reverse-ssh-relay.ps1` runs one foreground `ssh.exe` process with a fixed remote forward. It does not restart itself.
- `Scripts/register-windows-reverse-ssh-relay-task.ps1` pins the relay host key, tightens file ACLs, installs a task-owned copy of the start script under `C:\ProgramData\SkyBridge\reverse-ssh-relay\bin`, registers the Task Scheduler owner, and can optionally start the task.
- `Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1` verifies the task, pinned host key, private key ACL, known_hosts ACL, installed start-script hash and ACL, local sshd endpoint, fail-closed task action, and optional live process owner evidence.

Task Scheduler owns restart policy. The start script exits with the native SSH exit code, and `ExitOnForwardFailure=yes` makes port conflicts or relay policy failures visible.

This mirrors the macOS acceptance style used elsewhere in SkyBridge: source-controlled scripts define the contract, runtime-owned installed artifacts are verified by hash, and live process acceptance is separate from product transport acceptance.

## Required Security Properties

The relay connection must use explicit OpenSSH options:

- `-F none`
- `BatchMode=yes`
- `PreferredAuthentications=publickey`
- `IdentitiesOnly=yes`
- `IdentityAgent=none`
- `PasswordAuthentication=no`
- `KbdInteractiveAuthentication=no`
- `NumberOfPasswordPrompts=0`
- `StrictHostKeyChecking=yes`
- `UserKnownHostsFile=<gate-owned-known-hosts>`
- `UpdateHostKeys=no`
- `ExitOnForwardFailure=yes`

`accept-new`, password authentication, global SSH config reliance, and unpinned host keys are not accepted.

The scheduled task defaults to `NT AUTHORITY\LOCAL SERVICE` with least privilege. Verification requires the task principal SID to remain `S-1-5-19` and the run level to remain `Limited`. The private key must be readable only by `SYSTEM`, `BUILTIN\Administrators`, and the task service account; write/delete/ownership permissions are restricted to `SYSTEM` and `BUILTIN\Administrators`. If local provisioning left broader ACLs, registration fails unless the operator explicitly passes `-RepairPrivateKeyAcl`.

The known_hosts file is rewritten to the scanned record matching `ExpectedRelayHostKeyFingerprint` and then made read-only for the task account. Verification requires that file to contain only the expected pinned fingerprint. The installed script directory is read/execute-only for the task account. The log directory is separate from both `C:\ProgramData\ssh` and the installed script directory so the task account does not need write access to the private key directory or its executable script.

Relay-side `authorized_keys` policy is separate server evidence. The key used by this gate should be restricted on the relay host with `restrict`, `port-forwarding`, `from="<expected-windows-source>"`, and `permitlisten="127.0.0.1:2222"`. Missing or wildcard relay-side policy is not covered by local Task Scheduler evidence.

## Registration

Run registration from an elevated PowerShell session:

```powershell
Scripts\register-windows-reverse-ssh-relay-task.ps1 `
    -RelayHostName 54.92.79.99 `
    -RelayUserName ubuntu `
    -ExpectedRelayHostKeyFingerprint SHA256:<relay-host-key> `
    -IdentityFile C:\ProgramData\ssh\skybridge-relay-ed25519 `
    -KnownHostsPath C:\ProgramData\ssh\skybridge-relay-known_hosts `
    -InstalledStartScriptPath C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1 `
    -EvidencePath artifacts\windows-reverse-ssh-relay-register.json
```

If the private key exists but has wider read ACLs from manual provisioning, rerun with `-RepairPrivateKeyAcl` after confirming the key is the intended relay key:

```powershell
Scripts\register-windows-reverse-ssh-relay-task.ps1 `
    -RelayHostName 54.92.79.99 `
    -RelayUserName ubuntu `
    -ExpectedRelayHostKeyFingerprint SHA256:<relay-host-key> `
    -IdentityFile C:\ProgramData\ssh\skybridge-relay-ed25519 `
    -KnownHostsPath C:\ProgramData\ssh\skybridge-relay-known_hosts `
    -InstalledStartScriptPath C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1 `
    -RepairPrivateKeyAcl `
    -StartAfterRegister `
    -EvidencePath artifacts\windows-reverse-ssh-relay-register.json
```

## Verification

Local task lifecycle verification:

```powershell
Scripts\verify-windows-reverse-ssh-relay-lifecycle.ps1 `
    -ExpectedRelayHostKeyFingerprint SHA256:<relay-host-key> `
    -EvidencePath artifacts\windows-reverse-ssh-relay-lifecycle.json `
    -RequireRunning
```

Repository smoke keeps this local-only by default. Opt in when the Windows machine owns the task:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -IncludeWindowsReverseSshRelayLifecycle `
    -WindowsReverseSshRelayExpectedHostKeyFingerprint SHA256:<relay-host-key> `
    -WindowsReverseSshRelayEvidencePath artifacts\windows-reverse-ssh-relay-lifecycle.json `
    -AcceptanceEvidencePath artifacts\windows-portability-acceptance.json
```

Use `-RequireWindowsReverseSshRelayLifecycle` when the relay must be running and part of the acceptance package.

Mac-side reachability through the relay is a separate proof. A successful command such as:

```bash
ssh -F ~/.ssh/config skybridge-zk-win "cmd /c echo reverse-tunnel-ok"
```

proves the management path can reach Windows through the relay alias, but it still does not prove product WebRTC/AppControl acceptance.

## Evidence Contract

`verify-windows-reverse-ssh-relay-lifecycle.ps1` writes JSON with these fields:

- `taskName`
- `taskState`
- `taskActionExpected`
- `taskActionFailClosed`
- `taskPrincipalExpected`
- `expectedRelayHostKeyFingerprint`
- `relayHostKeyPinned`
- `identityFileAclOk`
- `knownHostsAclOk`
- `installedStartScriptAclOk`
- `sourceStartScriptPath`
- `installedStartScriptPath`
- `sourceStartScriptSha256`
- `installedStartScriptSha256`
- `startScriptInstalledAndCurrent`
- `runtimeAclOk`
- `localSshEndpointReachable`
- `remoteForward`
- `sshProcessCount`
- `sshProcessOwnerExpected`
- `requireRunning`
- `accepted`

The evidence records command-line hashes for matching `ssh.exe` processes, not raw SSH process command lines.
