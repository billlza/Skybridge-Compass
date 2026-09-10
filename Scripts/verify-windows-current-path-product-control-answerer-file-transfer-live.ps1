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
    [int]$RemoteAnswerTimeoutSeconds = 120,
    [int]$RemoteOfferTimeoutSeconds = 120,
    [ValidateRange(1, 2048)]
    [int]$FileTransferPayloadBytes = 1024,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-answerer-file-transfer-" + [guid]::NewGuid().ToString("N") + ".json")),
    [string]$RegisteredCodeOutPath = "",
    [string]$SignalingDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-signaling-" + [guid]::NewGuid().ToString("N"))),
    [switch]$KeepEvidenceArtifacts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$fileTransferGate = Join-Path $PSScriptRoot "verify-windows-current-path-product-control-file-transfer-live.ps1"
& $fileTransferGate `
    -RepoRoot $RepoRoot `
    -SignalServerBaseUrl $SignalServerBaseUrl `
    -LocalDeviceId $LocalDeviceId `
    -PeerDeviceId $PeerDeviceId `
    -PeerFingerprint $PeerFingerprint `
    -Role answer `
    -DeviceName $DeviceName `
    -ConnectionCodeEnvVar $ConnectionCodeEnvVar `
    -BearerTokenEnvVar $BearerTokenEnvVar `
    -TenantIdEnvVar $TenantIdEnvVar `
    -Mldsa65PrivateKeyBase64EnvVar $Mldsa65PrivateKeyBase64EnvVar `
    -PeerMlKem768PublicKeyBase64EnvVar $PeerMlKem768PublicKeyBase64EnvVar `
    -LocalMlKem768DecapsulationKeyBase64EnvVar $LocalMlKem768DecapsulationKeyBase64EnvVar `
    -LocalMlKem768EncapsulationKeyBase64EnvVar $LocalMlKem768EncapsulationKeyBase64EnvVar `
    -BindAddress $BindAddress `
    -ClientVersion $ClientVersion `
    -ProtocolVersion $ProtocolVersion `
    -ExpectedBoundRole $ExpectedBoundRole `
    -TtlSeconds $TtlSeconds `
    -TimeoutSeconds $TimeoutSeconds `
    -SignalFileTimeoutSeconds $SignalFileTimeoutSeconds `
    -RemoteAnswerTimeoutSeconds $RemoteAnswerTimeoutSeconds `
    -RemoteOfferTimeoutSeconds $RemoteOfferTimeoutSeconds `
    -FileTransferPayloadBytes $FileTransferPayloadBytes `
    -Configuration $Configuration `
    -EvidencePath $EvidencePath `
    -RegisteredCodeOutPath $RegisteredCodeOutPath `
    -SignalingDir $SignalingDir `
    -KeepEvidenceArtifacts:$KeepEvidenceArtifacts
