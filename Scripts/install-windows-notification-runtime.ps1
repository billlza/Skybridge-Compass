param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot 'RuntimeDependencies'),
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$files = @('Microsoft.WindowsAppRuntime.2.msix', 'Microsoft.WindowsAppRuntime.Main.2.msix', 'Microsoft.WindowsAppRuntime.Singleton.2.msix')
$expectedNames = @('Microsoft.WindowsAppRuntime.2', 'MicrosoftCorporationII.WinAppRuntime.Main.2', 'MicrosoftCorporationII.WinAppRuntime.Singleton')
$plans = @()
for ($index = 0; $index -lt $files.Count; $index++) {
    $file = Join-Path $RuntimeDirectory $files[$index]
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $publisher) {
        throw "Notification dependency does not have a valid Microsoft signature: $($files[$index])"
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($file)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry -or $entry.Length -gt 131072) { throw 'Invalid runtime package manifest.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    $identity = $manifest.Package.Identity
    if ($identity.Name -ne $expectedNames[$index] -or $identity.Publisher -ne $publisher -or $identity.ProcessorArchitecture -ne 'x64') {
        throw "Unexpected notification runtime identity: $($files[$index])"
    }
    $plans += [pscustomobject]@{name=$identity.Name;version=$identity.Version;path=$file;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash;result='pending'}
}

$receipt = [ordered]@{scope='current-user';userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;packages=$plans;success=$false}
try {
    foreach ($plan in $plans) {
        $existing = @(Get-AppxPackage -Name $plan.name | Where-Object { $_.Publisher -eq $publisher -and $_.Architecture -eq 'X64' -and [version]$_.Version -ge [version]$plan.version })
        if ($existing.Count -gt 0) { $plan.result = 'already-present'; continue }
        # Add-AppxPackage registers for the calling user. No machine provisioning,
        # policy changes, forced downgrade or other users' packages are involved.
        Add-AppxPackage -Path $plan.path
        $installed = @(Get-AppxPackage -Name $plan.name | Where-Object { $_.Publisher -eq $publisher -and $_.Architecture -eq 'X64' -and [version]$_.Version -ge [version]$plan.version })
        if ($installed.Count -eq 0) { throw "Notification dependency was not registered: $($plan.name)" }
        $plan.result = 'installed'
    }
    $receipt.success = $true
} finally {
    if ($EvidencePath) {
        $destination = [IO.Path]::GetFullPath($EvidencePath)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $destination -Encoding UTF8
    }
}
$receipt | ConvertTo-Json -Depth 4
