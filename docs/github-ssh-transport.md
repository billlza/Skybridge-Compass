# GitHub SSH transport policy

This repository must push to GitHub over SSH on Windows. Do not use GitHub HTTPS remotes for this workspace: the local guard is intended to keep Git from invoking `git-remote-https.exe`.

## Local policy

- `origin` fetch and push URLs must be `git@github.com:billlza/Skybridge-Compass.git`.
- `core.sshCommand` must include `BatchMode=yes`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes`, `UserKnownHostsFile=...`, and the workspace SSH key.
- `credential.helper` must be reset to an empty local value so the system Git Credential Manager cannot handle a GitHub HTTPS fallback.
- GitHub HTTPS URLs are rewritten to SSH locally, and `.githooks/pre-push` refuses GitHub HTTPS remotes.
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
