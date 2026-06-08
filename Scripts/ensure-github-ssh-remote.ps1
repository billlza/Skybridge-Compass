param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SshKeyPath = $env:SKYBRIDGE_GITHUB_SSH_KEY,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

$originSsh = "git@github.com:billlza/Skybridge-Compass.git"

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
    param([string]$PreferredKeyPath)

    $parts = @("ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new")
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

    return Join-SshCommand -Parts $parts
}

$sshCommand = Resolve-SkybridgeSshCommand -PreferredKeyPath $SshKeyPath

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

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git"))) {
    throw "RepoRoot is not a Git worktree: $RepoRoot"
}

if (-not $CheckOnly) {
    Invoke-Git remote set-url origin $originSsh | Out-Null
    Invoke-Git remote set-url --push origin $originSsh | Out-Null
    Invoke-Git config --local core.sshCommand $sshCommand | Out-Null
    Invoke-Git config --local credential.interactive false | Out-Null
    Invoke-Git config --local core.hooksPath .githooks | Out-Null
    Invoke-Git config --local url.git@github.com:billlza/Skybridge-Compass.git.insteadOf https://github.com/billlza/Skybridge-Compass.git | Out-Null
    Invoke-Git config --local url.git@github.com:billlza/Skybridge-Compass.insteadOf https://github.com/billlza/Skybridge-Compass | Out-Null
    Invoke-Git config --local url.git@github.com:.insteadOf https://github.com/ | Out-Null
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

$repoRewriteGit = Invoke-Git config --local --get-all url.git@github.com:billlza/Skybridge-Compass.git.insteadOf
$repoRewriteNoGit = Invoke-Git config --local --get-all url.git@github.com:billlza/Skybridge-Compass.insteadOf
$githubRewrite = Invoke-Git config --local --get-all url.git@github.com:.insteadOf

Assert-Contains -Actual $repoRewriteGit -Expected "https://github.com/billlza/Skybridge-Compass.git" -Message "Exact .git GitHub HTTPS rewrite must be present."
Assert-Contains -Actual $repoRewriteNoGit -Expected "https://github.com/billlza/Skybridge-Compass" -Message "Exact GitHub HTTPS rewrite must be present."
Assert-Contains -Actual $githubRewrite -Expected "https://github.com/" -Message "Broad GitHub HTTPS rewrite must be present."

Write-Output "github-ssh-remote: ok"
