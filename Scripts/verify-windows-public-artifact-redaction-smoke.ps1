param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

function Invoke-ScannerExpectFailure {
    param(
        [string]$ArtifactPath,
        [string]$Message
    )

    $scannerPath = Join-Path $RepoRoot "Scripts/verify-windows-public-artifact-redaction.ps1"
    $failed = $false
    try {
        & $scannerPath -RepoRoot $RepoRoot -ArtifactPath $ArtifactPath *> $null
    }
    catch {
        $failed = $true
    }
    Assert-True -Condition $failed -Message $Message
}

$scanner = Join-Path $RepoRoot "Scripts/verify-windows-public-artifact-redaction.ps1"
Assert-True -Condition (Test-Path -LiteralPath $scanner -PathType Leaf) -Message "Missing Windows public artifact redaction scanner."

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skybridge-windows-public-redaction-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $rawDir = Join-Path $tempRoot "raw"
    $publicDir = Join-Path $tempRoot "public"
    $emptyDir = Join-Path $tempRoot "empty"
    $sdpOnlyDir = Join-Path $tempRoot "sdp-only"
    $unsupportedDir = Join-Path $tempRoot "unsupported"
    New-Item -ItemType Directory -Force -Path (Join-Path $rawDir "nested") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $publicDir "nested") | Out-Null
    New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
    New-Item -ItemType Directory -Force -Path $sdpOnlyDir | Out-Null
    New-Item -ItemType Directory -Force -Path $unsupportedDir | Out-Null

    $longBase64 = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWkFCQ0RFRkdISUpLTE1OT1A="
    $rawJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ3aW5kb3dzLXB1YmxpYy1hcnRpZmFjdCJ9.signatureSecretValue"
    Set-Content -LiteralPath (Join-Path $rawDir "windows-live-file-transfer.json") -Encoding UTF8 -Value @"
{
  "repoRoot": "C:\\Users\\bill\\Skybridge-Compass",
  "sessionId": "raw-session-id",
  "trackId": "raw-track-id",
  "tenantId": "tenant-secret",
  "userIdentifier": "user-secret",
  "currentPathProductControlAnswererConnectionCodePath": "C:\\Users\\bill\\AppData\\Local\\Temp\\connection-code.txt",
  "Authorization": "Bearer raw-json-bearer",
  "access_token": "raw-snake-access-token",
  "publicKeyBase64": "$longBase64",
  "sdp": "v=0`na=ice-pwd:raw-json-ice-pwd`na=ice-ufrag:raw-json-ice-ufrag",
  "icePwd": "raw-json-ice-pwd",
  "ice_pwd": "raw-json-snake-ice-pwd",
  "iceUfrag": "raw-json-ice-ufrag",
  "iceCandidate": "candidate:1 1 UDP 2122252543 10.20.30.47 54326 typ host",
  "local_endpoint": "10.20.30.47:54326",
  "SelectedCandidatePair": "10.20.30.47:54326 -> 10.20.30.48:54327"
}
"@
    Set-Content -LiteralPath (Join-Path $rawDir "nested\acceptance.log") -Encoding UTF8 -Value @"
Authorization: Bearer raw-bearer-token session=raw-session-id trackId=raw-track-id connect ABC123 code 123456 path=C:\\Users\\bill\\secret.txt endpoint=https://control.example.invalid/private?token=secret jwt=$rawJwt peerPublicKey=$longBase64
v=0
a=ice-pwd:raw-line-ice-pwd
a=ice-ufrag:raw-line-ice-ufrag
a=candidate:1 1 UDP 2122252543 10.20.30.45 54324 typ host
"@
    Set-Content -LiteralPath (Join-Path $rawDir "frame.png") -Encoding UTF8 -Value "binary content is intentionally ignored by the text scanner"
    Set-Content -LiteralPath (Join-Path $sdpOnlyDir "webrtc-public.log") -Encoding UTF8 -Value @"
v=0
a=ice-pwd:raw-public-ice-pwd
a=ice-ufrag:raw-public-ice-ufrag
a=candidate:1 1 UDP 2122252543 10.20.30.46 54325 typ host
"@
    Set-Content -LiteralPath (Join-Path $unsupportedDir "public.yaml") -Encoding UTF8 -Value "access_token: raw-yaml-token"

    Invoke-ScannerExpectFailure -ArtifactPath $emptyDir -Message "Empty public artifact directory must fail."
    Invoke-ScannerExpectFailure -ArtifactPath $rawDir -Message "Raw public artifact directory must fail."
    Invoke-ScannerExpectFailure -ArtifactPath $sdpOnlyDir -Message "Raw SDP/ICE-only public artifact directory must fail."
    Invoke-ScannerExpectFailure -ArtifactPath $unsupportedDir -Message "Unsupported public artifact extension must fail."

    Set-Content -LiteralPath (Join-Path $publicDir "windows-live-file-transfer.json") -Encoding UTF8 -Value @"
{
  "repoRoot": "<external:abc123>",
  "sessionId": "<redacted>",
  "trackId": "<redacted>",
  "tenantId": "<redacted>",
  "userIdentifier": "<redacted>",
  "currentPathProductControlAnswererConnectionCodePath": "<redacted-path>",
  "Authorization": "<redacted>",
  "access_token": "<redacted>",
  "publicKeyBase64": "<redacted>",
  "sdp": "<redacted>",
  "icePwd": "<redacted>",
  "ice_pwd": "<redacted>",
  "iceUfrag": "<redacted>",
  "iceCandidate": "<redacted>",
  "local_endpoint": "<redacted>",
  "SelectedCandidatePair": "<redacted>"
}
"@
    Set-Content -LiteralPath (Join-Path $publicDir "nested\acceptance.log") -Encoding UTF8 -Value @"
Authorization: Bearer <redacted> session=ref:05d9cb246274 trackId=ref:0654c593e80f connect <redacted-code> code <redacted-code> path=<redacted-path> endpoint=<redacted-url> jwt=<redacted-jwt> peerPublicKey=ref:ffcded9c9679
"@

    & $scanner -RepoRoot $RepoRoot -ArtifactPath $publicDir
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "windows-public-artifact-redaction-smoke: ok"
