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
    [string]$PeerMlKem768PublicKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    [string]$LocalMlKem768DecapsulationKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_DECAPSULATION_KEY_BASE64",
    [string]$LocalMlKem768EncapsulationKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_LOCAL_MLKEM768_PUBLIC_KEY_BASE64",
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
    [ValidateRange(1, 2048)]
    [int]$FileTransferPayloadBytes = 1024,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-file-transfer-" + [guid]::NewGuid().ToString("N") + ".json")),
    [string]$RegisteredCodeOutPath = "",
    [string]$SignalingDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-signaling-" + [guid]::NewGuid().ToString("N"))),
    [switch]$KeepEvidenceArtifacts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$fileSystemHelpers = Join-Path $PSScriptRoot "windows-current-path-live-gate-file-system.ps1"
. $fileSystemHelpers

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected='$Expected' Actual='$Actual'" }
}

function Assert-EnvName {
    param([string]$Name, [string]$Label)
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
    @($Mldsa65PrivateKeyBase64EnvVar, "Mldsa65PrivateKeyBase64EnvVar"),
    @($PeerMlKem768PublicKeyBase64EnvVar, "PeerMlKem768PublicKeyBase64EnvVar"),
    @($LocalMlKem768DecapsulationKeyBase64EnvVar, "LocalMlKem768DecapsulationKeyBase64EnvVar"),
    @($LocalMlKem768EncapsulationKeyBase64EnvVar, "LocalMlKem768EncapsulationKeyBase64EnvVar")
)) {
    Assert-EnvName -Name $item[0] -Label $item[1]
}

$connectionCode = [Environment]::GetEnvironmentVariable($ConnectionCodeEnvVar)
$bearerToken = [Environment]::GetEnvironmentVariable($BearerTokenEnvVar)
$tenantId = [Environment]::GetEnvironmentVariable($TenantIdEnvVar)
$privateKey = [Environment]::GetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar)
$peerKemPublicKey = [Environment]::GetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar)
$localKemDecapsulationKey = [Environment]::GetEnvironmentVariable($LocalMlKem768DecapsulationKeyBase64EnvVar)
$localKemEncapsulationKey = [Environment]::GetEnvironmentVariable($LocalMlKem768EncapsulationKeyBase64EnvVar)
$secretEnvironmentSnapshot = Save-WindowsCurrentPathProcessEnvironment -Names @(
    $ConnectionCodeEnvVar,
    $BearerTokenEnvVar,
    $TenantIdEnvVar,
    $Mldsa65PrivateKeyBase64EnvVar,
    $PeerMlKem768PublicKeyBase64EnvVar,
    $LocalMlKem768DecapsulationKeyBase64EnvVar,
    $LocalMlKem768EncapsulationKeyBase64EnvVar)

if ($Role -eq "offer") {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($connectionCode)) -Message "Set the ConnectionCodeEnvVar environment variable before running this script."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($peerKemPublicKey)) -Message "Set the PeerMlKem768PublicKeyBase64EnvVar environment variable before running this script."
}
else {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($localKemDecapsulationKey)) -Message "Set the LocalMlKem768DecapsulationKeyBase64EnvVar environment variable before running this script."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($localKemEncapsulationKey)) -Message "Set the LocalMlKem768EncapsulationKeyBase64EnvVar environment variable before running this script."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($ExpectedBoundRole)) -Message "ExpectedBoundRole is required for answerer FileTransfer evidence."
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
    Write-Host "windows-current-path-product-control-file-transfer-live: build-helper"
    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($LocalMlKem768DecapsulationKeyBase64EnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($LocalMlKem768EncapsulationKeyBase64EnvVar, $null, "Process")
    dotnet build $helperProject -c $Configuration /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "WebRTC helper build failed."

    Write-Host "windows-current-path-product-control-file-transfer-live: build-runtime-smoke"
    dotnet build $runtimeSmokeProject -c $Configuration /p:EnableWindowsTargeting=true /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke build failed."

    $connectionCodeForRuntime = if ($Role -eq "offer") { $connectionCode } else { $null }
    $peerKemForRuntime = if ($Role -eq "offer") { $peerKemPublicKey } else { $null }
    $localKemDecapsulationForRuntime = if ($Role -eq "answer") { $localKemDecapsulationKey } else { $null }
    $localKemEncapsulationForRuntime = if ($Role -eq "answer") { $localKemEncapsulationKey } else { $null }
    [Environment]::SetEnvironmentVariable($ConnectionCodeEnvVar, $connectionCodeForRuntime, "Process")
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $bearerToken, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $tenantId, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $privateKey, "Process")
    [Environment]::SetEnvironmentVariable($PeerMlKem768PublicKeyBase64EnvVar, $peerKemForRuntime, "Process")
    [Environment]::SetEnvironmentVariable($LocalMlKem768DecapsulationKeyBase64EnvVar, $localKemDecapsulationForRuntime, "Process")
    [Environment]::SetEnvironmentVariable($LocalMlKem768EncapsulationKeyBase64EnvVar, $localKemEncapsulationForRuntime, "Process")

    $helperExe = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/bin/$Configuration/net10.0/skybridge-webrtc-helper.exe"
    Assert-True -Condition (Test-Path -LiteralPath $helperExe) -Message "Missing built helper exe: $helperExe"

    $profile = if ($Role -eq "answer") { "current-path-product-control-answerer-file-transfer" } else { "current-path-product-control-file-transfer" }
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
        "--file-transfer-payload-bytes", "$FileTransferPayloadBytes",
        "--evidence-out", $evidenceFullPath,
        "--timeout-seconds", "$TimeoutSeconds")
    if ($Role -eq "answer") {
        $runtimeArgs += @("--expected-bound-role", $ExpectedBoundRole)
        $runtimeArgs += @("--registered-code-out", $registeredCodeFullPath)
        $runtimeArgs += @("--local-mlkem768-decapsulation-key-base64-env", $LocalMlKem768DecapsulationKeyBase64EnvVar)
        $runtimeArgs += @("--local-mlkem768-encapsulation-key-base64-env", $LocalMlKem768EncapsulationKeyBase64EnvVar)
    }
    else {
        $runtimeArgs += @("--peer-mlkem768-public-key-base64-env", $PeerMlKem768PublicKeyBase64EnvVar)
    }
    if (-not [string]::IsNullOrWhiteSpace($BindAddress)) {
        $runtimeArgs += @("--bind-address", $BindAddress)
    }

    Write-Host "windows-current-path-product-control-file-transfer-live: run-profile"
    dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- @runtimeArgs
    $runtimeSmokeExitCode = $LASTEXITCODE
    Restore-WindowsCurrentPathProcessEnvironment -Snapshot $secretEnvironmentSnapshot
    Assert-True -Condition ($runtimeSmokeExitCode -eq 0) -Message "RuntimeSmoke current-path product-control FileTransfer profile failed."

    Assert-True -Condition (Test-Path -LiteralPath $evidenceFullPath) -Message "Missing product-control FileTransfer evidence: $evidenceFullPath"
    $evidenceText = Get-Content -LiteralPath $evidenceFullPath -Raw
    $evidence = $evidenceText | ConvertFrom-Json

    $expectedProfile = if ($Role -eq "answer") { "current-path-product-control-answerer-file-transfer" } else { "current-path-product-control-file-transfer" }
    $expectedScope = if ($Role -eq "answer") { "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeFileTransferReceipt" } else { "AdmissionLookupBoundSdpIceProductControlHandshakeFileTransferReceipt" }
    $expectedSignalingExchangeRole = if ($Role -eq "answer") { "answerer" } else { "offerer" }
    $expectedHelperMode = if ($Role -eq "answer") { "product-control-answer" } else { "product-control-offer" }
    $expectedRemoteSignalWaitType = if ($Role -eq "answer") { "offer" } else { "answer" }
    $expectedTransferRole = if ($Role -eq "answer") { "receiver" } else { "sender" }
    Assert-Equal -Expected $expectedProfile -Actual $evidence.Profile -Message "Unexpected evidence profile."
    Assert-Equal -Expected $expectedScope -Actual $evidence.EvidenceScope -Message "Unexpected evidence scope."
    Assert-Equal -Expected "fileTransferReceipt" -Actual $evidence.Status -Message "Unexpected evidence status."
    foreach ($stepName in @("AdmissionChallenge", "AdmissionLease", "SignalingBound", "ProductControlTransport", "ProductHandshake", "FileTransferReceipt")) {
        Assert-Equal -Expected $true -Actual $evidence.Steps.$stepName -Message "$stepName did not complete."
    }
    if ($Role -eq "answer") {
        Assert-Equal -Expected $true -Actual $evidence.Steps.RegisterCode -Message "Register code did not complete."
    }
    else {
        Assert-Equal -Expected $true -Actual $evidence.Steps.LookupCode -Message "Lookup code did not complete."
    }

    Assert-Equal -Expected "Established" -Actual $evidence.SecureSessionState -Message "Unexpected secure-session state."
    Assert-Equal -Expected "skybridge" -Actual $evidence.DataChannelLabel -Message "Unexpected data-channel label."
    Assert-Equal -Expected $Role -Actual $evidence.Role -Message "Unexpected product-control role."
    Assert-Equal -Expected $expectedSignalingExchangeRole -Actual $evidence.SignalingExchangeRole -Message "Unexpected signaling exchange role."
    Assert-Equal -Expected $expectedHelperMode -Actual $evidence.HelperMode -Message "Unexpected helper mode."
    Assert-Equal -Expected $expectedRemoteSignalWaitType -Actual $evidence.RemoteSignalWaitType -Message "Unexpected remote signal wait type."
    Assert-Equal -Expected $remoteTimeoutSeconds -Actual $evidence.RemoteSignalTimeoutSeconds -Message "Unexpected remote signal timeout."
    Assert-True -Condition ([int]$evidence.LateRemoteIceCandidateRelayCount -ge 0) -Message "Late remote ICE relay count must be non-negative."
    Assert-Equal -Expected "0x0101" -Actual $evidence.NegotiatedSuiteWireId -Message "Unexpected negotiated suite."
    Assert-Equal -Expected $true -Actual $evidence.PolicyRequirePqc -Message "PQC policy must be required."
    Assert-Equal -Expected $false -Actual $evidence.PolicyAllowClassicFallback -Message "Classic fallback must be disabled."
    Assert-Equal -Expected $false -Actual $evidence.NotHandshakeProof -Message "Evidence must claim handshake proof after verification."
    Assert-Equal -Expected $true -Actual $evidence.NotAppControlProof -Message "FileTransfer evidence must not claim AppControl proof."
    Assert-Equal -Expected $true -Actual $evidence.NotMacProductAppProof -Message "Evidence must not overclaim Mac/iOS product-app proof."

    if ($Role -eq "answer") {
        Assert-Equal -Expected $ExpectedBoundRole -Actual $evidence.BoundRole -Message "Unexpected current-path bound role."
        Assert-Equal -Expected $ExpectedBoundRole -Actual $evidence.ExpectedBoundRole -Message "Unexpected expected bound role evidence."
        Assert-Equal -Expected "responder" -Actual $evidence.HandshakeRole -Message "Unexpected handshake role."
        Assert-Equal -Expected $true -Actual $evidence.InitiatorIdentityFingerprintVerified -Message "Initiator identity was not verified."
        Assert-Equal -Expected $true -Actual $evidence.InitiatorSignatureVerified -Message "Initiator signature was not verified."
        Assert-Equal -Expected $true -Actual $evidence.ResponderFinishedSent -Message "Responder Finished was not sent."
        Assert-Equal -Expected $true -Actual $evidence.InitiatorFinishedVerified -Message "Initiator Finished was not verified."
        Assert-Equal -Expected "operatorExpectedPeerHandshakeVerifiedNotServerAttested" -Actual $evidence.RemoteIdentitySource -Message "Unexpected answerer remote identity source."
        Assert-Equal -Expected $false -Actual $evidence.RemoteIdentityServerAttested -Message "Answerer FileTransfer must not claim server-attested remote identity."
        Assert-Equal -Expected $false -Actual $evidence.NotRemoteIdentityProof -Message "Answerer FileTransfer must prove remote identity through the signed handshake."
        Assert-Equal -Expected $true -Actual $evidence.LocalMlKem768DecapsulationKeyInputPresent -Message "Local KEM decapsulation key input must be present."
        Assert-Equal -Expected $false -Actual $evidence.LocalMlKem768DecapsulationKeyCaptured -Message "Local KEM decapsulation key must not be captured."
        Assert-Equal -Expected $true -Actual $evidence.LocalMlKem768EncapsulationKeyInputPresent -Message "Local KEM public key input must be present."
        Assert-Equal -Expected $false -Actual $evidence.LocalMlKem768EncapsulationKeyCaptured -Message "Local KEM public key material must not be captured."
        Assert-Equal -Expected $true -Actual $evidence.LocalMlKem768KeyPairVerified -Message "Local KEM key pair must be verified."
    }
    else {
        Assert-Equal -Expected "initiator" -Actual $evidence.HandshakeRole -Message "Unexpected handshake role."
        Assert-Equal -Expected $true -Actual $evidence.ResponderIdentityFingerprintVerified -Message "Responder identity was not verified."
        Assert-Equal -Expected $true -Actual $evidence.ResponderSignatureVerified -Message "Responder signature was not verified."
        Assert-Equal -Expected $true -Actual $evidence.ResponderFinishedVerified -Message "Responder Finished was not verified."
        Assert-Equal -Expected $true -Actual $evidence.InitiatorFinishedSent -Message "Initiator Finished was not sent."
        Assert-Equal -Expected "connectionCodeLookup" -Actual $evidence.RemoteIdentitySource -Message "Unexpected offerer remote identity source."
        Assert-Equal -Expected $true -Actual $evidence.RemoteIdentityServerAttested -Message "Offerer FileTransfer must use lookup-attested remote identity."
        Assert-Equal -Expected $false -Actual $evidence.NotRemoteIdentityProof -Message "Offerer FileTransfer should not set NotRemoteIdentityProof."
        Assert-Equal -Expected $true -Actual $evidence.PeerMlKem768PublicKeyInputPresent -Message "Peer KEM public key input must be present."
        Assert-Equal -Expected $false -Actual $evidence.PeerMlKem768PublicKeyCaptured -Message "Peer KEM public key value must not be captured."
        Assert-Equal -Expected "operatorProvidedOutOfBand" -Actual $evidence.PeerMlKem768PublicKeySource -Message "Peer KEM public key source must remain explicit."
        Assert-Equal -Expected $false -Actual $evidence.PeerMlKem768PublicKeyServerAttested -Message "FileTransfer gate must not claim server-attested peer KEM key material."
    }

    Assert-Equal -Expected "FileTransfer" -Actual $evidence.FileTransferPacketType -Message "Unexpected FileTransfer packet type."
    Assert-Equal -Expected "FileTransfer" -Actual $evidence.SbwcPacketType -Message "Unexpected SBWC packet type."
    Assert-Equal -Expected $true -Actual $evidence.FileTransferSbwcEnvelope -Message "FileTransfer proof must use the SBWC secure envelope."
    Assert-Equal -Expected "sbwc-replay-window" -Actual $evidence.FileTransferReplayProtection -Message "SBWC FileTransfer replay boundary must be explicit."
    Assert-Equal -Expected $true -Actual $evidence.AuthenticatedFileTransferReceiptProof -Message "FileTransfer receipt proof must be authenticated."
    Assert-Equal -Expected $expectedTransferRole -Actual $evidence.TransferRole -Message "Unexpected transfer role."
    Assert-Equal -Expected $true -Actual $evidence.FileChannelObserved -Message "File channel must be observed."
    Assert-Equal -Expected 1 -Actual $evidence.ManifestFileCount -Message "Manifest must describe exactly one file."
    $manifestBytes = [int64]$evidence.ManifestBytes
    $transferredBytes = [int64]$evidence.TransferredBytes
    Assert-True -Condition ($manifestBytes -gt 0) -Message "ManifestBytes must be positive."
    Assert-Equal -Expected $manifestBytes -Actual $transferredBytes -Message "ManifestBytes must match TransferredBytes."
    if ($Role -eq "offer") {
        Assert-Equal -Expected ([int64]$FileTransferPayloadBytes) -Actual $manifestBytes -Message "Offerer transferred byte count must match FileTransferPayloadBytes."
    }
    else {
        Assert-True -Condition ($manifestBytes -le $FileTransferPayloadBytes) -Message "Answerer received bytes exceeded FileTransferPayloadBytes limit."
        Assert-Equal -Expected $manifestBytes -Actual ([int64]$evidence.ReceivedBytes) -Message "Answerer received byte count mismatch."
    }
    Assert-Equal -Expected 1 -Actual $evidence.ChunkCount -Message "FileTransfer smoke should transfer one chunk."
    Assert-Equal -Expected 1 -Actual $evidence.ChunkAckCount -Message "FileTransfer smoke should acknowledge one chunk."
    if ($Role -eq "offer") {
        Assert-Equal -Expected $true -Actual $evidence.CompleteAckReceived -Message "Offerer did not receive complete ACK."
    }
    else {
        Assert-Equal -Expected $true -Actual $evidence.CompleteAckSent -Message "Answerer did not send complete ACK."
    }
    foreach ($hashField in @("SentFileSha256", "FileSha256Receipt", "FileTransferSessionIdSha256", "FileTransferTransferIdSha256", "TransportBindingDigestHex")) {
        Assert-True -Condition ([string]$evidence.$hashField -match '^[0-9a-f]{64}$') -Message "$hashField is missing or invalid."
    }
    if ($Role -eq "answer") {
        Assert-True -Condition ([string]$evidence.ReceivedFileSha256 -match '^[0-9a-f]{64}$') -Message "ReceivedFileSha256 is missing or invalid."
        Assert-Equal -Expected $true -Actual $evidence.ReceiptMatchesReceivedHash -Message "Receipt did not match received hash."
    }
    Assert-Equal -Expected $true -Actual $evidence.ReceiptMatchesSentHash -Message "Receipt did not match sent hash."
    Assert-Equal -Expected $evidence.SentFileSha256 -Actual $evidence.FileSha256Receipt -Message "Sent file hash must match receipt hash."
    Assert-Equal -Expected 3 -Actual $evidence.ProductSendCount -Message "FileTransfer proof should send manifest/chunk/complete or ACK equivalents."
    Assert-Equal -Expected 3 -Actual $evidence.ProductReceiveCount -Message "FileTransfer proof should receive three peer messages."
    Assert-Equal -Expected "runtime-smoke-filetransfer-exchange" -Actual $evidence.ProductPayloadCountSource -Message "Unexpected product payload count source."
    foreach ($counterField in @(
        "FileTransferSessionHash",
        "FileTransferTranscriptPrefix"
    )) {
        Assert-True -Condition ($null -ne $evidence.$counterField) -Message "$counterField must be recorded."
    }
    foreach ($rawFlag in @("RawLocalPathCaptured", "RawRemotePathCaptured", "RawSignalingCaptured", "RawSdpCaptured", "RawIceCredentialCaptured", "RawPayloadCaptured", "HeaderValuesCaptured", "SecretInputsCaptured", "ConnectionCodeCaptured")) {
        Assert-Equal -Expected $false -Actual $evidence.$rawFlag -Message "$rawFlag must be false."
    }
    Assert-Equal -Expected $false -Actual (($evidence.PSObject.Properties.Name -contains "ConnectionCodeSha256")) -Message "Connection code hash must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.RemoteProductAppObserved -Message "FileTransfer gate must not claim remote product-app observation."
    Assert-Equal -Expected $false -Actual $evidence.PeerTrustPersistenceProof -Message "FileTransfer gate must not claim persisted peer trust."

    if ($Role -eq "answer") {
        Assert-True -Condition (Test-Path -LiteralPath $registeredCodeFullPath) -Message "Registered code output file was not created."
        Assert-WindowsCurrentPathOperatorSecretFileProtected -Path $registeredCodeFullPath
        $registeredCodeText = (Get-Content -Raw -LiteralPath $registeredCodeFullPath).Trim()
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($registeredCodeText)) -Message "Registered code output file is empty."
    }
    else {
        $registeredCodeText = ""
    }

    foreach ($secret in (@($connectionCode, $bearerToken, $tenantId, $privateKey, $peerKemPublicKey, $localKemDecapsulationKey, $localKemEncapsulationKey, $registeredCodeText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Assert-Equal -Expected $false -Actual $evidenceText.Contains($secret) -Message "Evidence leaked a raw secret, key, or connection code."
    }

    Write-Host "windows-current-path-product-control-file-transfer-live: evidence=$evidenceFullPath"
    Write-Host "windows-current-path-product-control-file-transfer-live: ok"
} finally {
    Restore-WindowsCurrentPathProcessEnvironment -Snapshot $secretEnvironmentSnapshot
    if ($removeRegisteredCodeOutPath -and -not [string]::IsNullOrWhiteSpace($generatedRegisteredCodeDir) -and (Test-Path -LiteralPath $generatedRegisteredCodeDir)) {
        Remove-WindowsCurrentPathGeneratedDirectory -Directory $generatedRegisteredCodeDir -RequiredLeafPrefix "skybridge-current-path-product-control-answerer-code-" -Label "Registered code directory"
    }
    if (-not $KeepEvidenceArtifacts -and $canRemoveSignalingDir -and (Test-Path -LiteralPath $signalingFullPath)) {
        Remove-WindowsCurrentPathGeneratedDirectory -Directory $signalingFullPath -RequiredLeafPrefix "skybridge-current-path-product-control-signaling-" -Label "SignalingDir"
    }
}
