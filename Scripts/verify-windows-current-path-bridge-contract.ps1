param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [int]$TimeoutSeconds = 30,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-bridge-contract-" + [guid]::NewGuid().ToString("N") + ".json")),
    [string]$SignalingDir = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-bridge-contract-signaling-" + [guid]::NewGuid().ToString("N")))
)

$ErrorActionPreference = "Stop"

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

Assert-True -Condition ($TimeoutSeconds -gt 0) -Message "TimeoutSeconds must be positive."

$runtimeSmokeProject = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/Skybridge.WinClient.RuntimeSmoke.csproj"
Assert-True -Condition (Test-Path -LiteralPath $runtimeSmokeProject) -Message "Missing RuntimeSmoke project: $runtimeSmokeProject"

$evidenceFullPath = [System.IO.Path]::GetFullPath($EvidencePath)
$evidenceDir = [System.IO.Path]::GetDirectoryName($evidenceFullPath)
if (-not [string]::IsNullOrWhiteSpace($evidenceDir)) {
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
}
New-Item -ItemType Directory -Force -Path $SignalingDir | Out-Null

Write-Host "windows-current-path-bridge-contract: build-runtime-smoke"
dotnet build $runtimeSmokeProject -c $Configuration /p:EnableWindowsTargeting=true /p:TreatWarningsAsErrors=true
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke build failed."

Write-Host "windows-current-path-bridge-contract: run-profile"
dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- `
    --profile current-path-bridge-contract `
    --signaling-dir $SignalingDir `
    --evidence-out $evidenceFullPath `
    --timeout-seconds $TimeoutSeconds
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke current-path-bridge-contract profile failed."

Assert-True -Condition (Test-Path -LiteralPath $evidenceFullPath) -Message "Missing bridge-contract evidence: $evidenceFullPath"
$evidenceText = Get-Content -LiteralPath $evidenceFullPath -Raw
$evidence = $evidenceText | ConvertFrom-Json

Assert-Equal -Expected "current-path-bridge-contract" -Actual $evidence.Profile -Message "Unexpected evidence profile."
Assert-Equal -Expected "CurrentPathWebRtcHelperBidirectionalSdpIceBridgeContract" -Actual $evidence.EvidenceScope -Message "Unexpected evidence scope."
Assert-Equal -Expected "ok" -Actual $evidence.Status -Message "Unexpected evidence status."
Assert-Equal -Expected "offerer" -Actual $evidence.ExchangeRoles[0] -Message "Unexpected first exchange role."
Assert-Equal -Expected "answerer" -Actual $evidence.ExchangeRoles[1] -Message "Unexpected second exchange role."
Assert-Equal -Expected "headers" -Actual $evidence.CredentialPlacement -Message "Unexpected credential placement."
Assert-Equal -Expected $false -Actual $evidence.QueryTokenPresent -Message "Query token must not be present."
Assert-Equal -Expected $false -Actual $evidence.HeaderValuesCaptured -Message "Header values must not be captured."
Assert-Equal -Expected $false -Actual $evidence.SecretInputsCaptured -Message "Secret inputs must not be captured."
Assert-Equal -Expected $true -Actual $evidence.Bound -Message "Expected fake signaling client to bind."
Assert-Equal -Expected 6 -Actual $evidence.OutboundFrameCount -Message "Expected bidirectional bridge signaling frames."
Assert-Equal -Expected "join" -Actual $evidence.OutboundTypes[0] -Message "Unexpected first outbound type."
Assert-Equal -Expected "offer" -Actual $evidence.OutboundTypes[1] -Message "Unexpected second outbound type."
Assert-Equal -Expected "iceCandidate" -Actual $evidence.OutboundTypes[2] -Message "Unexpected third outbound type."
Assert-Equal -Expected "join" -Actual $evidence.OutboundTypes[3] -Message "Unexpected fourth outbound type."
Assert-Equal -Expected "answer" -Actual $evidence.OutboundTypes[4] -Message "Unexpected fifth outbound type."
Assert-Equal -Expected "iceCandidate" -Actual $evidence.OutboundTypes[5] -Message "Unexpected sixth outbound type."
Assert-Equal -Expected 3 -Actual $evidence.OffererOutboundFrameCount -Message "Unexpected offerer outbound frame count."
Assert-Equal -Expected "join" -Actual $evidence.OffererOutboundTypes[0] -Message "Unexpected first offerer outbound type."
Assert-Equal -Expected "offer" -Actual $evidence.OffererOutboundTypes[1] -Message "Unexpected second offerer outbound type."
Assert-Equal -Expected "iceCandidate" -Actual $evidence.OffererOutboundTypes[2] -Message "Unexpected third offerer outbound type."
Assert-Equal -Expected 3 -Actual $evidence.AnswererOutboundFrameCount -Message "Unexpected answerer outbound frame count."
Assert-Equal -Expected "join" -Actual $evidence.AnswererOutboundTypes[0] -Message "Unexpected first answerer outbound type."
Assert-Equal -Expected "answer" -Actual $evidence.AnswererOutboundTypes[1] -Message "Unexpected second answerer outbound type."
Assert-Equal -Expected "iceCandidate" -Actual $evidence.AnswererOutboundTypes[2] -Message "Unexpected third answerer outbound type."
Assert-Equal -Expected 1 -Actual $evidence.LocalCandidateCount -Message "Unexpected local candidate count."
Assert-Equal -Expected 1 -Actual $evidence.RemoteCandidateCount -Message "Unexpected remote candidate count."
Assert-Equal -Expected "44:55:66" -Actual $evidence.AnswerFingerprint -Message "Unexpected answer fingerprint."
Assert-Equal -Expected "192.168.0.101:51490" -Actual $evidence.RemoteEndpoint -Message "Unexpected remote endpoint."
Assert-Equal -Expected $true -Actual $evidence.RemoteSignalWritten -Message "Remote answer file was not written."
Assert-Equal -Expected 1 -Actual $evidence.AnswererLocalCandidateCount -Message "Unexpected answerer local candidate count."
Assert-Equal -Expected 1 -Actual $evidence.AnswererRemoteCandidateCount -Message "Unexpected answerer remote candidate count."
Assert-Equal -Expected "55:66:77" -Actual $evidence.OfferFingerprint -Message "Unexpected offer fingerprint."
Assert-Equal -Expected "192.168.0.101:51491" -Actual $evidence.AnswererRemoteEndpoint -Message "Unexpected answerer remote endpoint."
Assert-Equal -Expected $true -Actual $evidence.AnswererRemoteSignalWritten -Message "Remote offer file was not written."
Assert-Equal -Expected $true -Actual $evidence.NotTransportProof -Message "Bridge contract evidence must not claim transport proof."
Assert-Equal -Expected $true -Actual $evidence.NotHandshakeProof -Message "Bridge contract evidence must not claim handshake proof."
Assert-Equal -Expected $true -Actual $evidence.NotAppControlProof -Message "Bridge contract evidence must not claim AppControl proof."
Assert-Equal -Expected $true -Actual $evidence.NotMacProductAppProof -Message "Bridge contract evidence must not claim Mac product App proof."
Assert-Equal -Expected $false -Actual $evidenceText.Contains("session-token") -Message "Evidence leaked the fake session token."

Write-Host "windows-current-path-bridge-contract: evidence=$evidenceFullPath"
Write-Host "windows-current-path-bridge-contract: ok"
