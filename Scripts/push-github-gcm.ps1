param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Repository = "billlza/Skybridge-Compass",
    [string]$TargetBranch = "Bill/windows-portability",
    [switch]$CheckOnly,
    [switch]$AllowDifferentCurrentBranch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Join-ProcessArguments {
    param([string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " "
}

function Invoke-NativeProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [hashtable]$Environment = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $textParts = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $textParts += $stdout.TrimEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $textParts += $stderr.TrimEnd()
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text = ($textParts -join [Environment]::NewLine)
    }
}

function Invoke-GitRaw {
    param([string[]]$Arguments, [hashtable]$Environment = @{})

    return Invoke-NativeProcess -FilePath "git" -Arguments (@("-C", $RepoRoot) + $Arguments) -Environment $Environment
}

function Get-GitText {
    param([string[]]$Arguments)

    $result = Invoke-GitRaw -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw $result.Text
    }

    return $result.Text.Trim()
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

function Get-GitHubCredential {
    $credentialInput = "protocol=https`nhost=github.com`n`n"
    $credentialOutput = $credentialInput | git credential-manager get
    if ($LASTEXITCODE -ne 0) {
        throw "Git Credential Manager did not return a GitHub credential."
    }

    $fields = @{}
    foreach ($line in $credentialOutput) {
        if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
            $fields[$Matches.key] = $Matches.value
        }
    }

    $username = [string]$fields["username"]
    $password = [string]$fields["password"]
    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = "x-access-token"
    }

    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "Git Credential Manager has no GitHub token for https://github.com."
    }

    return [pscustomobject]@{
        Username = $username
        Token = $password
    }
}

function New-GitHubHeaders {
    param([string]$Token)

    return @{
        "User-Agent" = "SkyBridge-GCM-Push"
        "Authorization" = "Bearer $Token"
        "Accept" = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "Cache-Control" = "no-cache"
    }
}

function Get-GitHubRef {
    param(
        [string]$Token,
        [string]$Branch
    )

    $headers = New-GitHubHeaders -Token $Token
    $uri = "https://api.github.com/repos/$Repository/git/ref/heads/$Branch"
    return Invoke-RestMethod -Headers $headers -Uri $uri
}

function Assert-GitHubWriteAccess {
    param([string]$Token)

    $headers = New-GitHubHeaders -Token $Token
    $viewer = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/user"
    $repo = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository"

    if (-not $repo.permissions.push) {
        throw "GitHub credential '$($viewer.login)' does not have push access to $Repository."
    }

    return [pscustomobject]@{
        Login = [string]$viewer.login
        FullName = [string]$repo.full_name
    }
}

function New-BasicAuthHeader {
    param(
        [string]$Username,
        [string]$Token
    )

    $raw = "${Username}:${Token}"
    return "AUTHORIZATION: Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($raw)))"
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git"))) {
    throw "RepoRoot is not a Git worktree: $RepoRoot"
}

$currentBranch = Get-GitText -Arguments @("branch", "--show-current")
if (-not $AllowDifferentCurrentBranch -and $currentBranch -ne $TargetBranch) {
    throw "Current branch is '$currentBranch', expected '$TargetBranch'. Pass -AllowDifferentCurrentBranch only for an intentional cross-branch push."
}

$head = Get-GitText -Arguments @("rev-parse", "HEAD")
$credential = Get-GitHubCredential
$access = Assert-GitHubWriteAccess -Token $credential.Token
$remoteRef = Get-GitHubRef -Token $credential.Token -Branch $TargetBranch
$remoteSha = [string]$remoteRef.object.sha

$ancestorCheck = Invoke-GitRaw -Arguments @("merge-base", "--is-ancestor", $remoteSha, $head)
if ($ancestorCheck.ExitCode -ne 0) {
    throw "Remote branch $Repository/$TargetBranch at $remoteSha is not an ancestor of local HEAD $head; refusing non-fast-forward push."
}

if ($CheckOnly) {
    Write-Output "github-gcm-push: check ok auth=$($access.Login) repo=$($access.FullName) branch=$TargetBranch remote=$remoteSha local=$head fast-forward=true"
    exit 0
}

Clear-LegacyGitHubHttpsRewrite

$remoteUrl = "https://github.com/$Repository.git"
$environment = @{
    "GIT_TERMINAL_PROMPT" = "0"
    "GIT_CONFIG_COUNT" = "2"
    "GIT_CONFIG_KEY_0" = "http.https://github.com/.extraheader"
    "GIT_CONFIG_VALUE_0" = (New-BasicAuthHeader -Username $credential.Username -Token $credential.Token)
    "GIT_CONFIG_KEY_1" = "credential.helper"
    "GIT_CONFIG_VALUE_1" = ""
    "SKYBRIDGE_ALLOW_GITHUB_HTTPS_GCM" = "1"
}

$push = Invoke-GitRaw -Arguments @("push", $remoteUrl, "HEAD:refs/heads/$TargetBranch") -Environment $environment
if ($push.ExitCode -ne 0) {
    throw $push.Text
}

$verify = Invoke-GitRaw -Arguments @("ls-remote", $remoteUrl, "refs/heads/$TargetBranch") -Environment $environment
if ($verify.ExitCode -ne 0) {
    throw $verify.Text
}

$verifiedSha = (($verify.Text -split "\s+") | Select-Object -First 1)
if ($verifiedSha -ne $head) {
    throw "GitHub verification mismatch after push. Expected $head, got $verifiedSha."
}

Invoke-GitRaw -Arguments @("update-ref", "refs/remotes/origin/$TargetBranch", $head) | Out-Null

if (-not [string]::IsNullOrWhiteSpace($push.Text)) {
    Write-Output $push.Text
}

Write-Output "github-gcm-push: ok auth=$($access.Login) repo=$($access.FullName) branch=$TargetBranch head=$head"
