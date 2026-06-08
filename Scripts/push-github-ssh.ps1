param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Remote = "origin",
    [string]$TargetBranch = "Bill/windows-portability",
    [string]$KnownHostsPath = (Join-Path $env:USERPROFILE ".ssh\known_hosts"),
    [string]$BundleDirectory = (Resolve-Path (Join-Path $RepoRoot "..")).Path,
    [switch]$CheckOnly,
    [switch]$AllowDifferentCurrentBranch,
    [switch]$NoBundleOnFailure
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-RepositoryGit {
    param([string[]]$Arguments)

    $output = & git -C $RepoRoot @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join [Environment]::NewLine).Trim()
    }
}

function Get-RepositoryGitText {
    param([string[]]$Arguments)

    $result = Invoke-RepositoryGit -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw $result.Text
    }

    return $result.Text
}

function Test-RepositoryGitRef {
    param([string]$Ref)

    $result = Invoke-RepositoryGit -Arguments @("rev-parse", "--verify", "--quiet", $Ref)
    return $result.ExitCode -eq 0
}

function Get-SkybridgePublicKeyPath {
    $keyPath = $env:SKYBRIDGE_GITHUB_SSH_KEY
    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $keyPath = Join-Path $env:USERPROFILE ".ssh\skybridge_zk_reverse_ed25519"
    }

    return "$keyPath.pub"
}

function New-PushFallbackBundle {
    if (-not (Test-Path -LiteralPath $BundleDirectory)) {
        New-Item -ItemType Directory -Path $BundleDirectory | Out-Null
    }

    $shortSha = Get-RepositoryGitText -Arguments @("rev-parse", "--short", "HEAD")
    $safeBranchName = $TargetBranch -replace "[^A-Za-z0-9._-]+", "-"
    $bundlePath = Join-Path $BundleDirectory "$safeBranchName-$shortSha.bundle"
    $remoteBranchRef = "refs/remotes/$Remote/$TargetBranch"
    $bundleArgs = @("bundle", "create", $bundlePath, "HEAD")

    if (Test-RepositoryGitRef -Ref $remoteBranchRef) {
        $aheadCountText = Get-RepositoryGitText -Arguments @("rev-list", "--count", "$remoteBranchRef..HEAD")
        $aheadCount = [int]$aheadCountText
        if ($aheadCount -gt 0) {
            $bundleArgs += "^$remoteBranchRef"
        }
    }

    $createResult = Invoke-RepositoryGit -Arguments $bundleArgs
    if ($createResult.ExitCode -ne 0) {
        throw $createResult.Text
    }

    $verifyResult = Invoke-RepositoryGit -Arguments @("bundle", "verify", $bundlePath)
    if ($verifyResult.ExitCode -ne 0) {
        throw $verifyResult.Text
    }

    return [pscustomobject]@{
        Path = $bundlePath
        Verification = $verifyResult.Text
    }
}

$ensureScript = Join-Path $PSScriptRoot "ensure-github-ssh-remote.ps1"
$verifyScript = Join-Path $PSScriptRoot "verify-git-ssh-remote.ps1"

if ($CheckOnly) {
    & $ensureScript -RepoRoot $RepoRoot -KnownHostsPath $KnownHostsPath -CheckOnly | Write-Output
}
else {
    & $ensureScript -RepoRoot $RepoRoot -KnownHostsPath $KnownHostsPath | Write-Output
}

& $verifyScript `
    -RepoRoot $RepoRoot `
    -Remote $Remote `
    -KnownHostsPath $KnownHostsPath `
    -RequireConfiguredSshCommand `
    -RequireKnownHosts `
    -RequireCredentialHelperReset | Write-Output

$currentBranch = Get-RepositoryGitText -Arguments @("branch", "--show-current")
if (-not $AllowDifferentCurrentBranch -and $currentBranch -ne $TargetBranch) {
    throw "Current branch is '$currentBranch', expected '$TargetBranch'. Pass -AllowDifferentCurrentBranch only for an intentional cross-branch push."
}

if ($CheckOnly) {
    Write-Output "github-ssh-push: check ok ($currentBranch -> $Remote/$TargetBranch)"
    exit 0
}

$pushResult = Invoke-RepositoryGit -Arguments @("push", $Remote, "HEAD:$TargetBranch")
if ($pushResult.ExitCode -eq 0) {
    Write-Output $pushResult.Text
    Write-Output "github-ssh-push: ok ($currentBranch -> $Remote/$TargetBranch)"
    exit 0
}

if ($pushResult.Text -match "Permission denied \(publickey\)") {
    $publicKeyPath = Get-SkybridgePublicKeyPath
    Write-Output "github-ssh-push: GitHub rejected the configured SSH key."
    Write-Output "github-ssh-push: local transport stayed on SSH; git-remote-https.exe was not used."
    Write-Output "github-ssh-push: authorize this public key in GitHub, then rerun this script: $publicKeyPath"

    if (Test-Path -LiteralPath $publicKeyPath) {
        Write-Output (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
    }

    if (-not $NoBundleOnFailure) {
        $bundle = New-PushFallbackBundle
        Write-Output "github-ssh-push: fallback bundle created: $($bundle.Path)"
        Write-Output $bundle.Verification
    }

    exit 2
}

throw $pushResult.Text
