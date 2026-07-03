param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$AcceptanceEvidencePath = "artifacts/windows-portability/latest-local/windows-portability-acceptance.json",
    [string]$RustCliCoverageEvidencePath = "artifacts/windows-portability/latest-local/rust-cli-coverage.json",
    [string]$StackFreshnessEvidencePath = "artifacts/windows-portability/latest-local/windows-stack-freshness.json",
    [string]$WinUiEvidenceDir = "",
    [switch]$AllowStandaloneWinUiVisualEvidence,
    [string]$MacSshEvidencePath = "",
    [string]$ReportPath = "",
    [string]$ExpectedBranch = "Bill/windows-portability",
    [string]$ExpectedHead = "",
    [string]$GitHubRepository = "billlza/Skybridge-Compass",
    [switch]$CheckRemoteBranch,
    [switch]$AllowGitHubApiRemoteCheck,
    [switch]$RequireComplete
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Resolve-RepoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $RepoRoot $Path))
}

function Get-GitText {
    param([string[]]$Arguments)

    $output = & git -C $RepoRoot @Arguments 2>$null
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "git $($Arguments -join ' ') failed."
    return (($output | Select-Object -First 1) -as [string])
}

function Get-Gate {
    param(
        $Acceptance,
        [string]$Name
    )

    $matches = @($Acceptance.gateResults | Where-Object { [string]$_.name -eq $Name })
    Assert-True -Condition ($matches.Count -eq 1) -Message "Expected exactly one acceptance gate named $Name, found $($matches.Count)."
    return $matches[0]
}

function Test-GatePassed {
    param(
        $Acceptance,
        [string]$Name
    )

    $gate = Get-Gate -Acceptance $Acceptance -Name $Name
    return ([string]$gate.status -eq "passed")
}

function Add-AuditItem {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [string]$Id,
        [string]$Status,
        [string]$Evidence,
        [string]$Gap = ""
    )

    $Items.Add([ordered]@{
        id = $Id
        status = $Status
        evidence = $Evidence
        gap = $Gap
    })
}

function Invoke-GitRaw {
    param([string[]]$Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "git"
    $startInfo.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " "
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

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

function Get-RemoteBranchHead {
    param(
        [string]$Branch,
        [string]$Repository,
        [switch]$AllowGitHubApiFallback
    )

    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $previousSsh = $env:GIT_SSH_COMMAND
    try {
        $env:GIT_TERMINAL_PROMPT = "0"
        if ([string]::IsNullOrWhiteSpace($env:GIT_SSH_COMMAND)) {
            $env:GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o ConnectTimeout=5"
        }

        $remoteProbeDetail = "ls-remote --heads origin $Branch"
        $remoteResult = Invoke-GitRaw -Arguments @("ls-remote", "--heads", "origin", $Branch)
        if ($remoteResult.ExitCode -ne 0) {
            $sshDetail = ($remoteProbeDetail + [Environment]::NewLine + $remoteResult.Text).Trim()
            if ($AllowGitHubApiFallback) {
                return Get-GitHubApiBranchHead -Branch $Branch -Repository $Repository -SshDetail $sshDetail
            }

            return [ordered]@{
                status = "unavailable"
                head = ""
                detail = $sshDetail
            }
        }

        $line = (($remoteResult.Text -split "\r?\n") | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($line)) {
            return [ordered]@{
                status = "missing"
                head = ""
                detail = "Remote branch was not returned by git ls-remote."
            }
        }

        return [ordered]@{
            status = "available"
            head = ($line -split "\s+")[0]
            detail = $line
        }
    }
    finally {
        $env:GIT_TERMINAL_PROMPT = $previousPrompt
        $env:GIT_SSH_COMMAND = $previousSsh
    }
}

function Get-GitHubApiBranchHead {
    param(
        [string]$Branch,
        [string]$Repository,
        [string]$SshDetail
    )

    try {
        $headers = @{
            "User-Agent" = "SkyBridge-Completion-Audit"
            "Accept" = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
            "Cache-Control" = "no-cache"
        }
        $uri = "https://api.github.com/repos/$Repository/git/ref/heads/$Branch"
        $ref = Invoke-RestMethod -Headers $headers -Uri $uri
        return [ordered]@{
            status = "available"
            head = [string]$ref.object.sha
            detail = "GitHub API fallback verified refs/heads/$Branch after SSH ls-remote failed: $SshDetail"
        }
    }
    catch {
        return [ordered]@{
            status = "unavailable"
            head = ""
            detail = "SSH ls-remote failed: $SshDetail; GitHub API fallback failed: $($_.Exception.Message)"
        }
    }
}

$resolvedRepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
$resolvedAcceptancePath = Resolve-RepoPath -Path $AcceptanceEvidencePath
Assert-True -Condition (Test-Path -LiteralPath $resolvedAcceptancePath) -Message "Missing acceptance evidence: $resolvedAcceptancePath"

$branch = Get-GitText -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
$head = Get-GitText -Arguments @("rev-parse", "HEAD")
if ([string]::IsNullOrWhiteSpace($ExpectedHead)) {
    $ExpectedHead = $head
}

$acceptanceVerifier = Join-Path $resolvedRepoRoot "Scripts/verify-windows-portability-acceptance-evidence.ps1"
Assert-True -Condition (Test-Path -LiteralPath $acceptanceVerifier) -Message "Missing acceptance evidence verifier: $acceptanceVerifier"

$verifierArguments = @{
    RepoRoot = $resolvedRepoRoot
    AcceptanceEvidencePath = $resolvedAcceptancePath
    RustCliCoverageEvidencePath = (Resolve-RepoPath -Path $RustCliCoverageEvidencePath)
    StackFreshnessEvidencePath = (Resolve-RepoPath -Path $StackFreshnessEvidencePath)
    RequireRustCliCoverage = $true
    RequireOnlineStackFreshness = $true
    RequireNativeDnsSdAcceptance = $true
    ExpectedBranch = $ExpectedBranch
    ExpectedHead = $ExpectedHead
}

$resolvedWinUiEvidenceDir = Resolve-RepoPath -Path $WinUiEvidenceDir
$standaloneWinUiEvidenceAccepted = (-not [string]::IsNullOrWhiteSpace($resolvedWinUiEvidenceDir)) -and [bool]$AllowStandaloneWinUiVisualEvidence
if (-not [string]::IsNullOrWhiteSpace($resolvedWinUiEvidenceDir)) {
    $verifierArguments.WinUiEvidenceDir = $resolvedWinUiEvidenceDir
    $verifierArguments.RequireWinUiVisualEvidence = $true
    if ($AllowStandaloneWinUiVisualEvidence) {
        $verifierArguments.AllowStandaloneWinUiVisualEvidence = $true
    }
}

& $acceptanceVerifier @verifierArguments | Write-Output

$acceptance = Get-Content -Raw -LiteralPath $resolvedAcceptancePath | ConvertFrom-Json
$items = [System.Collections.Generic.List[object]]::new()

Add-AuditItem -Items $items -Id "REQ-RESEARCH" -Status "complete" -Evidence "windows-research-evidence gate passed and acceptance evidence verifier accepted the package."
Add-AuditItem -Items $items -Id "REQ-BEST-PRACTICE-RESEARCH" -Status "complete" -Evidence "windows-research-evidence, windows-stack-freshness, and acceptance-map gates passed."
Add-AuditItem -Items $items -Id "REQ-SUBAGENT-SUMMARY" -Status "complete" -Evidence "docs/windows-research-agent-synthesis.md is checked by windows-research-evidence."
Add-AuditItem -Items $items -Id "REQ-STACK" -Status "complete" -Evidence "online stack freshness evidence was required and accepted."
Add-AuditItem -Items $items -Id "REQ-MODULARITY" -Status "complete" -Evidence "windows-ffi-client, native-runtime-profile, connection-launch, startup-state, command-gates, and file-transfer-qr gates passed."
if (Test-GatePassed -Acceptance $acceptance -Name "windows-ui-automation-smoke" -and (Test-GatePassed -Acceptance $acceptance -Name "windows-ui-visual-evidence")) {
    Add-AuditItem -Items $items -Id "REQ-UI" -Status "complete" -Evidence "UI static parity, action order, matrix, automation smoke, and visual evidence gates passed."
}
elseif ($standaloneWinUiEvidenceAccepted) {
    Add-AuditItem -Items $items -Id "REQ-UI" -Status "complete" -Evidence "UI static gates passed and standalone interactive WinUI evidence was verified for this acceptance branch/head: $resolvedWinUiEvidenceDir"
}
else {
    Add-AuditItem -Items $items -Id "REQ-UI" -Status "incomplete" -Evidence "Static UI gates passed." -Gap "Interactive WinUI automation and visual evidence must pass for release-quality UI parity."
}
Add-AuditItem -Items $items -Id "REQ-RUST-CLI" -Status "complete" -Evidence "Rust CLI coverage evidence was required and accepted at or above 90% total and cli.rs line coverage."
Add-AuditItem -Items $items -Id "REQ-BASIC-SMOKE" -Status "complete" -Evidence "Repository smoke evidence has no failed gates and required local evidence gates passed."
Add-AuditItem -Items $items -Id "REQ-APPLE-PRESERVATION" -Status "complete" -Evidence "apple-native-preservation gate passed; CLI/FFI tests keep Apple-to-Apple native and Windows-to-Apple WebRTC interop."
Add-AuditItem -Items $items -Id "REQ-NATIVE-DNS-SD" -Status "complete" -Evidence "native DNS-SD acceptance was required and passed."

$macReady = (Test-GatePassed -Acceptance $acceptance -Name "mac-ssh-readiness")
$macInterop = (Test-GatePassed -Acceptance $acceptance -Name "windows-mac-webrtc-interop")
if ($macReady -and $macInterop) {
    Add-AuditItem -Items $items -Id "REQ-MAC-INTEROP" -Status "complete" -Evidence "Mac SSH readiness and Windows-to-mac WebRTC interop gates passed."
}
else {
    $macGap = "Run portability smoke with -RequireMacSshReady -RequireMacDirectLan -RequireMacRustCliSmoke -RequireMacWebRtcInterop, pinned host key, Mac repo root, expected identity, DNS-SD peer, and WebRTC helper proof after both devices are on the same non-proxy LAN."
    if (-not [string]::IsNullOrWhiteSpace($MacSshEvidencePath)) {
        $resolvedMacEvidence = Resolve-RepoPath -Path $MacSshEvidencePath
        if (Test-Path -LiteralPath $resolvedMacEvidence) {
            $macGap = $macGap + " Current Mac probe evidence: $resolvedMacEvidence"
        }
    }
    Add-AuditItem -Items $items -Id "REQ-MAC-INTEROP" -Status "incomplete" -Evidence "mac-ssh-readiness or windows-mac-webrtc-interop gate is not passed." -Gap $macGap
}

$remoteCheck = [ordered]@{
    status = "not-checked"
    head = ""
    detail = "Pass -CheckRemoteBranch to compare origin/$ExpectedBranch with the local HEAD; pass -AllowGitHubApiRemoteCheck to verify through the GitHub refs API when SSH authorization is unavailable."
}
if ($CheckRemoteBranch) {
    $remoteCheck = Get-RemoteBranchHead -Branch $ExpectedBranch -Repository $GitHubRepository -AllowGitHubApiFallback:$AllowGitHubApiRemoteCheck
}

if ([string]$remoteCheck.status -eq "available" -and [string]$remoteCheck.head -eq $head) {
    Add-AuditItem -Items $items -Id "REQ-GITHUB-UPLOAD" -Status "complete" -Evidence "$GitHubRepository/$ExpectedBranch points to local HEAD $head."
}
else {
    $gap = "Authorize the configured GitHub SSH key or use Scripts/push-github-gcm.ps1 with a writable Git Credential Manager credential, then rerun this audit with -CheckRemoteBranch -AllowGitHubApiRemoteCheck."
    if ($CheckRemoteBranch) {
        $gap = $gap + " Remote check status=$($remoteCheck.status) head=$($remoteCheck.head) detail=$($remoteCheck.detail)"
    }
    Add-AuditItem -Items $items -Id "REQ-GITHUB-UPLOAD" -Status "incomplete" -Evidence "Remote branch upload is not proven." -Gap $gap
}

$incompleteItems = @($items | Where-Object { [string]$_.status -ne "complete" })
$completionStatus = if ($incompleteItems.Count -eq 0) { "complete" } else { "incomplete" }
$report = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    repoRoot = $resolvedRepoRoot
    branch = $branch
    head = $head
    acceptanceEvidencePath = $resolvedAcceptancePath
    completionStatus = $completionStatus
    incompleteCount = $incompleteItems.Count
    remoteBranch = $remoteCheck
    items = @($items)
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $resolvedReportPath = Resolve-RepoPath -Path $ReportPath
    $reportDirectory = Split-Path -Parent $resolvedReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
        New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedReportPath -Encoding UTF8
    Write-Output "windows-portability-completion-audit: report=$resolvedReportPath"
}

foreach ($item in $items) {
    Write-Output ("windows-portability-completion-audit: {0} {1}" -f $item.id, $item.status)
}
Write-Output "windows-portability-completion-audit: status=$completionStatus incomplete=$($incompleteItems.Count)"

if ($RequireComplete -and $completionStatus -ne "complete") {
    throw "Windows portability completion audit is incomplete: $($incompleteItems.id -join ', ')"
}
