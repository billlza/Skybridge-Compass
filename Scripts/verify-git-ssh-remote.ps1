param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Remote = "origin",
    [switch]$RequireConfiguredSshCommand
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
}

Write-Output "git-ssh-remote: ok"
