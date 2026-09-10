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
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-answerer-transport-" + [guid]::NewGuid().ToString("N") + ".json")),
    [string]$RegisteredCodeOutPath = "",
    [string]$SignalingDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-product-control-signaling-" + [guid]::NewGuid().ToString("N"))),
    [switch]$KeepEvidenceArtifacts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$transportGate = Join-Path $PSScriptRoot "verify-windows-current-path-product-control-transport-live.ps1"
& $transportGate `
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
    -BindAddress $BindAddress `
    -ClientVersion $ClientVersion `
    -ProtocolVersion $ProtocolVersion `
    -ExpectedBoundRole $ExpectedBoundRole `
    -TtlSeconds $TtlSeconds `
    -TimeoutSeconds $TimeoutSeconds `
    -SignalFileTimeoutSeconds $SignalFileTimeoutSeconds `
    -RemoteAnswerTimeoutSeconds $RemoteAnswerTimeoutSeconds `
    -RemoteOfferTimeoutSeconds $RemoteOfferTimeoutSeconds `
    -Configuration $Configuration `
    -EvidencePath $EvidencePath `
    -RegisteredCodeOutPath $RegisteredCodeOutPath `
    -SignalingDir $SignalingDir `
    -KeepEvidenceArtifacts:$KeepEvidenceArtifacts
