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
    [switch]$ImportProductControlSession,
    [string]$SessionImportStateDir = "",
    [string]$SessionImportReportPath = "",
    [string]$SessionImportTargetRuntimeId = "",
    [ValidateRange(1, 86400)]
    [int]$SessionImportTtlSeconds = 3600,
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
$secretEnvironmentSnapshot = Save-WindowsCurrentPathProcessEnvironment -Names @(
    $ConnectionCodeEnvVar,
    $BearerTokenEnvVar,
    $TenantIdEnvVar,
    $Mldsa65PrivateKeyBase64EnvVar,
    $PeerMlKem768PublicKeyBase64EnvVar)
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
if ([string]::IsNullOrWhiteSpace($evidenceDir)) {
    $evidenceDir = (Get-Location).Path
}
if (-not [string]::IsNullOrWhiteSpace($evidenceDir)) {
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
}
$signalingFullPath = [System.IO.Path]::GetFullPath($SignalingDir)
$createdSignalingDir = -not (Test-Path -LiteralPath $signalingFullPath)
$signalingFullPath = New-WindowsCurrentPathSignalingDirectory -Directory $signalingFullPath
$generatedSignalingDirPrefix = "skybridge-current-path-product-control-signaling-"
$canRemoveSignalingDir = $createdSignalingDir -and [System.IO.Path]::GetFileName($signalingFullPath).StartsWith($generatedSignalingDirPrefix, [StringComparison]::OrdinalIgnoreCase)
$sessionImportStateFullPath = ""
$sessionImportReportFullPath = ""
$sessionImportSessionIdDir = ""
$sessionImportSessionIdPath = ""
$removeSessionImportSessionIdDir = $false
if ($ImportProductControlSession) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($SessionImportStateDir)) -Message "SessionImportStateDir is required when ImportProductControlSession is enabled."
    $sessionImportStateFullPath = New-WindowsCurrentPathSessionImportStateDirectory -Directory ([System.IO.Path]::GetFullPath($SessionImportStateDir))
    if (-not [string]::IsNullOrWhiteSpace($SessionImportTargetRuntimeId)) {
        Assert-WindowsCurrentPathOperatorBindingText -Value $SessionImportTargetRuntimeId -Label "SessionImportTargetRuntimeId"
    }

    if ([string]::IsNullOrWhiteSpace($SessionImportReportPath)) {
        $sessionImportReportFullPath = Join-Path $evidenceDir (([System.IO.Path]::GetFileNameWithoutExtension($evidenceFullPath)) + ".session-import.json")
    }
    else {
        $sessionImportReportFullPath = [System.IO.Path]::GetFullPath($SessionImportReportPath)
    }
    $sessionImportReportDir = [System.IO.Path]::GetDirectoryName($sessionImportReportFullPath)
    if (-not [string]::IsNullOrWhiteSpace($sessionImportReportDir)) {
        New-Item -ItemType Directory -Force -Path $sessionImportReportDir | Out-Null
    }

    $sessionImportSessionIdDir = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-session-id-" + [guid]::NewGuid().ToString("N"))
    $sessionImportSessionIdDir = New-WindowsCurrentPathSessionIdSecretDirectory -Directory $sessionImportSessionIdDir
    $sessionImportSessionIdPath = Join-Path $sessionImportSessionIdDir "session-id.txt"
    $removeSessionImportSessionIdDir = $true
}

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
    if ($ImportProductControlSession) {
        $runtimeArgs += @("--session-id-out", $sessionImportSessionIdPath)
    }

    Write-Host "windows-current-path-product-control-appcontrol-live: run-profile"
    dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- @runtimeArgs
    $runtimeSmokeExitCode = $LASTEXITCODE
    Restore-WindowsCurrentPathProcessEnvironment -Snapshot $secretEnvironmentSnapshot
    Assert-True -Condition ($runtimeSmokeExitCode -eq 0) -Message "RuntimeSmoke current-path product-control AppControl profile failed."

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
    Assert-Equal -Expected "SkybridgeSecureEnvelopeV1" -Actual $evidence.AppControlPayloadFormat -Message "Unexpected AppControl payload format."
    Assert-Equal -Expected "SkybridgeSecureEnvelopeV1" -Actual $evidence.AppControlCryptoFormat -Message "Unexpected AppControl crypto format."
    Assert-Equal -Expected $true -Actual $evidence.AppControlSbwcEnvelope -Message "AppControl proof must use the SBWC secure envelope."
    Assert-Equal -Expected $true -Actual $evidence.AppControlSbwcCounterPresent -Message "SBWC AppControl proof must record counters."
    Assert-Equal -Expected "sbwc-replay-window" -Actual $evidence.AppControlReplayProtection -Message "SBWC AppControl replay boundary must be explicit."
    Assert-Equal -Expected $null -Actual $evidence.AppControlLegacyNonceLength -Message "SBWC AppControl must not record a legacy nonce length."
    Assert-Equal -Expected $null -Actual $evidence.AppControlLegacyTagLength -Message "SBWC AppControl must not record a legacy tag length."
    Assert-Equal -Expected $null -Actual $evidence.AppControlLegacyAadLength -Message "SBWC AppControl must not record a legacy AAD length."
    Assert-Equal -Expected $null -Actual $evidence.AppControlLegacyCombinedLayout -Message "SBWC AppControl must not record a legacy combined layout."
    Assert-Equal -Expected "skybridge" -Actual $evidence.DataChannelLabel -Message "Unexpected data-channel label."
    Assert-Equal -Expected "offer" -Actual $evidence.Role -Message "Windows live profile should run as the offerer for a Mac product connection code."
    Assert-Equal -Expected "answer" -Actual $evidence.RemoteSignalWaitType -Message "Unexpected remote signal wait type."
    Assert-Equal -Expected $RemoteAnswerTimeoutSeconds -Actual $evidence.RemoteSignalTimeoutSeconds -Message "Unexpected remote signal timeout."
    Assert-True -Condition ($evidence.PSObject.Properties.Name -contains "LateRemoteIceCandidateRelayCount") -Message "Evidence must record late remote ICE relay count."
    Assert-True -Condition ([int]$evidence.LateRemoteIceCandidateRelayCount -ge 0) -Message "Late remote ICE relay count must be non-negative."
    Assert-Equal -Expected "0x0101" -Actual $evidence.NegotiatedSuiteWireId -Message "Unexpected negotiated suite."
    Assert-Equal -Expected $true -Actual $evidence.PolicyRequirePqc -Message "PQC policy must be required."
    Assert-Equal -Expected $false -Actual $evidence.PolicyAllowClassicFallback -Message "Classic fallback must be disabled."
    Assert-Equal -Expected $true -Actual $evidence.ResponderIdentityFingerprintVerified -Message "Responder identity was not verified."
    Assert-Equal -Expected $true -Actual $evidence.ResponderSignatureVerified -Message "Responder signature was not verified."
    Assert-Equal -Expected $true -Actual $evidence.ResponderFinishedVerified -Message "Responder Finished was not verified."
    Assert-Equal -Expected $true -Actual $evidence.InitiatorFinishedSent -Message "Initiator Finished was not sent."
    Assert-Equal -Expected "AppControl" -Actual $evidence.AppControlPacketType -Message "Unexpected AppControl packet type."
    Assert-True -Condition ($null -ne $evidence.AppControlOutboundCounter) -Message "SBWC AppControl must record outbound counter."
    Assert-True -Condition ($null -ne $evidence.AppControlInboundCounter) -Message "SBWC AppControl must record inbound counter."
    Assert-True -Condition ($null -ne $evidence.AppControlSessionHash) -Message "SBWC AppControl must record session hash."
    Assert-True -Condition ($null -ne $evidence.AppControlTranscriptPrefix) -Message "SBWC AppControl must record transcript prefix."
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
    Assert-Equal -Expected "operatorProvidedOutOfBand" -Actual $evidence.PeerMlKem768PublicKeySource -Message "Peer KEM public key source must remain explicit."
    Assert-Equal -Expected $false -Actual $evidence.PeerMlKem768PublicKeyServerAttested -Message "AppControl gate must not claim server-attested peer KEM key material."
    Assert-Equal -Expected $false -Actual (($evidence.PSObject.Properties.Name -contains "ConnectionCodeSha256")) -Message "Connection code hash must not be captured."
    Assert-Equal -Expected $true -Actual $evidence.AuthenticatedAppControlPingPongProof -Message "AppControl ping/pong proof must be authenticated."
    Assert-Equal -Expected $false -Actual $evidence.RemoteProductAppObserved -Message "AppControl gate must not claim remote product-app observation."
    Assert-Equal -Expected $false -Actual $evidence.PeerTrustPersistenceProof -Message "AppControl gate must not claim persisted peer trust."
    Assert-Equal -Expected $false -Actual $evidence.NotHandshakeProof -Message "Evidence must claim handshake proof after verification."
    Assert-Equal -Expected $false -Actual $evidence.NotAppControlProof -Message "Evidence must claim AppControl proof after verification."
    Assert-Equal -Expected $true -Actual $evidence.NotMacProductAppProof -Message "Evidence must not overclaim Mac product App proof."

    foreach ($secret in @($connectionCode, $bearerToken, $tenantId, $privateKey, $peerKemPublicKey)) {
        Assert-Equal -Expected $false -Actual $evidenceText.Contains($secret) -Message "Evidence leaked a raw secret or key input."
    }

    if ($ImportProductControlSession) {
        Assert-True -Condition (Test-Path -LiteralPath $sessionImportSessionIdPath -PathType Leaf) -Message "RuntimeSmoke did not write the protected session id output file."
        $sessionImportSessionId = Read-WindowsCurrentPathSecretLineFile -Path $sessionImportSessionIdPath -Label "Session id file"
        Assert-True -Condition ([string]$evidence.SessionIdSha256 -match '^[0-9a-f]{64}$') -Message "Evidence SessionIdSha256 is missing or invalid."
        Assert-True -Condition ([string]$evidence.RemoteDeviceIdSha256 -match '^[0-9a-f]{64}$') -Message "Evidence RemoteDeviceIdSha256 is missing or invalid."
        Assert-Equal -Expected $PeerFingerprint -Actual $evidence.RemoteProtocolPublicKeyFingerprint -Message "Evidence remote protocol fingerprint did not match the expected peer fingerprint."
        Assert-Equal -Expected ([string]$evidence.SessionIdSha256) -Actual (Get-WindowsCurrentPathSha256Hex -Value $sessionImportSessionId) -Message "Protected session id file does not match evidence SessionIdSha256."
        Assert-Equal -Expected ([string]$evidence.RemoteDeviceIdSha256) -Actual (Get-WindowsCurrentPathSha256Hex -Value $PeerDeviceId) -Message "PeerDeviceId does not match evidence RemoteDeviceIdSha256."

        $importArgs = @(
            "session",
            "import-product-control",
            "--state-dir",
            $sessionImportStateFullPath,
            "--evidence",
            $evidenceFullPath,
            "--session-id-file",
            $sessionImportSessionIdPath,
            "--remote-device-id",
            $PeerDeviceId,
            "--ttl-seconds",
            "$SessionImportTtlSeconds",
            "--json"
        )
        if (-not [string]::IsNullOrWhiteSpace($SessionImportTargetRuntimeId)) {
            $importArgs += @("--target-runtime-id", $SessionImportTargetRuntimeId)
        }

        $importResult = Invoke-WindowsCurrentPathRustCli -RepoRoot $RepoRoot -CliArguments $importArgs -TimeoutSeconds $TimeoutSeconds
        $importCombinedOutput = "$($importResult.Stdout)`n$($importResult.Stderr)"
        Assert-WindowsCurrentPathTextDoesNotContain -Text $importCombinedOutput -Needles @(
            $sessionImportSessionId,
            $PeerDeviceId,
            $sessionImportStateFullPath,
            $evidenceFullPath,
            $sessionImportSessionIdPath,
            $PeerFingerprint,
            $connectionCode,
            $bearerToken,
            $tenantId,
            $privateKey,
            $peerKemPublicKey
        ) -Label "Rust session import output"
        Assert-True -Condition ($importResult.ExitCode -eq 0) -Message "Rust session import failed."
        Assert-True -Condition ([string]::IsNullOrWhiteSpace($importResult.Stderr)) -Message "Rust session import wrote stderr output."
        $importReportText = ([string]$importResult.Stdout).Trim()
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($importReportText)) -Message "Rust session import did not produce JSON output."
        $importReport = $importReportText | ConvertFrom-Json
        Assert-Equal -Expected $true -Actual $importReport.accepted -Message "Session import was not accepted."
        Assert-Equal -Expected "session_imported" -Actual $importReport.status -Message "Unexpected session import status."
        Assert-Equal -Expected $true -Actual $importReport.session_imported -Message "Session import did not mutate the registry."
        Assert-Equal -Expected $true -Actual $importReport.mutation_supported -Message "Session import mutation support was not reported."
        Assert-Equal -Expected $false -Actual $importReport.live_runtime_started -Message "Session import must not claim a live runtime start."
        Assert-Equal -Expected $true -Actual $importReport.session_id_file_used -Message "Session import must use the protected session id file path."
        Assert-Equal -Expected $true -Actual $importReport.session.product_control_secure_session_ready -Message "Imported session is not product-control ready."
        Assert-Equal -Expected $true -Actual $importReport.session.remote_identity_bound -Message "Imported session is missing the remote identity binding."
        Assert-Equal -Expected $true -Actual $importReport.proof_boundary.session_import_not_live_runtime_start -Message "Session import proof boundary missing runtime-start disclaimer."
        Assert-Equal -Expected $true -Actual $importReport.proof_boundary.request_registered_not_live_transfer -Message "Session import proof boundary missing file-transfer disclaimer."
        Assert-Equal -Expected $true -Actual $importReport.proof_boundary.request_registered_not_live_remote_apply -Message "Session import proof boundary missing remote-apply disclaimer."
        Assert-Equal -Expected $true -Actual $importReport.proof_boundary.raw_session_ids_redacted -Message "Session import report must redact raw session ids."
        Assert-WindowsCurrentPathTextDoesNotContain -Text $importReportText -Needles @(
            $sessionImportSessionId,
            $PeerDeviceId,
            $sessionImportStateFullPath,
            $evidenceFullPath,
            $sessionImportSessionIdPath,
            $PeerFingerprint
        ) -Label "Session import report"
        $importedSessionRegistry = Join-Path (Join-Path $sessionImportStateFullPath "runtime") "sessions.json"
        Assert-True -Condition (Test-Path -LiteralPath $importedSessionRegistry -PathType Leaf) -Message "Session import did not create runtime/sessions.json."
        Assert-WindowsCurrentPathNotReparsePath -Path $importedSessionRegistry -Label "Imported sessions registry"
        Set-Content -LiteralPath $sessionImportReportFullPath -Encoding UTF8 -Value $importReportText
        Write-Host "windows-current-path-product-control-appcontrol-live: import-report=$sessionImportReportFullPath"
    }

    Write-Host "windows-current-path-product-control-appcontrol-live: evidence=$evidenceFullPath"
    Write-Host "windows-current-path-product-control-appcontrol-live: ok"
} finally {
    Restore-WindowsCurrentPathProcessEnvironment -Snapshot $secretEnvironmentSnapshot
    if ($removeSessionImportSessionIdDir -and -not [string]::IsNullOrWhiteSpace($sessionImportSessionIdDir) -and (Test-Path -LiteralPath $sessionImportSessionIdDir)) {
        Remove-WindowsCurrentPathGeneratedDirectory -Directory $sessionImportSessionIdDir -RequiredLeafPrefix "skybridge-current-path-product-control-session-id-" -Label "Session id directory"
    }
    if (-not $KeepEvidenceArtifacts -and $canRemoveSignalingDir -and (Test-Path -LiteralPath $signalingFullPath)) {
        Remove-WindowsCurrentPathGeneratedDirectory -Directory $signalingFullPath -RequiredLeafPrefix "skybridge-current-path-product-control-signaling-" -Label "SignalingDir"
    }
}
