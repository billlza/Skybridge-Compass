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

    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Missing acceptance-map input: $Path"
    return (Get-Content -Raw -LiteralPath $Path)
}

$architecturePath = Join-Path $RepoRoot "docs/windows-architecture.md"
$researchSynthesisPath = Join-Path $RepoRoot "docs/windows-research-agent-synthesis.md"
$uiContractPath = Join-Path $RepoRoot "docs/windows-ui-parity-contract.md"
$uiMatrixPath = Join-Path $RepoRoot "docs/windows-ui-parity-matrix.md"
$webrtcSchemaPath = Join-Path $RepoRoot "docs/windows-webrtc-proof-schema.md"
$githubTransportPath = Join-Path $RepoRoot "docs/github-ssh-transport.md"
$acceptanceMapPath = Join-Path $RepoRoot "docs/windows-portability-acceptance-map.md"

$portabilitySmokePath = Join-Path $RepoRoot "Scripts/verify-windows-portability-smoke.ps1"
$acceptanceEvidencePath = Join-Path $RepoRoot "Scripts/verify-windows-portability-acceptance-evidence.ps1"
$completionAuditPath = Join-Path $RepoRoot "Scripts/audit-windows-portability-completion.ps1"
$researchEvidencePath = Join-Path $RepoRoot "Scripts/verify-windows-research-evidence.ps1"
$stackFreshnessPath = Join-Path $RepoRoot "Scripts/verify-windows-stack-freshness.ps1"
$rustCoveragePath = Join-Path $RepoRoot "Scripts/verify-rust-cli-coverage.ps1"
$ffiClientPath = Join-Path $RepoRoot "Scripts/verify-windows-ffi-client.ps1"
$uiParityPath = Join-Path $RepoRoot "Scripts/verify-windows-ui-parity.ps1"
$uiActionOrderPath = Join-Path $RepoRoot "Scripts/verify-windows-ui-action-order.ps1"
$uiMatrixSmokePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-parity-matrix.ps1"
$uiAutomationSmokePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-automation-smoke.ps1"
$uiVisualEvidencePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-visual-evidence.ps1"
$applePreservationPath = Join-Path $RepoRoot "Scripts/verify-apple-native-preservation.ps1"
$macCodbgPath = Join-Path $RepoRoot "Scripts/prepare-mac-rust-cli-codbg.ps1"
$macCodbgWrapperPath = Join-Path $RepoRoot "Scripts/verify-mac-rust-cli-codbg-wrapper.ps1"
$macInteropPath = Join-Path $RepoRoot "Scripts/verify-windows-mac-webrtc-interop.ps1"
$gitSshRemotePath = Join-Path $RepoRoot "Scripts/verify-git-ssh-remote.ps1"
$githubPushPath = Join-Path $RepoRoot "Scripts/push-github-ssh.ps1"
$githubGcmPushPath = Join-Path $RepoRoot "Scripts/push-github-gcm.ps1"
$githubEnsurePath = Join-Path $RepoRoot "Scripts/ensure-github-ssh-remote.ps1"

$architecture = Read-RequiredText -Path $architecturePath
$researchSynthesis = Read-RequiredText -Path $researchSynthesisPath
$uiContract = Read-RequiredText -Path $uiContractPath
$uiMatrix = Read-RequiredText -Path $uiMatrixPath
$webrtcSchema = Read-RequiredText -Path $webrtcSchemaPath
$githubTransport = Read-RequiredText -Path $githubTransportPath
$acceptanceMap = Read-RequiredText -Path $acceptanceMapPath
$portabilitySmoke = Read-RequiredText -Path $portabilitySmokePath
$acceptanceEvidence = Read-RequiredText -Path $acceptanceEvidencePath
$completionAudit = Read-RequiredText -Path $completionAuditPath
$researchEvidence = Read-RequiredText -Path $researchEvidencePath
$stackFreshness = Read-RequiredText -Path $stackFreshnessPath
$rustCoverage = Read-RequiredText -Path $rustCoveragePath
$ffiClient = Read-RequiredText -Path $ffiClientPath
$uiParity = Read-RequiredText -Path $uiParityPath
$uiActionOrder = Read-RequiredText -Path $uiActionOrderPath
$uiMatrixSmoke = Read-RequiredText -Path $uiMatrixSmokePath
$uiAutomationSmoke = Read-RequiredText -Path $uiAutomationSmokePath
$uiVisualEvidence = Read-RequiredText -Path $uiVisualEvidencePath
$applePreservation = Read-RequiredText -Path $applePreservationPath
$macCodbg = Read-RequiredText -Path $macCodbgPath
$macCodbgWrapper = Read-RequiredText -Path $macCodbgWrapperPath
$macInterop = Read-RequiredText -Path $macInteropPath
$gitSshRemote = Read-RequiredText -Path $gitSshRemotePath
$githubPush = Read-RequiredText -Path $githubPushPath
$githubGcmPush = Read-RequiredText -Path $githubGcmPushPath
$githubEnsure = Read-RequiredText -Path $githubEnsurePath

foreach ($requirement in @(
    "REQ-RESEARCH",
    "REQ-BEST-PRACTICE-RESEARCH",
    "REQ-SUBAGENT-SUMMARY",
    "REQ-STACK",
    "REQ-MODULARITY",
    "REQ-UI",
    "REQ-RUST-CLI",
    "REQ-BASIC-SMOKE",
    "REQ-APPLE-PRESERVATION",
    "REQ-MAC-INTEROP",
    "REQ-GITHUB-SSH",
    "REQ-GITHUB-UPLOAD"
)) {
    Assert-Contains -Text $acceptanceMap -Needle $requirement -Message "Acceptance map missing requirement id: $requirement"
}

foreach ($signal in @(
    "current TDSC mac branch",
    "Docs/CoreLayering.md",
    "Docs/ProtocolAlignmentPlan.md",
    "Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md",
    "Sources checked on 2026-06-09",
    "paper materials as stale"
)) {
    Assert-Contains -Text $architecture -Needle $signal -Message "Research evidence missing signal: $signal"
}
foreach ($signal in @(
    "Best-Practice Research Matrix",
    "Sub-Agent Research Summary",
    "checkedAtUtc",
    "sourceUris",
    "decisionImpact",
    "staleRisk",
    "agentRole",
    "reportId",
    "019eaabe-015c-7ba1-a82f-ed04ef5295e5",
    "019eaabe-45ca-7fe2-a24c-83a5bfa02ecb",
    "019eaabe-7d5b-7c33-9691-ba4765b93287",
    "verify-windows-research-evidence.ps1",
    "windows-research-evidence: ok"
)) {
    Assert-Contains -Text ($researchSynthesis + $researchEvidence + $acceptanceMap) -Needle $signal -Message "Sub-agent research evidence missing signal: $signal"
}

foreach ($signal in @(
    "Technology stack check",
    "net10.0-windows10.0.22621.0",
    "TargetPlatformMinVersion",
    "10.0.19041.0",
    "Microsoft.WindowsAppSDK",
    "2.2.0",
    "Microsoft.Windows.SDK.BuildTools",
    "10.0.28000.1839",
    "QRCoder",
    "1.8.0",
    "MsQuic v2.5.8",
    "libdatachannel v0.24.4",
    "verify-windows-stack-freshness.ps1"
)) {
    Assert-Contains -Text $architecture -Needle $signal -Message "Stack evidence missing architecture signal: $signal"
}
foreach ($signal in @(
    "CheckOnline",
    "api.nuget.org",
    "api.github.com",
    "sourceUris",
    "online latest-version results",
    "EvidencePath"
)) {
    Assert-Contains -Text $stackFreshness -Needle $signal -Message "Stack freshness gate missing signal: $signal"
}

foreach ($signal in @(
    "SessionViewModelDependencies",
    "SessionViewModelDependencyFactory",
    "CreateConfigured",
    "CoreBridge",
    "IWindowsTransportAdapterClient",
    "VerifiedWebRtcDataChannelTransportAdapterClient",
    "ConnectionLaunchRequest",
    "fail-closed"
)) {
    Assert-Contains -Text $architecture -Needle $signal -Message "Modularity architecture missing signal: $signal"
}
foreach ($signal in @(
    "FfiEngineClient",
    "CoreBridge",
    "SessionViewModelDependencyFactory",
    "WindowsNativeRuntimeDependencyFactory",
    "verify-windows-ui-parity.ps1"
)) {
    Assert-Contains -Text $ffiClient -Needle $signal -Message "Modularity gate missing signal: $signal"
}
Assert-Contains -Text $uiParity -Needle "MainWindow.xaml action surface must use shared resources" -Message "UI parity static gate missing shared-resource action-surface assertion."
Assert-Contains -Text $uiParity -Needle 'x:Key="WorkspaceActionButtonTemplate"' -Message "UI parity static gate missing shared action-button template assertion."

foreach ($signal in @(
    "Product Design QA gate",
    "buttons and feature positions must match",
    "fonts, rendering scale, and platform-specific pixel metrics remain out of scope",
    "Action Order Matrix",
    "Mac baseline commit",
    "16 PNG screenshots",
    "runtimeActionBounds"
)) {
    Assert-Contains -Text ($uiContract + $uiMatrix) -Needle $signal -Message "UI parity evidence missing signal: $signal"
}
foreach ($signal in @(
    "WorkspaceAction.<Surface>.<Key>",
    "minimum usable bounds",
    "windows-ui-visual-evidence.json",
    "windows-ui-visual-evidence-verify: ok"
)) {
    Assert-Contains -Text ($uiAutomationSmoke + $uiVisualEvidence + $uiMatrixSmoke + $uiActionOrder) -Needle $signal -Message "UI executable gate missing signal: $signal"
}

foreach ($signal in @(
    "MinimumLineCoverage",
    "cargo fmt",
    "cargo clippy",
    "cargo test",
    "cargo llvm-cov",
    "totalLineCoverage",
    "cliLineCoverage",
    "cli.rs line coverage",
    "nativeLibraryPath"
)) {
    Assert-Contains -Text $rustCoverage -Needle $signal -Message "Rust CLI coverage gate missing signal: $signal"
}
Assert-Contains -Text $architecture -Needle "at or above 90%" -Message "Architecture doc missing Rust CLI 90% threshold."

foreach ($gate in @(
    "git-ssh-remote",
    "windows-ci-workflow",
    "windows-stack-freshness",
    "windows-research-evidence",
    "windows-ffi-client",
    "windows-ui-parity",
    "windows-ui-action-order",
    "windows-ui-parity-matrix",
    "windows-startup-state",
    "windows-command-gates",
    "windows-file-transfer-qr",
    "windows-native-runtime-profile",
    "windows-connection-launch",
    "windows-webrtc-proof-smoke",
    "apple-native-preservation",
    "mac-rust-cli-codbg-wrapper"
)) {
    Assert-Contains -Text $portabilitySmoke -Needle $gate -Message "Default portability smoke missing gate: $gate"
}
foreach ($optionalGate in @(
    "IncludeWinUiAutomationSmoke",
    "WinUiEvidenceDir",
    "IncludeRustCliCoverage",
    "RustCliCoverageEvidencePath",
    "CheckOnlineStackFreshness",
    "StackFreshnessEvidencePath",
    "RequireMacWebRtcInterop",
    "MacExpectedHostKeyFingerprint",
    "AcceptanceEvidencePath"
)) {
    Assert-Contains -Text $portabilitySmoke -Needle $optionalGate -Message "Portability evidence option missing signal: $optionalGate"
}
foreach ($signal in @(
    "verify-windows-portability-acceptance-evidence.ps1",
    "audit-windows-portability-completion.ps1",
    "AcceptanceEvidencePath",
    "gateResults",
    "generatedAtUtc",
    "RequireRustCliCoverage",
    "RequireOnlineStackFreshness",
    "RequireWinUiVisualEvidence",
    "RequireNativeDnsSdAcceptance",
    "RequireMacInterop",
    "RequireComplete",
    "CheckRemoteBranch",
    "REQ-GITHUB-UPLOAD",
    "REQ-MAC-INTEROP",
    "windows-portability-acceptance-evidence: ok"
)) {
    Assert-Contains -Text ($acceptanceMap + $acceptanceEvidence + $completionAudit) -Needle $signal -Message "Portability acceptance evidence gate missing signal: $signal"
}

foreach ($signal in @(
    "cli_apple_to_apple_selects_apple_native",
    "cli_apple_to_apple_connection_plan_keeps_apple_native_channels",
    "windows_to_apple_same_lan_never_uses_apple_native",
    "Windows-to-Apple cross-NAT connection plan must use WebRTC DataChannel",
    "Apple-to-Apple transport must not be replaced by WebRTC"
)) {
    Assert-Contains -Text $applePreservation -Needle $signal -Message "AppleNative preservation gate missing signal: $signal"
}

foreach ($signal in @(
    "prepare-mac-rust-cli-codbg.ps1",
    "RequireKnownHost",
    "MacExpectedHostKeyFingerprint",
    "ProbeEvidencePath",
    "RequireDirectLan",
    "RequireRustCliSmoke",
    "MacRemoteRepoRoot",
    "probeEvidencePath",
    "remediation",
    "reasonCodes",
    "nextInteropCommand",
    "verify-windows-mac-webrtc-interop.ps1",
    "RequirePeer",
    "verify-rust-webrtc-proof-cli.ps1",
    "verify-windows-webrtc-proof.ps1",
    "verify-windows-connection-launch.ps1",
    "direct LAN, Mac SSH, Mac Rust CLI, native DNS-SD, and helper proof generation"
)) {
    Assert-Contains -Text ($macCodbg + $macCodbgWrapper + $macInterop + $webrtcSchema) -Needle $signal -Message "Mac interop evidence missing signal: $signal"
}

foreach ($signal in @(
    "GitHub SSH transport policy",
    "git-remote-https.exe",
    "credential.helper",
    "StrictHostKeyChecking=yes",
    "fallback bundle",
    "Permission denied (publickey)",
    "RequireRemoteAccess",
    "push-github-gcm.ps1",
    "Git Credential Manager",
    "SKYBRIDGE_ALLOW_GITHUB_HTTPS_GCM",
    "AllowGitHubApiRemoteCheck",
    "fast-forward",
    "git@github.com:billlza/Skybridge-Compass.git"
)) {
    Assert-Contains -Text ($githubTransport + $gitSshRemote + $githubPush + $githubGcmPush + $githubEnsure) -Needle $signal -Message "GitHub SSH evidence missing signal: $signal"
}

Write-Output "windows-portability-acceptance-map: ok"
