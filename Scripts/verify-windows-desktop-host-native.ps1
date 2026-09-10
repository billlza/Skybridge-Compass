param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceDir,
    [string]$DotnetPath = 'dotnet',
    [switch]$BuildOnly,
    [switch]$GpuScaling
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native desktop smoke requires Windows.' }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$buildDir = Join-Path $EvidenceDir 'build'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$files = @(
    'Scripts/DesktopBackendSmoke.cs',
    'Scripts/DesktopScalerSmoke.cs',
    'Scripts/DesktopSyncRefreshSmoke.cs',
    'Scripts/DesktopViewerInputReceipt.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsDesktopContracts.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsDesktopCapture.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsDesktopScaler.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsDesktopPixels.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsDesktopEncoder.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsMediaFoundationInterop.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsH264AccessUnit.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsInteractiveDesktop.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsRemoteInput.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsRemoteInputPolicy.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsLoopbackAudioSource.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsLoopbackAudioInterop.cs',
    'windows/Skybridge.WinClient/Services/RemoteControl/WindowsOpusAudioEncoder.cs'
)
$compileItems = foreach ($file in $files) {
    $path = (Resolve-Path -LiteralPath (Join-Path $RepoRoot $file)).Path
    '    <Compile Include="' + [Security.SecurityElement]::Escape($path) + '" />'
}
$projectPath = Join-Path $buildDir 'DesktopBackendSmoke.csproj'
@"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0-windows10.0.22621.0</TargetFramework>
    <TargetPlatformMinVersion>10.0.19041.0</TargetPlatformMinVersion>
    <UseWindowsForms>true</UseWindowsForms>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>
  <ItemGroup>
$($compileItems -join "`n")
    <PackageReference Include="Vortice.Direct3D11" Version="3.8.3" />
    <PackageReference Include="Vortice.DXGI" Version="3.8.3" />
    <PackageReference Include="Vortice.MediaFoundation" Version="3.8.3" />
    <PackageReference Include="Concentus" Version="2.2.2" />
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $projectPath -Encoding UTF8
& $DotnetPath build $projectPath --configuration Release --nologo 2>&1 |
    Tee-Object -FilePath (Join-Path $EvidenceDir 'native-build.log')
if ($LASTEXITCODE -ne 0) { throw "Desktop backend smoke build failed: $LASTEXITCODE" }
$exe = Join-Path $buildDir 'bin/Release/net10.0-windows10.0.22621.0/win-x64/DesktopBackendSmoke.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Native smoke executable was not produced.' }
if ($BuildOnly) { Write-Output "desktop-backend-smoke-built: $exe"; exit 0 }
if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run the native smoke in an existing interactive user session. SSH session 0 can build but cannot validate desktop capture/input.'
}
& $exe $(if ($GpuScaling) { '--evidence-gpu' } else { '--evidence' }) $EvidenceDir
$nativeExit = $LASTEXITCODE
Write-Output "desktop-backend-smoke-exit: $nativeExit"
if ($nativeExit -ne 0) { throw "Desktop backend native smoke failed: $nativeExit" }
