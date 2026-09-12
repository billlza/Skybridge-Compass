param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)
$ErrorActionPreference = "Stop"
# The previous QR encoded an empty intent and a throwaway identity. The live LAN
# runtime keeps this capability unavailable until a real share manifest exists.
& (Join-Path $PSScriptRoot "verify-windows-native-runtime-profile.ps1") -RepoRoot $RepoRoot -FileTransferOnly
