#requires -RunAsAdministrator
# Setup-Msix.ps1 — generate placeholder MSIX assets + a trusted self-signed dev cert.
# Run elevated. Prereqs for the packaged build: the assets + cert this creates, then build
# with /p:EnableMsixTooling=true /p:GenerateAppxPackageOnBuild=true (see §4 of the plan).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ProjectDir = Split-Path -Parent $PSScriptRoot   # .../Skybridge.WinClient
$AssetsDir  = Join-Path $ProjectDir 'Assets'
$PublisherSubject = 'CN=SkyBridge'               # MUST match Package.appxmanifest Publisher
$PfxPassword = 'DevPassw0rd!'                     # change for your environment

New-Item -ItemType Directory -Force -Path $AssetsDir | Out-Null

# --- (a) Placeholder PNGs: solid SkyBridge-blue fill, exact pixel sizes ----------
$fill = [System.Drawing.Color]::FromArgb(255, 12, 92, 168)   # opaque blue

function New-Png([string]$name, [int]$w, [int]$h, [bool]$transparent = $false) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  if ($transparent) { $g.Clear([System.Drawing.Color]::Transparent) }
  else              { $g.Clear($fill) }
  $g.Dispose()
  $bmp.Save((Join-Path $AssetsDir $name), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "  wrote Assets\$name  ($w x $h)"
}

New-Png 'Square44x44Logo.png'    44   44
New-Png 'Square150x150Logo.png'  150  150
New-Png 'Wide310x150Logo.png'    310  150
New-Png 'LargeTile.png'          310  310    # Square310x310Logo
New-Png 'SmallTile.png'          71   71     # Square71x71Logo
New-Png 'StoreLogo.png'          50   50
New-Png 'SplashScreen.png'       620  300

foreach ($s in 16,24,32,48,256) {
  New-Png ("Square44x44Logo.targetsize-{0}.png" -f $s) $s $s
}
foreach ($s in 24,48,256) {
  New-Png ("Square44x44Logo.targetsize-{0}_altform-unplated.png" -f $s) $s $s $true
}

Write-Host "Assets generated in $AssetsDir`n" -ForegroundColor Green

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
