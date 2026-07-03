param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SignalServerBaseUrl = "https://api.nebula-technologies.net",
    [Parameter(Mandatory = $true)]
    [string]$LocalDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$PeerDeviceId,
    [Parameter(Mandatory = $true)]
    [string]$PeerFingerprint,
    [string]$DeviceName = "Windows RuntimeSmoke",
    [string]$ConnectionCodeEnvVar = "SKYBRIDGE_CURRENT_PATH_CONNECTION_CODE",
    [string]$BearerTokenEnvVar = "SKYBRIDGE_CURRENT_PATH_BEARER_TOKEN",
    [string]$TenantIdEnvVar = "SKYBRIDGE_CURRENT_PATH_TENANT_ID",
    [string]$Mldsa65PrivateKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_MLDSA65_PRIVATE_KEY_BASE64",
    [string]$PeerMlKem768PublicKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    [string]$BindAddress = "",
    [string]$ClientVersion = "1.0.0",
    [string]$ProtocolVersion = "1",
    [int]$TimeoutSeconds = 180,
    [int]$SignalFileTimeoutSeconds = 30,
    [int]$RemoteAnswerTimeoutSeconds = 120,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-appcontrol-" + [guid]::NewGuid().ToString("N") + ".json")),
    [string]$SignalingDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-signaling-" + [guid]::NewGuid().ToString("N"))),
    [switch]$KeepEvidenceArtifacts
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
Assert-True -Condition ($RemoteAnswerTimeoutSeconds -gt 0) -Message "RemoteAnswerTimeoutSeconds must be positive."
Assert-True -Condition ($PeerFingerprint -match '^[0-9a-f]{64}$') -Message "PeerFingerprint must be 64 lowercase hex characters."
foreach ($item in @(
    @($ConnectionCodeEnvVar, "ConnectionCodeEnvVar"),
    @($BearerTokenEnvVar, "BearerTokenEnvVar"),
    @($TenantIdEnvVar, "TenantIdEnvVar"),
    @($Mldsa65PrivateKeyBase64EnvVar, "Mldsa65PrivateKeyBase64EnvVar"),
    @($PeerMlKem768PublicKeyBase64EnvVar, "PeerMlKem768PublicKeyBase64EnvVar")
)) {
    Assert-EnvName -Name $item[0] -Label $item[1]
}

$connectionCode = [Environment]::GetEnvironmentVariable($ConnectionCodeEnvVar)
$bearerToken = [Environment]::GetEnvironmentVariable($BearerTokenEnvVar)
$tenantId = [Environment]::GetEnvironmentVariable($TenantIdEnvVar)
$privateKey = [Environment]::GetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar)
$peerKemPublicKey = [Environment]::GetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar)
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($connectionCode)) -Message "Set the ConnectionCodeEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($bearerToken)) -Message "Set the BearerTokenEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($tenantId)) -Message "Set the TenantIdEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($privateKey)) -Message "Set the Mldsa65PrivateKeyBase64EnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($peerKemPublicKey)) -Message "Set the PeerMlKem768PublicKeyBase64EnvVar environment variable before running this script."

$runtimeSmokeProject = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/Skybridge.WinClient.RuntimeSmoke.csproj"
$helperProject = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/Skybridge.WebRtcHelper.csproj"
Assert-True -Condition (Test-Path -LiteralPath $runtimeSmokeProject) -Message "Missing RuntimeSmoke project: $runtimeSmokeProject"
Assert-True -Condition (Test-Path -LiteralPath $helperProject) -Message "Missing WebRTC helper project: $helperProject"

$evidenceFullPath = [System.IO.Path]::GetFullPath($EvidencePath)
$evidenceDir = [System.IO.Path]::GetDirectoryName($evidenceFullPath)
if (-not [string]::IsNullOrWhiteSpace($evidenceDir)) {
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
}
New-Item -ItemType Directory -Force -Path $SignalingDir | Out-Null

try {
    Write-Host "windows-current-path-product-control-appcontrol-live: build-helper"
    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar, $null, "Process")
    dotnet build $helperProject -c $Configuration /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WebRTC helper build failed."

    Write-Host "windows-current-path-product-control-appcontrol-live: build-runtime-smoke"
    dotnet build $runtimeSmokeProject -c $Configuration /p:EnableWindowsTargeting=true /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke build failed."

    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $connectionCode, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $bearerToken, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $tenantId, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $privateKey, "Process")
    [Environment]::SetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar, $peerKemPublicKey, "Process")

    $helperExe = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/bin/$Configuration/net10.0/skybridge-webrtc-helper.exe"
    Assert-True -Condition (Test-Path -LiteralPath $helperExe) -Message "Missing built helper exe: $helperExe"

    $runtimeArgs = @(
        "--profile", "current-path-product-control-appcontrol",
        "--signal-server-base-url", $SignalServerBaseUrl,
        "--helper-path", $helperExe,
        "--signaling-dir", $SignalingDir,
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
        "--peer-mlkem768-public-key-base64-env", $PeerMlKem768PublicKeyBase64EnvVar,
        "--client-version", $ClientVersion,
        "--protocol-version", $ProtocolVersion,
        "--signal-file-timeout-seconds", "$SignalFileTimeoutSeconds",
        "--remote-answer-timeout-seconds", "$RemoteAnswerTimeoutSeconds",
        "--evidence-out", $evidenceFullPath,
        "--timeout-seconds", "$TimeoutSeconds")
    if (-not [string]::IsNullOrWhiteSpace($BindAddress)) {
        $runtimeArgs += @("--bind-address", $BindAddress)
    }

    Write-Host "windows-current-path-product-control-appcontrol-live: run-profile"
    dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- @runtimeArgs
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke current-path product-control AppControl profile failed."

    Assert-True -Condition (Test-Path -LiteralPath $evidenceFullPath) -Message "Missing product-control AppControl evidence: $evidenceFullPath"
    $evidenceText = Get-Content -LiteralPath $evidenceFullPath -Raw
    $evidence = $evidenceText | ConvertFrom-Json

    Assert-Equal -Expected "current-path-product-control-appcontrol" -Actual $evidence.Profile -Message "Unexpected evidence profile."
    Assert-Equal -Expected "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong" -Actual $evidence.EvidenceScope -Message "Unexpected evidence scope."
    Assert-Equal -Expected "appControlPong" -Actual $evidence.Status -Message "Unexpected evidence status."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AdmissionChallenge -Message "Admission challenge did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AdmissionLease -Message "Admission lease did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.LookupCode -Message "Lookup code did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.SignalingBound -Message "Signaling bind did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.ProductControlTransport -Message "Product-control transport did not open."
    Assert-Equal -Expected $true -Actual $evidence.Steps.ProductHandshake -Message "Product handshake did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AppControlPingPong -Message "AppControl ping/pong did not complete."
    Assert-Equal -Expected "Established" -Actual $evidence.SecureSessionState -Message "Unexpected secure-session state."
    Assert-Equal -Expected "skybridge" -Actual $evidence.DataChannelLabel -Message "Unexpected data-channel label."
    Assert-Equal -Expected "offer" -Actual $evidence.Role -Message "Windows live profile should run as the offerer for a Mac product connection code."
    Assert-Equal -Expected "0x0101" -Actual $evidence.NegotiatedSuiteWireId -Message "Unexpected negotiated suite."
    Assert-Equal -Expected $true -Actual $evidence.PolicyRequirePqc -Message "PQC policy must be required."
    Assert-Equal -Expected $false -Actual $evidence.PolicyAllowClassicFallback -Message "Classic fallback must be disabled."
    Assert-Equal -Expected $true -Actual $evidence.ResponderIdentityFingerprintVerified -Message "Responder identity was not verified."
    Assert-Equal -Expected $true -Actual $evidence.ResponderSignatureVerified -Message "Responder signature was not verified."
    Assert-Equal -Expected $true -Actual $evidence.ResponderFinishedVerified -Message "Responder Finished was not verified."
    Assert-Equal -Expected $true -Actual $evidence.InitiatorFinishedSent -Message "Initiator Finished was not sent."
    Assert-Equal -Expected "AppControl" -Actual $evidence.AppControlPacketType -Message "Unexpected AppControl packet type."
    Assert-Equal -Expected "pong" -Actual $evidence.AppControlReceivedMessageKind -Message "Expected an AppControl pong."
    Assert-Equal -Expected $true -Actual $evidence.AppControlPongIdMatches -Message "Pong id did not match ping id."
    Assert-Equal -Expected 1 -Actual $evidence.ProductSendCount -Message "AppControl gate should send one ping."
    Assert-Equal -Expected 1 -Actual $evidence.ProductReceiveCount -Message "AppControl gate should receive one pong."
    Assert-Equal -Expected $true -Actual $evidence.Bound -Message "Expected bound evidence."
    Assert-Equal -Expected $false -Actual $evidence.QueryTokenPresent -Message "Query token must not be present."
    Assert-Equal -Expected $false -Actual $evidence.HeaderValuesCaptured -Message "Header values must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.SecretInputsCaptured -Message "Secret inputs must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.ConnectionCodeCaptured -Message "Connection code value must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.PeerMlKem768PublicKeyCaptured -Message "Peer KEM public key value must not be captured."
    Assert-Equal -Expected $false -Actual (($evidence.PSObject.Properties.Name -contains "ConnectionCodeSha256")) -Message "Connection code hash must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.NotHandshakeProof -Message "Evidence must claim handshake proof after verification."
    Assert-Equal -Expected $false -Actual $evidence.NotAppControlProof -Message "Evidence must claim AppControl proof after verification."
    Assert-Equal -Expected $false -Actual $evidence.NotMacProductAppProof -Message "Evidence must claim Mac product App proof only after authenticated AppControl pong."

    foreach ($secret in @($connectionCode, $bearerToken, $tenantId, $privateKey, $peerKemPublicKey)) {
        Assert-Equal -Expected $false -Actual $evidenceText.Contains($secret) -Message "Evidence leaked a raw secret or key input."
    }

    Write-Host "windows-current-path-product-control-appcontrol-live: evidence=$evidenceFullPath"
    Write-Host "windows-current-path-product-control-appcontrol-live: ok"
} finally {
    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $connectionCode, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $bearerToken, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $tenantId, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $privateKey, "Process")
    [Environment]::SetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar, $peerKemPublicKey, "Process")
    if (-not $KeepEvidenceArtifacts -and (Test-Path -LiteralPath $SignalingDir)) {
        Remove-Item -LiteralPath $SignalingDir -Recurse -Force
    }
}
