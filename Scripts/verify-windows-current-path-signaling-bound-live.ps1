param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [Parameter(Mandatory = $true)]
    [string]$SignalingServerOrigin,
    [Parameter(Mandatory = $true)]
    [string]$WsPath,
    [Parameter(Mandatory = $true)]
    [string]$SessionId,
    [Parameter(Mandatory = $true)]
    [string]$LocalDeviceId,
    [string]$SessionTokenEnvVar = "SKYBRIDGE_CURRENT_PATH_SESSION_TOKEN",
    [string]$ClientVersion = "1.0.0",
    [string]$ProtocolVersion = "1",
    [int]$TimeoutSeconds = 60,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-signaling-bound-" + [guid]::NewGuid().ToString("N") + ".json"))
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
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($SessionTokenEnvVar)) -Message "SessionTokenEnvVar must not be empty."
Assert-True -Condition ($SessionTokenEnvVar -match '^[A-Za-z0-9_]+$') -Message "SessionTokenEnvVar must contain only letters, digits, or underscores."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($SessionTokenEnvVar))) -Message "Set the SessionTokenEnvVar environment variable before running this script."

$tokenForEvidenceCheck = [Environment]::GetEnvironmentVariable($SessionTokenEnvVar)

try {
    $runtimeSmokeProject = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/Skybridge.WinClient.RuntimeSmoke.csproj"
    Assert-True -Condition (Test-Path -LiteralPath $runtimeSmokeProject) -Message "Missing RuntimeSmoke project: $runtimeSmokeProject"

    Write-Host "windows-current-path-signaling-bound-live: build-runtime-smoke"
    [Environment]::SetEnvironmentVariable($SessionTokenEnvVar, $null, "Process")
    dotnet build $runtimeSmokeProject -c $Configuration /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke build failed."
    [Environment]::SetEnvironmentVariable($SessionTokenEnvVar, $tokenForEvidenceCheck, "Process")

    $evidenceFullPath = [System.IO.Path]::GetFullPath($EvidencePath)
    $evidenceDir = [System.IO.Path]::GetDirectoryName($evidenceFullPath)
    if (-not [string]::IsNullOrWhiteSpace($evidenceDir)) {
        New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
    }

    Write-Host "windows-current-path-signaling-bound-live: run-signaling-bound"
    dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- `
        --profile signaling-bound `
        --signaling-server-origin $SignalingServerOrigin `
        --ws-path $WsPath `
        --session-id $SessionId `
        --session-token-env $SessionTokenEnvVar `
        --local-device-id $LocalDeviceId `
        --client-version $ClientVersion `
        --protocol-version $ProtocolVersion `
        --evidence-out $evidenceFullPath `
        --timeout-seconds $TimeoutSeconds
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke signaling-bound profile failed."

    Assert-True -Condition (Test-Path -LiteralPath $evidenceFullPath) -Message "Missing signaling-bound evidence: $evidenceFullPath"
    $evidenceText = Get-Content -LiteralPath $evidenceFullPath -Raw
    $evidence = $evidenceText | ConvertFrom-Json

    Assert-Equal -Expected "signaling-bound" -Actual $evidence.Profile -Message "Unexpected evidence profile."
    Assert-Equal -Expected "SignalingBound" -Actual $evidence.EvidenceScope -Message "Unexpected evidence scope."
    Assert-Equal -Expected "bound" -Actual $evidence.Status -Message "Unexpected signaling status."
    Assert-Equal -Expected "bound" -Actual $evidence.Phase -Message "Unexpected signaling phase."
    Assert-Equal -Expected $true -Actual $evidence.SocketOpen -Message "Expected socketOpen before bound."
    Assert-Equal -Expected $true -Actual $evidence.Bound -Message "Expected bound evidence."
    Assert-Equal -Expected $true -Actual $evidence.BoundSessionMatches -Message "Expected bound session match."
    Assert-Equal -Expected "headers" -Actual $evidence.CredentialPlacement -Message "Expected header credential placement."
    Assert-Equal -Expected $false -Actual $evidence.QueryTokenPresent -Message "Query token must not be present."
    Assert-Equal -Expected $false -Actual $evidence.HeaderValuesCaptured -Message "Header values must not be captured."
    Assert-Equal -Expected 0 -Actual $evidence.BusinessSendCount -Message "Signaling-bound gate must not send business envelopes."
    Assert-Equal -Expected $true -Actual $evidence.NotTransportProof -Message "Evidence must not claim transport proof."
    Assert-Equal -Expected $true -Actual $evidence.NotHandshakeProof -Message "Evidence must not claim handshake proof."
    Assert-Equal -Expected $true -Actual $evidence.NotAppControlProof -Message "Evidence must not claim AppControl proof."

    $headers = @($evidence.HeadersPresent)
    foreach ($requiredHeader in @("X-SkyBridge-Client-Version", "X-SkyBridge-Protocol-Version", "X-SkyBridge-Session", "X-SkyBridge-Session-Id")) {
        Assert-True -Condition ($headers -contains $requiredHeader) -Message "Evidence missing header marker: $requiredHeader"
    }

    if (-not [string]::IsNullOrWhiteSpace($tokenForEvidenceCheck)) {
        Assert-Equal -Expected $false -Actual $evidenceText.Contains($tokenForEvidenceCheck) -Message "Evidence leaked the raw session token."
    }

    Write-Host "windows-current-path-signaling-bound-live: evidence=$evidenceFullPath"
    Write-Host "windows-current-path-signaling-bound-live: ok"
} finally {
    [Environment]::SetEnvironmentVariable($SessionTokenEnvVar, $tokenForEvidenceCheck, "Process")
}
