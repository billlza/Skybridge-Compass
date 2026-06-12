# GitHub SSH transport policy

This repository defaults to GitHub SSH transport on Windows. The local guard still blocks accidental GitHub HTTPS pushes so ordinary `git push` does not invoke `git-remote-https.exe`, but `Scripts/push-github-gcm.ps1` is the explicit Git Credential Manager fallback when the SSH key has not been authorized yet.

## Local policy

- `origin` fetch and push URLs must be `git@github.com:billlza/Skybridge-Compass.git`.
- `core.sshCommand` must include `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes`, `UserKnownHostsFile=...`, and the workspace SSH key.
- `credential.helper` must be reset to an empty local value so normal pushes cannot silently use Git Credential Manager.
- Legacy GitHub HTTPS-to-SSH URL rewrites must be absent; they prevent the explicit GCM fallback from using HTTPS when SSH authorization is unavailable.
- `.githooks/pre-push` refuses GitHub HTTPS remotes unless `SKYBRIDGE_ALLOW_GITHUB_HTTPS_GCM=1` is set by `Scripts/push-github-gcm.ps1`.
- GitHub's Ed25519 host key must be pinned in `~/.ssh/known_hosts`.

Run the repair/check command:

```powershell
.\Scripts\ensure-github-ssh-remote.ps1
.\Scripts\verify-git-ssh-remote.ps1 -RequireConfiguredSshCommand -RequireKnownHosts -RequireCredentialHelperReset
```

Use the guarded upload command for this branch:

```powershell
.\Scripts\push-github-ssh.ps1
```

It repairs/verifies the local SSH policy, refuses accidental pushes from the wrong branch, pushes `HEAD` to `Bill/windows-portability`, and creates a verified fallback bundle if GitHub rejects the SSH key.

If GitHub rejects the SSH key but Git Credential Manager already has a writable `billlza` credential, use the guarded fallback command:

```powershell
.\Scripts\push-github-gcm.ps1
```

The fallback checks that the credential can push to `billlza/Skybridge-Compass`, verifies that the remote `Bill/windows-portability` branch is an ancestor of local `HEAD`, removes legacy HTTPS-to-SSH URL rewrites, sends the token only through an in-memory Git `extraHeader`, sets `SKYBRIDGE_ALLOW_GITHUB_HTTPS_GCM=1` for the pre-push hook, verifies the remote ref after upload, and updates the local `origin/Bill/windows-portability` tracking ref. It refuses non-fast-forward updates.

Run the remote authorization check:

```powershell
.\Scripts\verify-git-ssh-remote.ps1 -RequireConfiguredSshCommand -RequireKnownHosts -RequireCredentialHelperReset -RequireRemoteAccess
```

If the remote authorization check reports `Permission denied (publickey)`, the local transport is stable but GitHub has not authorized the SSH key.

## Required GitHub authorization

Add this public key to the GitHub account or as a repository deploy key with write access:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA5WPv1IxVRiDxqE4zjFIFSApR8nbwDpxM8c75yoeYq4 skybridge-zk-reverse-20260604
```

Key fingerprint:

```text
SHA256:PIVgx0F1G0M0RYsATcvpGavtpuql2NJYwvfpUMR9WJQ
```
