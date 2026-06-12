param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SshKeyPath = $env:SKYBRIDGE_GITHUB_SSH_KEY,
    [string]$KnownHostsPath = (Join-Path $env:USERPROFILE ".ssh\known_hosts"),
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

$originSsh = "git@github.com:billlza/Skybridge-Compass.git"
$githubEd25519KnownHost = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

function Join-SshCommand {
    param([string[]]$Parts)

    return ($Parts | ForEach-Object {
        if ($_ -match "\s") {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " "
}

function Resolve-SkybridgeSshCommand {
    param(
        [string]$PreferredKeyPath,
        [string]$KnownHosts
    )

    $resolvedKnownHosts = (Resolve-Path -LiteralPath $KnownHosts -ErrorAction Stop).Path -replace "\\", "/"
    $parts = @(
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$resolvedKnownHosts")
    $keyPath = $PreferredKeyPath
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $candidateKey = Join-Path $env:USERPROFILE ".ssh\skybridge_zk_reverse_ed25519"
        if (Test-Path -LiteralPath $candidateKey) {
            $keyPath = $candidateKey
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($keyPath)) {
        $resolvedKeyPath = (Resolve-Path -LiteralPath $keyPath -ErrorAction Stop).Path -replace "\\", "/"
        $parts += @("-i", $resolvedKeyPath, "-o", "IdentitiesOnly=yes")
    }
    else {
        throw "No SSH key path configured. Set SKYBRIDGE_GITHUB_SSH_KEY or create ~/.ssh/skybridge_zk_reverse_ed25519."
    }

    return Join-SshCommand -Parts $parts
}

function Ensure-PublicKeyFile {
    param([string]$PrivateKeyPath)

    $publicKeyPath = "$PrivateKeyPath.pub"
    if (Test-Path -LiteralPath $publicKeyPath) {
        return
    }

    if ($CheckOnly) {
        throw "SSH public key file is missing: $publicKeyPath"
    }

    $publicKey = & ssh-keygen -y -f $PrivateKeyPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to derive SSH public key from $PrivateKeyPath`: $($publicKey -join [Environment]::NewLine)"
    }

    Set-Content -LiteralPath $publicKeyPath -Encoding ascii -Value (($publicKey | Select-Object -First 1) -as [string])
}

function Ensure-GitHubKnownHost {
    param([string]$Path)

    $sshDir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $sshDir)) {
        if ($CheckOnly) {
            throw "SSH directory is missing: $sshDir"
        }

        New-Item -ItemType Directory -Path $sshDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($CheckOnly) {
            throw "known_hosts is missing: $Path"
        }

        New-Item -ItemType File -Path $Path | Out-Null
    }

    $knownHosts = Get-Content -LiteralPath $Path -ErrorAction Stop
    if ($githubEd25519KnownHost -notin $knownHosts) {
        if ($CheckOnly) {
            throw "known_hosts is missing GitHub's Ed25519 host key entry."
        }

        Add-Content -LiteralPath $Path -Value $githubEd25519KnownHost
    }
}

Ensure-GitHubKnownHost -Path $KnownHostsPath
$sshCommand = Resolve-SkybridgeSshCommand -PreferredKeyPath $SshKeyPath -KnownHosts $KnownHostsPath
$resolvedPrivateKey = if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
    Join-Path $env:USERPROFILE ".ssh\skybridge_zk_reverse_ed25519"
} else {
    $SshKeyPath
}
Ensure-PublicKeyFile -PrivateKeyPath (Resolve-Path -LiteralPath $resolvedPrivateKey -ErrorAction Stop).Path

function Invoke-Git {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $output = & git -C $RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Get-ConfigValue {
    param([string]$Key)

    $value = Invoke-Git config --local --get $Key
    return (($value | Select-Object -First 1) -as [string]).Trim()
}

function Assert-Equal {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Contains {
    param(
        [string[]]$Actual,
        [string]$Expected,
        [string]$Message
    )

    if ($Expected -notin $Actual) {
        throw "$Message Missing '$Expected'."
    }
}

function Clear-LegacyGitHubHttpsRewrite {
    $legacyRewriteKeys = @(
        "url.git@github.com:billlza/Skybridge-Compass.git.insteadOf",
        "url.git@github.com:billlza/Skybridge-Compass.insteadOf",
        "url.git@github.com:.insteadOf"
    )

    foreach ($key in $legacyRewriteKeys) {
        & git -C $RepoRoot config --local --unset-all $key 2>$null
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git"))) {
    throw "RepoRoot is not a Git worktree: $RepoRoot"
}

if (-not $CheckOnly) {
    Invoke-Git remote set-url origin $originSsh | Out-Null
    Invoke-Git remote set-url --push origin $originSsh | Out-Null
    Invoke-Git config --local core.sshCommand $sshCommand | Out-Null
    Invoke-Git config --local credential.helper "" | Out-Null
    Invoke-Git config --local credential.interactive false | Out-Null
    Invoke-Git config --local core.hooksPath .githooks | Out-Null
    Clear-LegacyGitHubHttpsRewrite
}

$remoteOutput = Invoke-Git remote -v
$remoteText = $remoteOutput -join [Environment]::NewLine
if ($remoteText -match "https?://github\.com/") {
    throw "GitHub HTTPS remote is still configured. Run this script without -CheckOnly."
}

Assert-Equal -Actual (Get-ConfigValue "remote.origin.url") -Expected $originSsh -Message "origin fetch URL must use SSH."
Assert-Equal -Actual (Get-ConfigValue "remote.origin.pushurl") -Expected $originSsh -Message "origin push URL must use SSH."
Assert-Equal -Actual (Get-ConfigValue "core.sshCommand") -Expected $sshCommand -Message "core.sshCommand must force non-interactive SSH."
Assert-Equal -Actual (Get-ConfigValue "credential.interactive") -Expected "false" -Message "credential.interactive must stay disabled for this repo."
Assert-Equal -Actual (Get-ConfigValue "core.hooksPath") -Expected ".githooks" -Message "core.hooksPath must install the tracked HTTPS guard."

$localCredentialHelpers = @(& git -C $RepoRoot config --local --get-all credential.helper 2>$null)
if ($LASTEXITCODE -ne 0 -or $localCredentialHelpers.Count -eq 0 -or $localCredentialHelpers[0] -ne "") {
    throw "credential.helper must be reset to an empty local value so normal pushes cannot silently use Git Credential Manager; use Scripts/push-github-gcm.ps1 for the explicit fallback."
}

$legacyRewriteOutput = @(& git -C $RepoRoot config --local --get-regexp "^url\.git@github\.com.*\.insteadOf$" 2>$null)
if ($legacyRewriteOutput.Count -gt 0) {
    throw "Legacy GitHub HTTPS rewrite is still configured; remove it so Scripts/push-github-gcm.ps1 can use the explicit GCM fallback when SSH authorization is unavailable."
}

Write-Output "github-ssh-remote: ok"
