#requires -RunAsAdministrator
# Setup-Msix.ps1 — generate placeholder MSIX assets + a trusted self-signed dev cert.
# Run elevated. Prereqs for the packaged build: the assets + cert this creates, then build
# with /p:EnableMsixTooling=true /p:GenerateAppxPackageOnBuild=true (see §4 of the plan).

$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent $PSScriptRoot   # .../Skybridge.WinClient
$AssetsDir  = Join-Path $ProjectDir 'Assets'
$PublisherSubject = 'CN=SkyBridge'               # MUST match Package.appxmanifest Publisher
$PfxPassword = 'DevPassw0rd!'                     # change for your environment

# The reviewed product artwork is checked in and shared with unpackaged builds.
# Validate inputs before certificate setup; never replace the brand with placeholder pixels.
foreach ($asset in 'SkyBridgeCompass.ico', 'AppList.scale-100.png', 'MedTile.scale-100.png', 'StoreLogo.scale-100.png') {
  if (!(Test-Path -LiteralPath (Join-Path $AssetsDir $asset) -PathType Leaf)) {
    throw "Missing product icon asset: $asset"
  }
}

# --- (b) Self-signed dev code-signing cert -------------------------------------
$existing = Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.Subject -eq $PublisherSubject }
if ($existing) {
  Write-Host "Reusing existing cert: $($existing.Thumbprint)"
  $cert = $existing | Select-Object -First 1
} else {
  $cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $PublisherSubject `
    -KeyUsage DigitalSignature `
    -FriendlyName 'SkyBridge Compass Dev Cert' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}')
  Write-Host "Created cert: $($cert.Thumbprint)"
}

$pwd = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
$pfx = Join-Path $ProjectDir 'SkyBridgeCompass_Dev.pfx'
Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$($cert.Thumbprint)" -FilePath $pfx -Password $pwd | Out-Null
Write-Host "Exported PFX -> $pfx"

$cer = Join-Path $ProjectDir 'SkyBridgeCompass_Dev.cer'
Export-Certificate -Cert "Cert:\CurrentUser\My\$($cert.Thumbprint)" -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
Write-Host "Imported into LocalMachine\TrustedPeople"

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host " THUMBPRINT (wire into the build command):" -ForegroundColor Cyan
Write-Host "   $($cert.Thumbprint)" -ForegroundColor Yellow
Write-Host "   Publisher in Package.appxmanifest = $PublisherSubject" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
