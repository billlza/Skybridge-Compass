param(
    [Parameter(Mandatory=$true)][string]$RuntimePackage,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Windows App SDK 2.3.1 omits this notification resource from its self-contained
# output. Extract the exact pinned Microsoft asset at build time (upstream #6071).
# Installing the framework MSIX alone does not add it to a self-contained app.
$package=[IO.Path]::GetFullPath($RuntimePackage)
$signature=Get-AuthenticodeSignature -LiteralPath $package
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
    throw 'The pinned Windows App Runtime package has no valid Microsoft signature.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$name='Microsoft.WindowsAppRuntime.Insights.Resource.dll'
$zip=[IO.Compression.ZipFile]::OpenRead($package)
try {
    $entry=$zip.GetEntry($name)
    if($null -eq $entry -or $entry.Length -le 0 -or $entry.Length -gt 1048576) {
        throw 'The pinned notification resource is absent or has an unexpected size.'
    }
    $input=$entry.Open()
    $buffer=[IO.MemoryStream]::new()
    try {$input.CopyTo($buffer);$bytes=$buffer.ToArray()} finally {$input.Dispose();$buffer.Dispose()}
} finally {$zip.Dispose()}
$directory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$destination=Join-Path $directory $name
[IO.File]::WriteAllBytes($destination,$bytes)
$resourceSignature=Get-AuthenticodeSignature -LiteralPath $destination
if($resourceSignature.Status -ne 'Valid' -or $resourceSignature.SignerCertificate.Subject -ne $signature.SignerCertificate.Subject) {
    throw 'The extracted notification resource has no valid Microsoft signature.'
}
[pscustomobject]@{success=$true;packageSha256=(Get-FileHash $package -Algorithm SHA256).Hash;resourceSha256=(Get-FileHash $destination -Algorithm SHA256).Hash} |
    ConvertTo-Json | Set-Content (Join-Path $directory 'notification-assets.json') -Encoding UTF8
Write-Output 'Notification resource: verified Microsoft signature and staged the pinned runtime asset.'
