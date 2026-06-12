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

    Assert-True -Condition ($Text.Contains($Needle)) -Message $Message
}

function Read-RequiredText {
    param([string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Missing research evidence input: $Path"
    return (Get-Content -Raw -LiteralPath $Path)
}

$architecturePath = Join-Path $RepoRoot "docs/windows-architecture.md"
$synthesisPath = Join-Path $RepoRoot "docs/windows-research-agent-synthesis.md"
$acceptanceMapPath = Join-Path $RepoRoot "docs/windows-portability-acceptance-map.md"
$stackFreshnessPath = Join-Path $RepoRoot "Scripts/verify-windows-stack-freshness.ps1"

$architecture = Read-RequiredText -Path $architecturePath
$synthesis = Read-RequiredText -Path $synthesisPath
$acceptanceMap = Read-RequiredText -Path $acceptanceMapPath
$stackFreshness = Read-RequiredText -Path $stackFreshnessPath

foreach ($signal in @(
    "current TDSC mac branch",
    "Docs/CoreLayering.md",
    "Docs/ProtocolAlignmentPlan.md",
    "Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md",
    "Technology stack check",
    "Sources checked on 2026-06-09"
)) {
    Assert-Contains -Text $architecture -Needle $signal -Message "Architecture research evidence missing signal: $signal"
}

foreach ($signal in @(
    "Windows Research And Sub-Agent Synthesis",
    "Best-Practice Research Matrix",
    "Sub-Agent Research Summary",
    "checkedAtUtc",
    "sourceUris",
    "finding",
    "decisionImpact",
    "staleRisk",
    "agentRole",
    "reportId",
    "019eaabe-015c-7ba1-a82f-ed04ef5295e5",
    "019eaabe-45ca-7fe2-a24c-83a5bfa02ecb",
    "019eaabe-7d5b-7c33-9691-ba4765b93287",
    "research-stack explorer",
    "ui-parity explorer",
    "rust-apple explorer",
    "Open Evidence Gaps",
    "Real Windows-to-mac interop remains blocked",
    "GitHub branch upload is now covered",
    "Interactive WinUI visual screenshots"
)) {
    Assert-Contains -Text $synthesis -Needle $signal -Message "Sub-agent synthesis missing signal: $signal"
}

foreach ($signal in @(
    "dotnetcli.blob.core.windows.net",
    "api.nuget.org",
    "api.github.com",
    "sourceUris",
    "online latest-version results",
    "EvidencePath"
)) {
    Assert-Contains -Text $stackFreshness -Needle $signal -Message "Stack best-practice evidence missing signal: $signal"
}

foreach ($signal in @(
    "REQ-RESEARCH",
    "REQ-BEST-PRACTICE-RESEARCH",
    "REQ-SUBAGENT-SUMMARY",
    "verify-windows-research-evidence.ps1"
)) {
    Assert-Contains -Text $acceptanceMap -Needle $signal -Message "Acceptance map missing research evidence signal: $signal"
}

Write-Output "windows-research-evidence: ok"
