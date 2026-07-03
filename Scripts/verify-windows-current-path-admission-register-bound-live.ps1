param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SignalServerBaseUrl = "https://api.nebula-technologies.net",
    [Parameter(Mandatory = $true)]
    [string]$LocalDeviceId,
    [string]$DeviceName = "Windows RuntimeSmoke",
    [string]$BearerTokenEnvVar = "SKYBRIDGE_CURRENT_PATH_BEARER_TOKEN",
    [string]$TenantIdEnvVar = "SKYBRIDGE_CURRENT_PATH_TENANT_ID",
    [string]$Mldsa65PrivateKeyBase64EnvVar = "SKYBRIDGE_CURRENT_PATH_MLDSA65_PRIVATE_KEY_BASE64",
    [string]$ClientVersion = "1.0.0",
    [string]$ProtocolVersion = "1",
    [int]$TtlSeconds = 300,
    [int]$TimeoutSeconds = 60,
    [string]$Configuration = "Debug",
    [string]$EvidencePath = (Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-current-path-admission-register-bound-" + [guid]::NewGuid().ToString("N") + ".json"))
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

function Assert-EnvName {
    param(
        [string]$Name,
        [string]$Label
    )

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($Name)) -Message "$Label must not be empty."
    Assert-True -Condition ($Name -match '^[A-Za-z0-9_]+$') -Message "$Label must contain only letters, digits, or underscores."
}

Assert-True -Condition ($TimeoutSeconds -gt 0) -Message "TimeoutSeconds must be positive."
Assert-True -Condition ($TtlSeconds -gt 0) -Message "TtlSeconds must be positive."
Assert-EnvName -Name $BearerTokenEnvVar -Label "BearerTokenEnvVar"
Assert-EnvName -Name $TenantIdEnvVar -Label "TenantIdEnvVar"
Assert-EnvName -Name $Mldsa65PrivateKeyBase64EnvVar -Label "Mldsa65PrivateKeyBase64EnvVar"

$bearerToken = [Environment]::GetEnvironmentVariable($BearerTokenEnvVar)
$tenantId = [Environment]::GetEnvironmentVariable($TenantIdEnvVar)
$privateKey = [Environment]::GetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar)
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($bearerToken)) -Message "Set the BearerTokenEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($tenantId)) -Message "Set the TenantIdEnvVar environment variable before running this script."
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($privateKey)) -Message "Set the Mldsa65PrivateKeyBase64EnvVar environment variable before running this script."

try {
    $runtimeSmokeProject = Join-Path $RepoRoot "windows/Skybridge.WinClient.RuntimeSmoke/Skybridge.WinClient.RuntimeSmoke.csproj"
    Assert-True -Condition (Test-Path -LiteralPath $runtimeSmokeProject) -Message "Missing RuntimeSmoke project: $runtimeSmokeProject"

    Write-Host "windows-current-path-admission-register-bound-live: build-runtime-smoke"
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $null, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $null, "Process")
    dotnet build $runtimeSmokeProject -c $Configuration /p:TreatWarningsAsErrors=true
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke build failed."
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $bearerToken, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $tenantId, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $privateKey, "Process")

    $evidenceFullPath = [System.IO.Path]::GetFullPath($EvidencePath)
    $evidenceDir = [System.IO.Path]::GetDirectoryName($evidenceFullPath)
    if (-not [string]::IsNullOrWhiteSpace($evidenceDir)) {
        New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
    }

    Write-Host "windows-current-path-admission-register-bound-live: run-admission-register-bound"
    dotnet run --no-build --no-restore --project $runtimeSmokeProject -c $Configuration -- `
        --profile admission-register-bound `
        --signal-server-base-url $SignalServerBaseUrl `
        --local-device-id $LocalDeviceId `
        --device-name $DeviceName `
        --bearer-token-env $BearerTokenEnvVar `
        --tenant-id-env $TenantIdEnvVar `
        --mldsa65-private-key-base64-env $Mldsa65PrivateKeyBase64EnvVar `
        --client-version $ClientVersion `
        --protocol-version $ProtocolVersion `
        --ttl-seconds $TtlSeconds `
        --evidence-out $evidenceFullPath `
        --timeout-seconds $TimeoutSeconds
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "RuntimeSmoke admission-register-bound profile failed."

    Assert-True -Condition (Test-Path -LiteralPath $evidenceFullPath) -Message "Missing admission-register-bound evidence: $evidenceFullPath"
    $evidenceText = Get-Content -LiteralPath $evidenceFullPath -Raw
    $evidence = $evidenceText | ConvertFrom-Json

    Assert-Equal -Expected "admission-register-bound" -Actual $evidence.Profile -Message "Unexpected evidence profile."
    Assert-Equal -Expected "AdmissionRegisterLookupSignalingBound" -Actual $evidence.EvidenceScope -Message "Unexpected evidence scope."
    Assert-Equal -Expected "bound" -Actual $evidence.Status -Message "Unexpected signaling status."
    Assert-Equal -Expected "bound" -Actual $evidence.Phase -Message "Unexpected signaling phase."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AdmissionChallenge -Message "Admission challenge did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.AdmissionLease -Message "Admission lease did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.RegisterCode -Message "Register code did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.LookupCode -Message "Lookup code did not complete."
    Assert-Equal -Expected $true -Actual $evidence.Steps.SignalingBound -Message "Signaling bind did not complete."
    Assert-Equal -Expected "ML-DSA-65" -Actual $evidence.ProtocolSigningAlgorithm -Message "Unexpected protocol signing algorithm."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($evidence.AdmissionState)) -Message "Admission state must be recorded."
    Assert-True -Condition @("admitted", "active").Contains(([string]$evidence.AdmissionState).ToLowerInvariant()) -Message "Admission state must be admitted or active before registration."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($evidence.AdmissionIssuedAt)) -Message "Admission issued time must be recorded."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($evidence.AdmissionExpiresAt)) -Message "Admission expiry must be recorded."
    Assert-True -Condition ($evidence.LeaseExpiresIn -gt 0) -Message "LeaseExpiresIn must be positive."
    Assert-Equal -Expected $true -Actual $evidence.TurnAdmissionTokenPresent -Message "TURN admission token presence must be recorded."
    Assert-Equal -Expected "selfRegisteredCode" -Actual $evidence.LookupMode -Message "Unexpected lookup mode."
    Assert-Equal -Expected $true -Actual $evidence.LookupSessionMatches -Message "Lookup session must match registered lease."
    Assert-Equal -Expected $true -Actual $evidence.LookupOriginMatches -Message "Lookup origin must match registered lease."
    Assert-Equal -Expected $true -Actual $evidence.LookupWsPathMatches -Message "Lookup wsPath must match registered lease."
    Assert-Equal -Expected $true -Actual $evidence.LookupInitiatorDeviceMatches -Message "Lookup initiator device must match local binding."
    Assert-Equal -Expected $true -Actual $evidence.LookupInitiatorFingerprintMatches -Message "Lookup initiator fingerprint must match local binding."
    Assert-Equal -Expected $true -Actual $evidence.SocketOpen -Message "Expected socketOpen before bound."
    Assert-Equal -Expected $true -Actual $evidence.Bound -Message "Expected bound evidence."
    Assert-Equal -Expected $true -Actual $evidence.BoundSessionMatches -Message "Expected bound session match."
    Assert-Equal -Expected $false -Actual $evidence.QueryTokenPresent -Message "Query token must not be present."
    Assert-Equal -Expected $false -Actual $evidence.HeaderValuesCaptured -Message "Header values must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.SecretInputsCaptured -Message "Secret inputs must not be captured."
    Assert-Equal -Expected $false -Actual $evidence.ConnectionCodeCaptured -Message "Connection code value must not be captured."
    Assert-Equal -Expected 0 -Actual $evidence.BusinessSendCount -Message "Admission-register-bound gate must not send business envelopes."
    Assert-Equal -Expected $true -Actual $evidence.NotTransportProof -Message "Evidence must not claim transport proof."
    Assert-Equal -Expected $true -Actual $evidence.NotHandshakeProof -Message "Evidence must not claim handshake proof."
    Assert-Equal -Expected $true -Actual $evidence.NotAppControlProof -Message "Evidence must not claim AppControl proof."
    Assert-Equal -Expected $true -Actual $evidence.NotMacProductAppProof -Message "Evidence must not claim Mac product App proof."

    foreach ($secret in @($bearerToken, $tenantId, $privateKey)) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            Assert-Equal -Expected $false -Actual $evidenceText.Contains($secret) -Message "Evidence leaked a raw secret input."
        }
    }

    Write-Host "windows-current-path-admission-register-bound-live: evidence=$evidenceFullPath"
    Write-Host "windows-current-path-admission-register-bound-live: ok"
} finally {
    [Environment]::SetEnvironmentVariable($BearerTokenEnvVar, $bearerToken, "Process")
    [Environment]::SetEnvironmentVariable($TenantIdEnvVar, $tenantId, "Process")
    [Environment]::SetEnvironmentVariable($Mldsa65PrivateKeyBase64EnvVar, $privateKey, "Process")
}
