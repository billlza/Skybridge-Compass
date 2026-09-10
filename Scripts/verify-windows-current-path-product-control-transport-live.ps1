param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SignalServerBaseUrl = "https://api.nebula-technologies.net",
    [Parameter(Mandatory = $true)]
    [string]$LocalDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$PeerDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$PeerFingerprint,
    [ValidateSet("offer", "answer")]
    [string]$Role = "offer",
    [string]$DeviceName = "Windows RuntimeSmoke",
    [string]$ConnectionCodeEnvVar = "SKYBRIDGE_CURRENT_PATH_CONNECTION_CODE",
    [string]$BearerTokenEnvVar = "SKYBRIDGE_CURRENT_PATH_BEARER_TOKEN",
    [string]$TenantIdEnvVar = "SKYBRIDGE_CURRENT_PATH_TENANT_ID",
    [string]$Mldsa65PrivateKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_MLDSA65_PRIVATE_KEY_BASE64",
    [string]$BindAddress = "",
    [string]$ClientVersion = "1.0.0",
    [string]$ProtocolVersion = "1",
    [ValidateSet("initiator", "responder")]
    [string]$ExpectedBoundRole = "responder",
    [int]$TtlSeconds = 300,
    [int]$TimeoutSeconds = 180,
    [int]$SignalFileTimeoutSeconds = 30,
    [int]$RemoteOfferTimeoutSeconds = 120,
    [int]$RemoteAnswerTimeoutSeconds = 120,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-transport-" + [guid]::NewGuid().ToString("N") + ".json")),
    [string]$RegisteredCodeOutPath = "",
    [string]$SignalingDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-signaling-" + [guid]::NewGuid().ToString("N"))),
    [switch]$KeepEvidenceArtifacts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$fileSystemHelpers = Join-Path $PSScriptRoot "windows-current-path-live-gate-file-system.ps1"
. $fileSystemHelpers

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected='$Expected' Actual='$Actual'"
    }
}

function Assert-EnvName {
    param(
        [string]$Name,
        [string]$Label
    )

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Name)) -Message "$Label must not be empty."
    Assert-True -Condition ($Name -match '^[A-Za-z0-9_]+$') -Message "$Label must contain only letters, digits, or underscores."
}

Assert-True -Condition ($TimeoutSeconds -gt 0) -Message "TimeoutSeconds must be positive."
Assert-True -Condition ($SignalFileTimeoutSeconds -gt 0) -Message "SignalFileTimeoutSeconds must be positive."
Assert-True -Condition ($RemoteOfferTimeoutSeconds -gt 0) -Message "RemoteOfferTimeoutSeconds must be positive."
Assert-True -Condition ($RemoteAnswerTimeoutSeconds -gt 0) -Message "RemoteAnswerTimeoutSeconds must be positive."
Assert-True -Condition ($TtlSeconds -gt 0) -Message "TtlSeconds must be positive."
Assert-True -Condition ($PeerFingerprint -match '^[0-9a-f]{64}$') -Message "PeerFingerprint must be 64 lowercase hex characters."
foreach ($item in @(
    @($ConnectionCodeEnvVar, "ConnectionCodeEnvVar"),
    @($BearerTokenEnvVar, "BearerTokenEnvVar"),
    @($TenantIdEnvVar, "TenantIdEnvVar"),
    @($Mldsa65PrivateKeyBase64EnvVar, "Mldsa65PrivateKeyBase64EnvVar")
)) {
    Assert-EnvName -Name $item[0] -Label $item[1]
}

$connectionCode = [Environment]::GetEnvironmentVariable($ConnectionCodeEnvVar)
$bearerToken = [Environment]::GetEnvironmentVariable($BearerTokenEnvVar)
$tenantId = [Environment]::GetEnvironmentVariable($TenantIdEnvVar)
$privateKey = [Environment]::GetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar)
$secretEnvironmentSnapshot = Save-WindowsCurrentPathProcessEnvironment -Names @(
    $ConnectionCodeEnvVar,
    $BearerTokenEnvVar,
    $TenantIdEnvVar,
    $Mldsa65PrivateKeyBase64EnvVar)
if ($Role -eq "offer") {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($connectionCode)) -Message "Set the ConnectionCodeEnvVar environment variable before running this script."
}
else {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedBoundRole)) -Message "ExpectedBoundRole is required for answerer transport evidence."
}
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($bearerToken)) -Message "Set the BearerTokenEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($tenantId)) -Message "Set the TenantIdEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($privateKey)) -Message "Set the Mldsa65PrivateKeyBase64EnvVar environment variable before running this script."

$runtimeSmokeProject = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/Skybridge.WinClient.RuntimeSmoke.csproj"
$helperProject = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/Skybridge.WebRtcHelper.csproj"
Assert-True -Condition (Test-Path -LiteralPath $runtimeSmokeProject) -Message "Missing RuntimeSmoke project: $runtimeSmokeProject"
Assert-True -Condition (Test-Path -LiteralPath $helperProject) -Message "Missing WebRTC helper project: $helperProject"

$evidenceFullPath = [System.IO.Path]::GetFullPath($EvidencePath)
$evidenceDir = [System.IO.Path]::GetDirectoryName($evidenceFullPath)
if (-not [string]::IsNullOrWhiteSpace($evidenceDir)) {
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
}
$signalingFullPath = [System.IO.Path]::GetFullPath($SignalingDir)
$createdSignalingDir = -not (Test-Path -LiteralPath $signalingFullPath)
$signalingFullPath = New-WindowsCurrentPathSignalingDirectory -Directory $signalingFullPath
$generatedSignalingDirPrefix = "skybridge-current-path-product-control-signaling-"
$canRemoveSignalingDir = $createdSignalingDir -and [System.IO.Path]::GetFileName($signalingFullPath).StartsWith($generatedSignalingDirPrefix, [StringComparison]::OrdinalIgnoreCase)
$registeredCodeFullPath = ""
$generatedRegisteredCodeDir = ""
$removeRegisteredCodeOutPath = $false
if ($Role -eq "answer") {
    if ([string]::IsNullOrWhiteSpace($RegisteredCodeOutPath)) {
        $generatedRegisteredCodeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-answerer-code-" + [guid]::NewGuid().ToString("N"))
        $registeredCodeFullPath = Join-Path $generatedRegisteredCodeDir "connection-code.txt"
        $removeRegisteredCodeOutPath = -not [bool]$KeepEvidenceArtifacts
    }
    else {
        $registeredCodeFullPath = [System.IO.Path]::GetFullPath($RegisteredCodeOutPath)
    }

    $registeredCodeDir = [System.IO.Path]::GetDirectoryName($registeredCodeFullPath)
    if (-not [string]::IsNullOrWhiteSpace($registeredCodeDir)) {
        $registeredCodeDir = New-WindowsCurrentPathOperatorSecretDirectory -Directory $registeredCodeDir
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $registeredCodeFullPath)) -Message "RegisteredCodeOutPath must not already exist; use a fresh dedicated directory for each live gate run: $registeredCodeFullPath"
}

try {
    Write-Host "windows-current-path-product-control-transport-live: build-helper"
    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $null, "Process")
    dotnet build $helperProject -c $Configuration /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WebRTC helper build failed."

    Write-Host "windows-current-path-product-control-transport-live: build-runtime-smoke"
    dotnet build $runtimeSmokeProject -c $Configuration /p:EnableWindowsTargeting=true /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke build failed."

    $connectionCodeForRuntime = if ($Role -eq "offer") { $connectionCode } else { $null }
    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $connectionCodeForRuntime, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $bearerToken, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $tenantId, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $privateKey, "Process")

    $helperExe = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/bin/$Configuration/net10.0/skybridge-webrtc-helper.exe"
    Assert-True -Condition (Test-Path -LiteralPath $helperExe) -Message "Missing built helper exe: $helperExe"

    $profile = if ($Role -eq "answer") { "current-path-product-control-answerer-transport" } else { "current-path-product-control-transport" }
    $remoteTimeoutSeconds = if ($Role -eq "answer") { $RemoteOfferTimeoutSeconds } else { $RemoteAnswerTimeoutSeconds }
    $remoteTimeoutArgumentName = if ($Role -eq "answer") { "--remote-offer-timeout-seconds" } else { "--remote-answer-timeout-seconds" }
    $runtimeArgs = @(
        "--profile", $profile,
        "--signal-server-base-url", $SignalServerBaseUrl,
        "--helper-path", $helperExe,
        "--signaling-dir", $signalingFullPath,
        "--offer-file", "offer.json",
        "--answer-file", "answer.json",
        "--peer-device-id", $PeerDeviceId,
        "--peer-fingerprint", $PeerFingerprint,
        "--local-device-id", $LocalDeviceId,
        "--device-name", $DeviceName,
        "--connection-code-env", $ConnectionCodeEnvVar,
        "--bearer-token-env", $BearerTokenEnvVar,
        "--tenant-id-env", $TenantIdEnvVar,
        "--mldsa65-private-key-base64-env", $Mldsa65PrivateKeyBase64EnvVar,
        "--client-version", $ClientVersion,
        "--protocol-version", $ProtocolVersion,
        "--ttl-seconds", "$TtlSeconds",
        "--signal-file-timeout-seconds", "$SignalFileTimeoutSeconds",
        $remoteTimeoutArgumentName, "$remoteTimeoutSeconds",
        "--evidence-out", $evidenceFullPath,
        "--timeout-seconds", "$TimeoutSeconds")
    if ($Role -eq "answer") {
        $runtimeArgs += @("--expected-bound-role", $ExpectedBoundRole)
        $runtimeArgs += @("--registered-code-out", $registeredCodeFullPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($BindAddress)) {
        $runtimeArgs += @("--bind-address", $BindAddress)
    }

    Write-Host "windows-current-path-product-control-transport-live: run-profile"
    dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- @runtimeArgs
    $runtimeSmokeExitCode = $LASTEXITCODE
    Restore-WindowsCurrentPathProcessEnvironment -Snapshot $secretEnvironmentSnapshot
    Assert-True -Condition ($runtimeSmokeExitCode -eq 0) -Message "RuntimeSmoke current-path product-control transport profile failed."

    Assert-True -Condition (Test-Path -LiteralPath $evidenceFullPath) -Message "Missing product-control transport evidence: $evidenceFullPath"
    $evidenceText = Get-Content -LiteralPath $evidenceFullPath -Raw
    $evidence = $evidenceText | ConvertFrom-Json

    $expectedProfile = if ($Role -eq "answer") { "current-path-product-control-answerer-transport" } else { "current-path-product-control-transport" }
    $expectedScope = if ($Role -eq "answer") { "AdmissionRegisterBoundSdpIceProductControlAnswererTransportOpen" } else { "AdmissionLookupBoundSdpIceProductControlTransportOpen" }
    $expectedSignalingExchangeRole = if ($Role -eq "answer") { "answerer" } else { "offerer" }
    $expectedHelperMode = if ($Role -eq "answer") { "product-control-answer" } else { "product-control-offer" }
    $expectedRemoteSignalWaitType = if ($Role -eq "answer") { "offer" } else { "answer" }
    Assert-Equal -Expected $expectedProfile -Actual $evidence.Profile -Message "Unexpected evidence profile."
    Assert-Equal -Expected $expectedScope -Actual $evidence.EvidenceScope -Message "Unexpected evidence scope."
    Assert-Equal -Expected "transportOpen" -Actual $evidence.Status -Message "Unexpected evidence status."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AdmissionChallenge -Message "Admission challenge did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AdmissionLease -Message "Admission lease did not complete."
    if ($Role -eq "answer") {
        Assert-Equal -Expected $true -Actual $evidence.Steps.RegisterCode -Message "Register code did not complete."
    }
    else {
        Assert-Equal -Expected $true -Actual $evidence.Steps.LookupCode -Message "Lookup code did not complete."
    }
    Assert-Equal -Expected $true -Actual $evidence.Steps.SignalingBound -Message "Signaling bind did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.ProductControlTransport -Message "Product-control transport did not open."
    Assert-Equal -Expected "TransportOnly" -Actual $evidence.SecureSessionState -Message "Unexpected secure-session state."
    Assert-Equal -Expected "skybridge" -Actual $evidence.DataChannelLabel -Message "Unexpected data-channel label."
    Assert-Equal -Expected $Role -Actual $evidence.Role -Message "Unexpected product-control transport role."
    Assert-Equal -Expected $expectedSignalingExchangeRole -Actual $evidence.SignalingExchangeRole -Message "Unexpected current-path signaling exchange role."
    Assert-Equal -Expected $expectedHelperMode -Actual $evidence.HelperMode -Message "Unexpected helper mode."
    Assert-Equal -Expected $expectedRemoteSignalWaitType -Actual $evidence.RemoteSignalWaitType -Message "Unexpected remote signal wait type."
    Assert-Equal -Expected $remoteTimeoutSeconds -Actual $evidence.RemoteSignalTimeoutSeconds -Message "Unexpected remote signal timeout."
    Assert-True -Condition ($evidence.PSObject.Properties.Name -contains "LateRemoteIceCandidateRelayCount") -Message "Evidence must record late remote ICE relay count."
    Assert-True -Condition ([int]$evidence.LateRemoteIceCandidateRelayCount -ge 0) -Message "Late remote ICE relay count must be non-negative."
    if ($Role -eq "answer") {
        Assert-Equal -Expected $ExpectedBoundRole -Actual $evidence.BoundRole -Message "Unexpected current-path bound role."
        Assert-Equal -Expected $ExpectedBoundRole -Actual $evidence.ExpectedBoundRole -Message "Unexpected expected bound role evidence."
        Assert-Equal -Expected "operatorExpectedPeerNotServerAttested" -Actual $evidence.RemoteIdentitySource -Message "Unexpected answerer remote identity source."
        Assert-Equal -Expected $false -Actual $evidence.RemoteIdentityServerAttested -Message "Answerer transport must not claim server-attested remote identity."
        Assert-Equal -Expected $true -Actual $evidence.NotRemoteIdentityProof -Message "Answerer transport must not claim remote identity proof."
        Assert-True -Condition (Test-Path -LiteralPath $registeredCodeFullPath) -Message "Registered code output file was not created."
        Assert-WindowsCurrentPathOperatorSecretFileProtected -Path $registeredCodeFullPath
        $registeredCodeText = Get-Content -Raw -LiteralPath $registeredCodeFullPath
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($registeredCodeText)) -Message "Registered code output file is empty."
        Assert-Equal -Expected $false -Actual $evidenceText.Contains($registeredCodeText.Trim()) -Message "Evidence leaked the registered connection code."
    }
    else {
        Assert-Equal -Expected "connectionCodeLookup" -Actual $evidence.RemoteIdentitySource -Message "Unexpected offerer remote identity source."
        Assert-Equal -Expected $true -Actual $evidence.RemoteIdentityServerAttested -Message "Offerer transport must use lookup-attested remote identity."
        Assert-Equal -Expected $false -Actual $evidence.NotRemoteIdentityProof -Message "Offerer transport should not set NotRemoteIdentityProof."
    }
    Assert-Equal -Expected $true -Actual $evidence.Bound -Message "Expected bound evidence."
    Assert-Equal -Expected $false -Actual $evidence.QueryTokenPresent -Message "Query token must not be present."
    Assert-Equal -Expected $false -Actual $evidence.HeaderValuesCaptured -Message "Header values must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.SecretInputsCaptured -Message "Secret inputs must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.ConnectionCodeCaptured -Message "Connection code value must not be captured."
    Assert-Equal -Expected $false -Actual (($evidence.PSObject.Properties.Name -contains "ConnectionCodeSha256")) -Message "Connection code hash must not be captured."
    Assert-Equal -Expected 0 -Actual $evidence.ProductSendCount -Message "Transport gate must not send AppControl payloads."
    Assert-Equal -Expected 0 -Actual $evidence.ProductReceiveCount -Message "Transport gate must not claim AppControl responses."
    Assert-Equal -Expected $true -Actual $evidence.NotHandshakeProof -Message "Evidence must not claim handshake proof."
    Assert-Equal -Expected $true -Actual $evidence.NotAppControlProof -Message "Evidence must not claim AppControl proof."
    Assert-Equal -Expected $true -Actual $evidence.NotMacProductAppProof -Message "Evidence must not claim Mac product App proof."

    foreach ($secret in (@($connectionCode, $bearerToken, $tenantId, $privateKey) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Assert-Equal -Expected $false -Actual $evidenceText.Contains($secret) -Message "Evidence leaked a raw secret or connection code."
    }

    Write-Host "windows-current-path-product-control-transport-live: evidence=$evidenceFullPath"
    Write-Host "windows-current-path-product-control-transport-live: ok"
} finally {
    Restore-WindowsCurrentPathProcessEnvironment -Snapshot $secretEnvironmentSnapshot
    if ($removeRegisteredCodeOutPath -and -not [string]::IsNullOrWhiteSpace($generatedRegisteredCodeDir) -and (Test-Path -LiteralPath $generatedRegisteredCodeDir)) {
        Remove-WindowsCurrentPathGeneratedDirectory -Directory $generatedRegisteredCodeDir -RequiredLeafPrefix "skybridge-current-path-product-control-answerer-code-" -Label "Registered code directory"
    }
    if (-not $KeepEvidenceArtifacts -and $canRemoveSignalingDir -and (Test-Path -LiteralPath $signalingFullPath)) {
        Remove-WindowsCurrentPathGeneratedDirectory -Directory $signalingFullPath -RequiredLeafPrefix "skybridge-current-path-product-control-signaling-" -Label "SignalingDir"
    }
}
