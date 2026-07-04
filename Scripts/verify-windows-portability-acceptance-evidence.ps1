param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string]$AcceptanceEvidencePath,
    [double]$MinimumLineCoverage = 90.0,
    [switch]$RequireRustCliCoverage,
    [switch]$RequireOnlineStackFreshness,
    [switch]$RequireWinUiVisualEvidence,
    [switch]$AllowStandaloneWinUiVisualEvidence,
    [switch]$RequireNativeDnsSdAcceptance,
    [switch]$RequireMacInterop,
    [switch]$RequireWindowsReverseSshRelayLifecycle,
    [string]$RustCliCoverageEvidencePath = "",
    [string]$StackFreshnessEvidencePath = "",
    [string]$WinUiEvidenceDir = "",
    [string]$MacSshEvidencePath = "",
    [string]$WindowsReverseSshRelayEvidencePath = "",
    [string]$ExpectedBranch = "",
    [string]$ExpectedHead = ""
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

function Assert-JsonProperty {
    param(
        $Object,
        [string]$Name,
        [string]$Context
    )

    Assert-True -Condition ($null -ne $Object) -Message "$Context is null."
    $property = $Object.PSObject.Properties[$Name]
    Assert-True -Condition ($null -ne $property) -Message "$Context missing JSON property: $Name"
    return $property.Value
}

function ConvertTo-Boolean {
    param(
        $Value,
        [string]$Context
    )

    Assert-True -Condition ($null -ne $Value) -Message "$Context is null."
    return [System.Convert]::ToBoolean($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DoubleInvariant {
    param(
        $Value,
        [string]$Context
    )

    Assert-True -Condition ($null -ne $Value) -Message "$Context is null."
    return [System.Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Resolve-EvidencePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $RepoRoot $Path))
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Context
    )

    $resolvedPath = Resolve-EvidencePath -Path $Path
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedPath)) -Message "$Context evidence path is empty."
    Assert-True -Condition (Test-Path -LiteralPath $resolvedPath) -Message "$Context evidence file is missing: $resolvedPath"
    return (Get-Content -Raw -LiteralPath $resolvedPath | ConvertFrom-Json)
}

function Get-OverrideOrJsonPath {
    param(
        [string]$OverridePath,
        $EvidencePaths,
        [string]$PropertyName
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return $OverridePath
    }

    return [string](Assert-JsonProperty -Object $EvidencePaths -Name $PropertyName -Context "acceptance.evidencePaths")
}

function Assert-DateString {
    param(
        [string]$Value,
        [string]$Context
    )

    $parsed = [DateTime]::MinValue
    Assert-True -Condition ([DateTime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed) -and $parsed -gt [DateTime]::MinValue) -Message "$Context must be a parseable UTC date string."
}

function Assert-PassedGate {
    param([string]$Name)

    $gate = Get-Gate -Name $Name
    Assert-True -Condition ([string]$gate.status -eq "passed") -Message "Acceptance gate must be passed: $Name status=$($gate.status) detail=$($gate.detail)"
    return $gate
}

function Assert-SkippedGate {
    param([string]$Name)

    $gate = Get-Gate -Name $Name
    Assert-True -Condition ([string]$gate.status -eq "skipped") -Message "Acceptance gate must be skipped: $Name status=$($gate.status) detail=$($gate.detail)"
    return $gate
}

function Assert-PassedOrSkippedGate {
    param([string]$Name)

    $gate = Get-Gate -Name $Name
    $status = [string]$gate.status
    Assert-True -Condition ($status -eq "passed" -or $status -eq "skipped") -Message "Acceptance gate must be passed or skipped: $Name status=$status detail=$($gate.detail)"
    return $gate
}

function Get-Gate {
    param([string]$Name)

    $matches = @($script:AcceptanceGateResults | Where-Object { [string]$_.name -eq $Name })
    Assert-True -Condition ($matches.Count -eq 1) -Message "Expected exactly one acceptance gate named $Name, found $($matches.Count)."
    return $matches[0]
}

function Assert-RequiredBooleanParameter {
    param(
        $Parameters,
        [string]$Name,
        [bool]$Expected
    )

    $value = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $Parameters -Name $Name -Context "acceptance.parameters") -Context "acceptance.parameters.$Name"
    Assert-True -Condition ($value -eq $Expected) -Message "Acceptance parameter $Name must be $Expected, got $value."
}

$resolvedRepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
$resolvedAcceptanceEvidencePath = Resolve-EvidencePath -Path $AcceptanceEvidencePath
Assert-True -Condition (Test-Path -LiteralPath $resolvedAcceptanceEvidencePath) -Message "Missing Windows portability acceptance evidence: $resolvedAcceptanceEvidencePath"

$acceptance = Get-Content -Raw -LiteralPath $resolvedAcceptanceEvidencePath | ConvertFrom-Json
Assert-DateString -Value ([string](Assert-JsonProperty -Object $acceptance -Name "generatedAtUtc" -Context "acceptance")) -Context "acceptance.generatedAtUtc"

$acceptanceRepoRoot = [string](Assert-JsonProperty -Object $acceptance -Name "repoRoot" -Context "acceptance")
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($acceptanceRepoRoot)) -Message "Acceptance repoRoot is empty."
$resolvedAcceptanceRepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($acceptanceRepoRoot)
Assert-True -Condition ([string]::Equals($resolvedAcceptanceRepoRoot, $resolvedRepoRoot, [StringComparison]::OrdinalIgnoreCase)) -Message "Acceptance repoRoot mismatch: expected=$resolvedRepoRoot actual=$resolvedAcceptanceRepoRoot"

$branch = [string](Assert-JsonProperty -Object $acceptance -Name "branch" -Context "acceptance")
$head = [string](Assert-JsonProperty -Object $acceptance -Name "head" -Context "acceptance")
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($branch)) -Message "Acceptance branch is empty."
Assert-True -Condition ($head -match '^[0-9a-f]{40}$') -Message "Acceptance head must be a 40-character git SHA: $head"
if (-not [string]::IsNullOrWhiteSpace($ExpectedBranch)) {
    Assert-True -Condition ($branch -eq $ExpectedBranch) -Message "Acceptance branch mismatch: expected=$ExpectedBranch actual=$branch"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedHead)) {
    Assert-True -Condition ($head -eq $ExpectedHead) -Message "Acceptance head mismatch: expected=$ExpectedHead actual=$head"
}

$parameters = Assert-JsonProperty -Object $acceptance -Name "parameters" -Context "acceptance"
$evidencePaths = Assert-JsonProperty -Object $acceptance -Name "evidencePaths" -Context "acceptance"
$script:AcceptanceGateResults = @((Assert-JsonProperty -Object $acceptance -Name "gateResults" -Context "acceptance"))
Assert-True -Condition ($script:AcceptanceGateResults.Count -gt 0) -Message "Acceptance gateResults must not be empty."

$seenGates = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($gate in $script:AcceptanceGateResults) {
    $name = [string](Assert-JsonProperty -Object $gate -Name "name" -Context "acceptance.gateResults[]")
    $status = [string](Assert-JsonProperty -Object $gate -Name "status" -Context "acceptance.gateResults[$name]")
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($name)) -Message "Acceptance gate name is empty."
    Assert-True -Condition ($seenGates.Add($name)) -Message "Duplicate acceptance gate result: $name"
    Assert-True -Condition ($status -eq "passed" -or $status -eq "skipped") -Message "Acceptance gate must not be failed: $name status=$status"
}

foreach ($gateName in @(
    "git-ssh-remote",
    "windows-ci-workflow",
    "windows-stack-freshness",
    "windows-research-evidence",
    "windows-portability-acceptance-map",
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
    Assert-PassedGate -Name $gateName | Out-Null
}

$includeWinUiAutomationSmoke = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeWinUiAutomationSmoke" -Context "acceptance.parameters") -Context "acceptance.parameters.includeWinUiAutomationSmoke"
$winUiEvidencePath = Get-OverrideOrJsonPath -OverridePath $WinUiEvidenceDir -EvidencePaths $evidencePaths -PropertyName "winUiEvidenceDir"
if ($includeWinUiAutomationSmoke) {
    Assert-PassedGate -Name "windows-ui-automation-smoke" | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($winUiEvidencePath)) {
        Assert-PassedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
    else {
        Assert-SkippedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
}
else {
    Assert-PassedOrSkippedGate -Name "windows-ui-automation-smoke" | Out-Null
    Assert-PassedOrSkippedGate -Name "windows-ui-visual-evidence" | Out-Null
}

if ($RequireWinUiVisualEvidence) {
    if ($includeWinUiAutomationSmoke) {
        Assert-PassedGate -Name "windows-ui-automation-smoke" | Out-Null
        Assert-PassedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
    else {
        Assert-True `
            -Condition ([bool]$AllowStandaloneWinUiVisualEvidence) `
            -Message "WinUI visual evidence was required, but acceptance evidence did not run windows-ui-automation-smoke. Pass -AllowStandaloneWinUiVisualEvidence with -WinUiEvidenceDir only when an interactive desktop task generated the evidence for this same branch/head."
        Assert-SkippedGate -Name "windows-ui-automation-smoke" | Out-Null
        Assert-SkippedGate -Name "windows-ui-visual-evidence" | Out-Null
    }
    $resolvedWinUiEvidenceDir = Resolve-EvidencePath -Path $winUiEvidencePath
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedWinUiEvidenceDir)) -Message "WinUI visual evidence directory is empty."
    Assert-True -Condition (Test-Path -LiteralPath $resolvedWinUiEvidenceDir) -Message "WinUI visual evidence directory is missing: $resolvedWinUiEvidenceDir"
    $visualEvidenceVerifier = Join-Path $resolvedRepoRoot "Scripts/verify-windows-ui-visual-evidence.ps1"
    Assert-True -Condition (Test-Path -LiteralPath $visualEvidenceVerifier) -Message "Missing WinUI visual evidence verifier: $visualEvidenceVerifier"
    & $visualEvidenceVerifier -RepoRoot $resolvedRepoRoot -EvidenceDir $resolvedWinUiEvidenceDir -ExpectedBranch $branch -ExpectedHead $head | Write-Output
}

$includeNativeDnsSdAcceptance = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeNativeDnsSdAcceptance" -Context "acceptance.parameters") -Context "acceptance.parameters.includeNativeDnsSdAcceptance"
$requireNativeDnsSdPeer = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireNativeDnsSdPeer" -Context "acceptance.parameters") -Context "acceptance.parameters.requireNativeDnsSdPeer"
if ($RequireNativeDnsSdAcceptance) {
    Assert-True -Condition ($includeNativeDnsSdAcceptance -or $requireNativeDnsSdPeer) -Message "Acceptance must include native DNS-SD acceptance when -RequireNativeDnsSdAcceptance is passed."
    Assert-PassedGate -Name "windows-native-dns-sd-acceptance" | Out-Null
}
elseif ($includeNativeDnsSdAcceptance -or $requireNativeDnsSdPeer) {
    Assert-PassedGate -Name "windows-native-dns-sd-acceptance" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "windows-native-dns-sd-acceptance" | Out-Null
}

$checkOnlineStackFreshness = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "checkOnlineStackFreshness" -Context "acceptance.parameters") -Context "acceptance.parameters.checkOnlineStackFreshness"
$stackFreshnessPath = Get-OverrideOrJsonPath -OverridePath $StackFreshnessEvidencePath -EvidencePaths $evidencePaths -PropertyName "stackFreshnessEvidencePath"
if ($RequireOnlineStackFreshness) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "checkOnlineStackFreshness" -Expected $true
}
if ($RequireOnlineStackFreshness -or $checkOnlineStackFreshness) {
    $stackEvidence = Read-JsonFile -Path $stackFreshnessPath -Context "Windows stack freshness"
    Assert-True -Condition ((ConvertTo-Boolean -Value (Assert-JsonProperty -Object $stackEvidence -Name "checkOnline" -Context "stackFreshness") -Context "stackFreshness.checkOnline") -eq $true) -Message "Stack freshness evidence must be online evidence."
    $sourceUris = Assert-JsonProperty -Object $stackEvidence -Name "sourceUris" -Context "stackFreshness"
    Assert-True -Condition (@($sourceUris.PSObject.Properties).Count -ge 7) -Message "Stack freshness evidence must include primary source URIs."
    $online = Assert-JsonProperty -Object $stackEvidence -Name "online" -Context "stackFreshness"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string](Assert-JsonProperty -Object (Assert-JsonProperty -Object $online -Name "dotnet10" -Context "stackFreshness.online") -Name "latestRuntime" -Context "stackFreshness.online.dotnet10"))) -Message "Stack freshness online evidence missing dotnet latest runtime."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string](Assert-JsonProperty -Object (Assert-JsonProperty -Object $online -Name "nugetLatestStable" -Context "stackFreshness.online") -Name "MicrosoftWindowsAppSdk" -Context "stackFreshness.online.nugetLatestStable"))) -Message "Stack freshness online evidence missing Windows App SDK latest version."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string](Assert-JsonProperty -Object (Assert-JsonProperty -Object (Assert-JsonProperty -Object $online -Name "githubLatestStable" -Context "stackFreshness.online") -Name "MsQuic" -Context "stackFreshness.online.githubLatestStable") -Name "tagName" -Context "stackFreshness.online.githubLatestStable.MsQuic"))) -Message "Stack freshness online evidence missing MsQuic latest tag."
}

$includeRustCliCoverage = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeRustCliCoverage" -Context "acceptance.parameters") -Context "acceptance.parameters.includeRustCliCoverage"
$rustCoveragePath = Get-OverrideOrJsonPath -OverridePath $RustCliCoverageEvidencePath -EvidencePaths $evidencePaths -PropertyName "rustCliCoverageEvidencePath"
if ($RequireRustCliCoverage) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "includeRustCliCoverage" -Expected $true
}
if ($RequireRustCliCoverage -or $includeRustCliCoverage) {
    Assert-PassedGate -Name "rust-cli-coverage" | Out-Null
    $coverageEvidence = Read-JsonFile -Path $rustCoveragePath -Context "Rust CLI coverage"
    Assert-True -Condition ([string](Assert-JsonProperty -Object $coverageEvidence -Name "status" -Context "rustCoverage") -eq "passed") -Message "Rust CLI coverage evidence must be passed."
    $totalLineCoverage = ConvertTo-DoubleInvariant -Value (Assert-JsonProperty -Object $coverageEvidence -Name "totalLineCoverage" -Context "rustCoverage") -Context "rustCoverage.totalLineCoverage"
    $cliLineCoverage = ConvertTo-DoubleInvariant -Value (Assert-JsonProperty -Object $coverageEvidence -Name "cliLineCoverage" -Context "rustCoverage") -Context "rustCoverage.cliLineCoverage"
    Assert-True -Condition ($totalLineCoverage -ge $MinimumLineCoverage) -Message "Rust total line coverage $totalLineCoverage% is below $MinimumLineCoverage%."
    Assert-True -Condition ($cliLineCoverage -ge $MinimumLineCoverage) -Message "Rust cli.rs line coverage $cliLineCoverage% is below $MinimumLineCoverage%."
    $commandResults = @((Assert-JsonProperty -Object $coverageEvidence -Name "commandResults" -Context "rustCoverage"))
    Assert-True -Condition ($commandResults.Count -ge 5) -Message "Rust CLI coverage evidence must include command results."
    $commandNames = @($commandResults | ForEach-Object { [string](Assert-JsonProperty -Object $_ -Name "name" -Context "rustCoverage.commandResults[]") })
    foreach ($requiredCommandName in @(
        "cargo fmt --all -- --check",
        "cargo clippy --all-targets --all-features -- -D warnings",
        "cargo build --lib",
        "cargo test"
    )) {
        Assert-True -Condition ($commandNames -contains $requiredCommandName) -Message "Rust CLI coverage evidence missing command result: $requiredCommandName"
    }
    Assert-True -Condition (@($commandNames | Where-Object { $_.StartsWith("cargo llvm-cov --fail-under-lines ", [StringComparison]::Ordinal) -and $_.EndsWith(" --summary-only", [StringComparison]::Ordinal) }).Count -eq 1) -Message "Rust CLI coverage evidence must include one cargo llvm-cov --fail-under-lines <threshold> --summary-only command result."
    foreach ($commandResult in $commandResults) {
        $commandName = [string](Assert-JsonProperty -Object $commandResult -Name "name" -Context "rustCoverage.commandResults[]")
        $exitCode = [int](Assert-JsonProperty -Object $commandResult -Name "exitCode" -Context "rustCoverage.commandResults[$commandName]")
        Assert-True -Condition ($exitCode -eq 0) -Message "Rust CLI coverage command failed in evidence: $commandName exitCode=$exitCode"
    }
}
else {
    Assert-PassedOrSkippedGate -Name "rust-cli-coverage" | Out-Null
}

$includeWindowsReverseSshRelayLifecycle = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "includeWindowsReverseSshRelayLifecycle" -Context "acceptance.parameters") -Context "acceptance.parameters.includeWindowsReverseSshRelayLifecycle"
$requireWindowsReverseSshRelayLifecycle = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireWindowsReverseSshRelayLifecycle" -Context "acceptance.parameters") -Context "acceptance.parameters.requireWindowsReverseSshRelayLifecycle"
$reverseSshRelayEvidencePath = Get-OverrideOrJsonPath -OverridePath $WindowsReverseSshRelayEvidencePath -EvidencePaths $evidencePaths -PropertyName "windowsReverseSshRelayEvidencePath"
if ($RequireWindowsReverseSshRelayLifecycle) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireWindowsReverseSshRelayLifecycle" -Expected $true
}
if ($RequireWindowsReverseSshRelayLifecycle -or $requireWindowsReverseSshRelayLifecycle) {
    Assert-PassedGate -Name "windows-reverse-ssh-relay-lifecycle" | Out-Null
    $reverseSshRelayEvidence = Read-JsonFile -Path $reverseSshRelayEvidencePath -Context "Windows reverse SSH relay lifecycle"
    foreach ($requiredRelayBooleanField in @(
        "accepted",
        "taskActionExpected",
        "taskActionFailClosed",
        "taskPrincipalExpected",
        "relayHostKeyPinned",
        "identityFileAclOk",
        "knownHostsAclOk",
        "installedStartScriptAclOk",
        "startScriptInstalledAndCurrent",
        "runtimeAclOk",
        "localSshEndpointReachable"
    )) {
        $fieldValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name $requiredRelayBooleanField -Context "reverseSshRelay") -Context "reverseSshRelay.$requiredRelayBooleanField"
        Assert-True -Condition ($fieldValue -eq $true) -Message "Windows reverse SSH relay evidence must have $requiredRelayBooleanField=true."
    }
    $relayProcessCount = [System.Convert]::ToInt32((Assert-JsonProperty -Object $reverseSshRelayEvidence -Name "sshProcessCount" -Context "reverseSshRelay"), [Globalization.CultureInfo]::InvariantCulture)
    Assert-True -Condition ($relayProcessCount -eq 1) -Message "Required Windows reverse SSH relay evidence must include exactly one matching ssh.exe process."
    $relayProcessOwnerExpected = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name "sshProcessOwnerExpected" -Context "reverseSshRelay") -Context "reverseSshRelay.sshProcessOwnerExpected"
    Assert-True -Condition ($relayProcessOwnerExpected -eq $true) -Message "Required Windows reverse SSH relay evidence must prove matching ssh.exe belongs to the task service account."
    $relayRequireRunning = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name "requireRunning" -Context "reverseSshRelay") -Context "reverseSshRelay.requireRunning"
    Assert-True -Condition ($relayRequireRunning -eq $true) -Message "Required Windows reverse SSH relay evidence must be generated with RequireRunning=true."
}
elseif ($includeWindowsReverseSshRelayLifecycle) {
    Assert-PassedGate -Name "windows-reverse-ssh-relay-lifecycle" | Out-Null
    $reverseSshRelayEvidence = Read-JsonFile -Path $reverseSshRelayEvidencePath -Context "Windows reverse SSH relay lifecycle"
    foreach ($optionalRelayBooleanField in @("accepted", "taskActionExpected", "taskActionFailClosed", "taskPrincipalExpected", "relayHostKeyPinned", "identityFileAclOk", "knownHostsAclOk", "installedStartScriptAclOk", "startScriptInstalledAndCurrent", "runtimeAclOk", "localSshEndpointReachable")) {
        $fieldValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $reverseSshRelayEvidence -Name $optionalRelayBooleanField -Context "reverseSshRelay") -Context "reverseSshRelay.$optionalRelayBooleanField"
        Assert-True -Condition ($fieldValue -eq $true) -Message "Included Windows reverse SSH relay evidence must have $optionalRelayBooleanField=true."
    }
}
else {
    Assert-PassedOrSkippedGate -Name "windows-reverse-ssh-relay-lifecycle" | Out-Null
}

$probeMacSsh = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "probeMacSsh" -Context "acceptance.parameters") -Context "acceptance.parameters.probeMacSsh"
$requireMacSshReady = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacSshReady" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacSshReady"
$requireMacDirectLan = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacDirectLan" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacDirectLan"
$requireMacRustCliSmoke = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacRustCliSmoke" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacRustCliSmoke"
$requireMacWebRtcInterop = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $parameters -Name "requireMacWebRtcInterop" -Context "acceptance.parameters") -Context "acceptance.parameters.requireMacWebRtcInterop"

if ($probeMacSsh -or $requireMacSshReady -or $requireMacDirectLan -or $requireMacRustCliSmoke) {
    Assert-PassedGate -Name "mac-ssh-readiness" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "mac-ssh-readiness" | Out-Null
}

if ($requireMacWebRtcInterop) {
    Assert-PassedGate -Name "windows-mac-webrtc-interop" | Out-Null
}
else {
    Assert-PassedOrSkippedGate -Name "windows-mac-webrtc-interop" | Out-Null
}

if ($RequireMacInterop) {
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacSshReady" -Expected $true
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacDirectLan" -Expected $true
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacRustCliSmoke" -Expected $true
    Assert-RequiredBooleanParameter -Parameters $parameters -Name "requireMacWebRtcInterop" -Expected $true
    Assert-PassedGate -Name "mac-ssh-readiness" | Out-Null
    Assert-PassedGate -Name "windows-mac-webrtc-interop" | Out-Null

    $macEvidencePath = Get-OverrideOrJsonPath -OverridePath $MacSshEvidencePath -EvidencePaths $evidencePaths -PropertyName "macSshEvidencePath"
    $macEvidence = Read-JsonFile -Path $macEvidencePath -Context "Mac SSH readiness"
    foreach ($macBooleanField in @("ready", "directLanLikely", "hostKeyPinned")) {
        $fieldValue = ConvertTo-Boolean -Value (Assert-JsonProperty -Object $macEvidence -Name $macBooleanField -Context "macSsh") -Context "macSsh.$macBooleanField"
        Assert-True -Condition ($fieldValue -eq $true) -Message "Mac SSH evidence must have $macBooleanField=true."
    }

    $macRustCliSmoke = Assert-JsonProperty -Object $macEvidence -Name "rustCliSmoke" -Context "macSsh"
    Assert-True -Condition ([string](Assert-JsonProperty -Object $macRustCliSmoke -Name "status" -Context "macSsh.rustCliSmoke") -eq "passed") -Message "Mac SSH evidence must include passed rustCliSmoke status."
    $macRustExitCode = [System.Convert]::ToInt32((Assert-JsonProperty -Object $macRustCliSmoke -Name "exitCode" -Context "macSsh.rustCliSmoke"), [Globalization.CultureInfo]::InvariantCulture)
    Assert-True -Condition ($macRustExitCode -eq 0) -Message "Mac SSH evidence must include rustCliSmoke exitCode=0."
    $macRustCliCommand = [string](Assert-JsonProperty -Object $macRustCliSmoke -Name "command" -Context "macSsh.rustCliSmoke")
    Assert-True -Condition ($macRustCliCommand -match "transport select --local macos --remote ios --path same-lan") -Message "Mac Rust CLI smoke evidence must prove the transport-select command."
    $macRustExpectedSignals = @((Assert-JsonProperty -Object $macRustCliSmoke -Name "expectedSignals" -Context "macSsh.rustCliSmoke"))
    $macRustActualSignals = @((Assert-JsonProperty -Object $macRustCliSmoke -Name "actualSignals" -Context "macSsh.rustCliSmoke"))
    foreach ($expectedSignal in @("kind=AppleNative", "audit=AppleNativeDefault", "relay_allowed=false")) {
        Assert-True -Condition ($macRustExpectedSignals -contains $expectedSignal) -Message "Mac Rust CLI smoke evidence missing expected signal: $expectedSignal"
        Assert-True -Condition ($macRustActualSignals -contains $expectedSignal) -Message "Mac Rust CLI smoke evidence missing actual signal: $expectedSignal"
    }
    Assert-True -Condition ([string](Assert-JsonProperty -Object $macRustCliSmoke -Name "actualOutputSha256" -Context "macSsh.rustCliSmoke") -match '^[0-9a-f]{64}$') -Message "Mac Rust CLI smoke evidence must include actualOutputSha256."

    $macWebRtcProofPath = [string](Assert-JsonProperty -Object $evidencePaths -Name "macWebRtcProofPath" -Context "acceptance.evidencePaths")
    $resolvedMacWebRtcProofPath = Resolve-EvidencePath -Path $macWebRtcProofPath
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedMacWebRtcProofPath)) -Message "Mac WebRTC proof evidence path is empty."
    Assert-True -Condition (Test-Path -LiteralPath $resolvedMacWebRtcProofPath) -Message "Mac WebRTC proof file is missing: $resolvedMacWebRtcProofPath"
}

Write-Output "windows-portability-acceptance-evidence: ok path=$resolvedAcceptanceEvidencePath branch=$branch head=$head gates=$($script:AcceptanceGateResults.Count)"
