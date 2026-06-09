param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition $Text.Contains($Needle) -Message $Message
}

$workflowPath = Join-Path $RepoRoot ".github/workflows/windows-portability.yml"
$portabilitySmokePath = Join-Path $RepoRoot "Scripts/verify-windows-portability-smoke.ps1"
$rustCoveragePath = Join-Path $RepoRoot "Scripts/verify-rust-cli-coverage.ps1"
$gitSshRemotePath = Join-Path $RepoRoot "Scripts/verify-git-ssh-remote.ps1"

foreach ($path in @($workflowPath, $portabilitySmokePath, $rustCoveragePath, $gitSshRemotePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing Windows CI gate input: $path"
}

$workflow = Get-Content -Raw -LiteralPath $workflowPath
$portabilitySmoke = Get-Content -Raw -LiteralPath $portabilitySmokePath
$rustCoverage = Get-Content -Raw -LiteralPath $rustCoveragePath
$gitSshRemote = Get-Content -Raw -LiteralPath $gitSshRemotePath

foreach ($signal in @(
    "name: Windows Portability",
    "windows-latest",
    "actions/checkout@v4",
    "actions/setup-dotnet@v4",
    "dotnet-version: '10.0.x'",
    "rustup toolchain install stable --profile minimal",
    "rustup component add clippy",
    "rustup component add llvm-tools-preview",
    "cargo install cargo-llvm-cov --locked",
    "git remote set-url origin git@github.com:billlza/Skybridge-Compass.git",
    "git remote set-url --push origin git@github.com:billlza/Skybridge-Compass.git",
    "New-Item -ItemType Directory -Force -Path artifacts",
    "Scripts\verify-windows-portability-smoke.ps1",
    "-CiMode -CheckOnlineStackFreshness -IncludeRustCliCoverage",
    "-StackFreshnessEvidencePath artifacts\windows-stack-freshness.json",
    "-RustCliCoverageEvidencePath artifacts\rust-cli-coverage.json",
    "-AcceptanceEvidencePath artifacts\windows-portability-acceptance.json",
    "permissions:",
    "contents: read"
)) {
    Assert-Contains -Text $workflow -Needle $signal -Message "Windows CI workflow missing signal: $signal"
}

foreach ($forbidden in @(
    "-RequireGitRemoteAccess",
    "-RequireMacSshReady",
    "-RequireMacDirectLan",
    "-RequireMacWebRtcInterop",
    "-RequireNativeDnsSdPeer"
)) {
    Assert-True -Condition (-not $workflow.Contains($forbidden)) -Message "Windows CI workflow must not require local-only readiness gate: $forbidden"
}

foreach ($signal in @(
    "CiMode",
    "verify-windows-ci-workflow.ps1",
    "CI mode keeps the SSH-only remote check",
    "RequireConfiguredSshCommand",
    "RequireKnownHosts",
    "RequireCredentialHelperReset",
    "IncludeRustCliCoverage",
    "CheckOnlineStackFreshness",
    "RustCliCoverageEvidencePath"
)) {
    Assert-Contains -Text $portabilitySmoke -Needle $signal -Message "Portability smoke missing CI signal: $signal"
}

foreach ($signal in @(
    "MinimumLineCoverage",
    "cargo fmt",
    "--check",
    "cargo clippy",
    "--all-targets",
    "--all-features",
    "-D warnings",
    "cargo llvm-cov",
    "fail-under-lines",
    "EvidencePath",
    "rust-cli-coverage: evidence=",
    "totalLineCoverage",
    "cliLineCoverage",
    "cli.rs",
    "cli.rs line coverage"
)) {
    Assert-Contains -Text $rustCoverage -Needle $signal -Message "Rust coverage gate missing CI coverage signal: $signal"
}

foreach ($signal in @(
    "Git remote",
    "must use SSH",
    "not HTTPS",
    "git-remote-https.exe",
    "RequireRemoteAccess"
)) {
    Assert-Contains -Text $gitSshRemote -Needle $signal -Message "Git SSH remote gate missing transport signal: $signal"
}

Write-Output "windows-ci-workflow: ok"
