# Windows Stable SSH Connection Runbook

This runbook keeps Windows true-machine access repeatable. It covers the management SSH path only: Windows opens a reverse SSH tunnel to the EC2 relay, and macOS connects back through the relay alias. It does not prove SkyBridge product transport, WebRTC helper behavior, Mac AppControl acceptance, peer-trust persistence, or UI parity.

## Contract

The durable connection must be owned by Windows Task Scheduler, not by an interactive Administrator shell:

- Task name: `SkyBridgeReverseSshTunnel`
- Principal: `NT AUTHORITY\LOCAL SERVICE`
- Installed start script: `C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1`
- Private key: `C:\ProgramData\ssh\skybridge-relay-ed25519`
- Pinned known_hosts: `C:\ProgramData\ssh\skybridge-relay-known_hosts`
- Logs: `C:\ProgramData\SkyBridge\reverse-ssh-relay\logs\skybridge-relay-tunnel.log`
- Remote forward: `127.0.0.1:2222 -> 127.0.0.1:22`

Do not use an Administrator foreground `ssh.exe` process as acceptance evidence. The relay private key ACL is intentionally scoped for `LOCAL SERVICE`; interactive foreground runs can fail with OpenSSH key-permission errors even when the scheduled task setup is correct.

The relay host name, relay host key fingerprint, and expected Windows egress address are operational inputs. Verify them before registration; do not copy stale values from a previous outage into formal evidence.

## Fast Triage From macOS

Check the relay listener first:

```bash
ssh -F '<skybridge-zk-ssh-config>' -o ConnectTimeout=5 skybridge-ec2-relay \
  'ss -ltn | grep 127.0.0.1:2222'
```

If the listener exists, check Windows reachability:

```bash
ssh -F '<skybridge-zk-ssh-config>' -o ConnectTimeout=8 skybridge-zk-win \
  'cmd /c echo reverse-tunnel-ok'
```

Interpretation:

- Listener present and `reverse-tunnel-ok`: SSH management channel is available; continue over SSH.
- Listener present but Windows echo fails: debug relay alias, Windows OpenSSH service, or authentication.
- Listener absent: recover or re-register the scheduled task from Windows.

Relay-side SSH logs can explain policy failures, but they are not repository gate evidence:

```bash
ssh -F '<skybridge-zk-ssh-config>' skybridge-ec2-relay \
  "sudo journalctl -u ssh --since '10 min ago' --no-pager | tail -80"
```

If relay logs show `Permission denied (publickey)` after a network change, check whether `authorized_keys from=` still matches the current Windows egress address before changing Windows scripts.

## Windows Recovery Order

Use an elevated PowerShell session on Windows.

First inspect and start the existing task:

```powershell
schtasks /query /tn SkyBridgeReverseSshTunnel /v /fo list
schtasks /run /tn SkyBridgeReverseSshTunnel
```

If the task action points into a user-profile repo checkout, re-register from the current repository after SSH/Git is available. Runtime tasks must point to ProgramData installed artifacts so a deleted checkout, changed user profile, or LocalService ACL mismatch cannot break the tunnel.

If the only available access is remote desktop and long command input is unreliable, use a temporary ProgramData wrapper only to restore the management channel. Keep the wrapper under `C:\ProgramData\SkyBridge\reverse-ssh-relay\bin`, keep the `schtasks /tr` value short, and use root-relative PowerShell paths such as `/ProgramData/SkyBridge/...` to avoid drive-letter or backslash input issues. Replace the wrapper with the formal registration script before claiming acceptance.

## Formal Registration

Run from an elevated PowerShell session in the current repo checkout:

```powershell
Scripts\register-windows-reverse-ssh-relay-task.ps1 `
    -RepoRoot . `
    -RelayHostName <relay-host> `
    -RelayUserName ubuntu `
    -ExpectedRelayHostKeyFingerprint SHA256:<relay-host-key> `
    -IdentityFile C:\ProgramData\ssh\skybridge-relay-ed25519 `
    -KnownHostsPath C:\ProgramData\ssh\skybridge-relay-known_hosts `
    -InstalledStartScriptPath C:\ProgramData\SkyBridge\reverse-ssh-relay\bin\start-windows-reverse-ssh-relay.ps1 `
    -RepairPrivateKeyAcl `
    -StartAfterRegister `
    -EvidencePath artifacts\reverse-relay-smoke\windows-reverse-ssh-relay-register.json
```

Registration must:

- pin the relay host key from `ExpectedRelayHostKeyFingerprint`;
- install the source-controlled start script into ProgramData;
- verify source and installed script SHA-256 hashes match;
- keep the script directory read/execute-only for `LOCAL SERVICE`;
- keep logs in the separate ProgramData logs directory;
- set private key and known_hosts ACLs explicitly;
- register a non-interactive, least-privilege scheduled task.

Relay-side `authorized_keys` policy is separate server evidence. The relay key should be constrained with `restrict`, `port-forwarding`, `from="<expected-windows-source>"`, and `permitlisten="127.0.0.1:2222"`. A missing or wildcard relay policy is not fixed by local lifecycle evidence.

Registration and lifecycle JSON can include local paths, task arguments, and topology details. Treat those artifacts as sensitive diagnostics when sharing outside the development machine. Prefer reporting the accepted booleans, SIDs, fingerprints, hashes, and bounded path summaries.

## Required Validation

Run PowerShell parse validation on the Windows machine:

```powershell
$files = @(
  'Scripts/start-windows-reverse-ssh-relay.ps1',
  'Scripts/register-windows-reverse-ssh-relay-task.ps1',
  'Scripts/verify-windows-reverse-ssh-relay-lifecycle.ps1',
  'Scripts/verify-windows-portability-smoke.ps1',
  'Scripts/verify-windows-portability-acceptance-map.ps1',
  'Scripts/verify-windows-portability-acceptance-evidence.ps1',
  'Scripts/verify-windows-ffi-client.ps1',
  'Scripts/audit-windows-portability-completion.ps1',
  'Scripts/verify-windows-ci-workflow.ps1'
)
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) > $null
  if ($errors.Count) { throw "$file parse failed: $($errors.Message -join '; ')" }
}
```

If macOS has no `pwsh` or `powershell`, local text checks are not PowerShell validation. Use macOS for OpenSSH relay probes and run Windows PowerShell 5.1 on the Windows host once `skybridge-zk-win` is reachable. Do not substitute a WindowsApps `pwsh.exe` path if the SSH service account reports `Access denied`.

Run repository static gates:

```powershell
Scripts\verify-windows-ci-workflow.ps1
Scripts\verify-windows-portability-acceptance-map.ps1 -RepoRoot .
Scripts\verify-windows-ffi-client.ps1 -RepoRoot .
```

Run live lifecycle verification:

```powershell
Scripts\verify-windows-reverse-ssh-relay-lifecycle.ps1 `
    -RepoRoot . `
    -ExpectedRelayHostKeyFingerprint SHA256:<relay-host-key> `
    -EvidencePath artifacts\reverse-relay-smoke\windows-reverse-ssh-relay-lifecycle.json `
    -RequireRunning
```

Run the required portability smoke and acceptance evidence only after the lifecycle gate passes:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RepoRoot . `
    -CiMode `
    -RequireWindowsReverseSshRelayLifecycle `
    -WindowsReverseSshRelayExpectedHostKeyFingerprint SHA256:<relay-host-key> `
    -WindowsReverseSshRelayEvidencePath artifacts\reverse-relay-smoke\windows-reverse-ssh-relay-lifecycle.json `
    -AcceptanceEvidencePath artifacts\reverse-relay-smoke\windows-portability-acceptance-required.json

Scripts\verify-windows-portability-acceptance-evidence.ps1 `
    -AcceptanceEvidencePath artifacts\reverse-relay-smoke\windows-portability-acceptance-required.json `
    -RequireWindowsReverseSshRelayLifecycle `
    -WindowsReverseSshRelayEvidencePath artifacts\reverse-relay-smoke\windows-reverse-ssh-relay-lifecycle.json
```

Finish with the Mac-side reachability proof:

```bash
ssh -F '<skybridge-zk-ssh-config>' skybridge-zk-win 'cmd /c echo reverse-tunnel-ok'
```

## Failure Routing

- `ss -ltn` has no `127.0.0.1:2222`: the reverse tunnel is not established; inspect the Windows scheduled task and relay-side SSH policy.
- Task last result is non-zero: read Task Scheduler action, principal, and the ProgramData log path. Do not mask it with a foreground admin `ssh.exe`.
- `Bad permissions` or `UNPROTECTED PRIVATE KEY FILE`: verify whether the command is running under the intended account. The key should be usable by `LOCAL SERVICE`, not broad interactive users.
- Host key mismatch: stop and verify the relay host identity. Do not use `accept-new`, overwrite known_hosts by hand, or continue with an unpinned host.
- Relay-side `from=` or `permitlisten=` mismatch: fix relay policy and rerun Windows registration/verification; do not loosen host-key or task checks to compensate.
- Lifecycle verification fails but Mac echo works: the management path may be reachable, but the durable lifecycle contract is not accepted.

## Claim Boundaries

Keep proof names precise:

- EC2 listener proof: reverse-forward socket exists.
- Mac echo proof: macOS can reach Windows management SSH through the relay.
- Lifecycle proof: pinned host key, LocalService task, installed script hash/ACL, local sshd, and one live fail-closed process.
- Portability smoke: selected repository gates passed for the current branch/head.
- Product proof: WebRTC/AppControl/peer-trust/UI gates passed separately.

Stable SSH acceptance requires lifecycle evidence with `accepted=true`, `requireRunning=true`, and exactly one matching `ssh.exe` owned by LocalService. `-IncludeWindowsReverseSshRelayLifecycle` is diagnostic; `-RequireWindowsReverseSshRelayLifecycle` is the acceptance path.

Do not flatten these into one "Windows interop passed" statement.
