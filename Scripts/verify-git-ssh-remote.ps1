param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Remote = "origin",
    [string]$KnownHostsPath = (Join-Path $env:USERPROFILE ".ssh\known_hosts"),
    [switch]$RequireConfiguredSshCommand,
    [switch]$RequireKnownHosts,
    [switch]$RequireCredentialHelperReset,
    [switch]$RequireRemoteAccess
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$githubEd25519KnownHost = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

function Invoke-RepositoryGit {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$GitArgs
    )

    $output = & git -C $RepoRoot @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Assert-RemoteIsSsh {
    param(
        [string]$Name,
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "Git remote $Name URL is empty."
    }

    if ($Url -match '^\s*https?://') {
        throw "Git remote $Name must use SSH, not HTTPS: $Url"
    }

    if ($Url -notmatch '^\s*(git@|ssh://)') {
        throw "Git remote $Name must use an SSH URL so Windows does not invoke git-remote-https.exe: $Url"
    }
}

$fetchUrl = Invoke-RepositoryGit remote get-url $Remote
$pushUrl = Invoke-RepositoryGit remote get-url --push $Remote

Assert-RemoteIsSsh -Name "$Remote fetch" -Url $fetchUrl
Assert-RemoteIsSsh -Name "$Remote push" -Url $pushUrl

$sshCommand = (& git -C $RepoRoot config --get core.sshCommand 2>$null)
if ($LASTEXITCODE -ne 0) {
    $sshCommand = ""
}

$sshCommand = ($sshCommand -join [Environment]::NewLine).Trim()
if ($RequireConfiguredSshCommand -and [string]::IsNullOrWhiteSpace($sshCommand)) {
    throw "core.sshCommand is not configured; set it before pushing so Git uses the intended SSH key."
}

if (-not [string]::IsNullOrWhiteSpace($sshCommand)) {
    if ($sshCommand -notmatch 'BatchMode=yes') {
        throw "core.sshCommand must include BatchMode=yes to fail fast without interactive credential prompts."
    }

    if ($sshCommand -notmatch 'IdentitiesOnly=yes') {
        throw "core.sshCommand must include IdentitiesOnly=yes so Git uses the intended SSH identity."
    }

    if ($sshCommand -notmatch 'StrictHostKeyChecking=yes') {
        throw "core.sshCommand must include StrictHostKeyChecking=yes after GitHub known_hosts is pinned."
    }

    if ($sshCommand -notmatch 'UserKnownHostsFile=') {
        throw "core.sshCommand must include UserKnownHostsFile so Git uses the pinned GitHub host key file."
    }
}

if ($RequireKnownHosts) {
    if (-not (Test-Path -LiteralPath $KnownHostsPath)) {
        throw "known_hosts is missing: $KnownHostsPath"
    }

    $knownHosts = Get-Content -LiteralPath $KnownHostsPath
    if ($githubEd25519KnownHost -notin $knownHosts) {
        throw "known_hosts is missing GitHub's Ed25519 host key entry."
    }
}

if ($RequireCredentialHelperReset) {
    $localCredentialHelpers = @(& git -C $RepoRoot config --local --get-all credential.helper 2>$null)
    if ($LASTEXITCODE -ne 0 -or $localCredentialHelpers.Count -eq 0 -or $localCredentialHelpers[0] -ne "") {
        throw "credential.helper must be reset to an empty local value so Git Credential Manager cannot handle GitHub HTTPS fallback."
    }
}

if ($RequireRemoteAccess) {
    $output = & git -C $RepoRoot ls-remote --exit-code $Remote HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($output -join [Environment]::NewLine)
        if ($text -match 'Permission denied \(publickey\)') {
            throw "GitHub SSH transport is stable, but this SSH key is not authorized for $Remote. Add the public key from ~/.ssh/skybridge_zk_reverse_ed25519.pub or grant this deploy key write access."
        }

        throw $text
    }
}

Write-Output "git-ssh-remote: ok"
