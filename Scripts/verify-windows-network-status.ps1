param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)
$ErrorActionPreference = 'Stop'
$probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('skybridge-network-status-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeRoot | Out-Null
$program = [Security.SecurityElement]::Escape((Join-Path $RepoRoot 'Scripts/NetworkStatusSmoke.cs'))
$client = [Security.SecurityElement]::Escape((Join-Path $RepoRoot 'windows/Skybridge.WinClient/Services/TopBarNetworkStatusClient.cs'))
$project = Join-Path $probeRoot 'NetworkStatusSmoke.csproj'
@"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems><TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>
  <ItemGroup><Compile Include="$program" /><Compile Include="$client" /></ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $project -Encoding UTF8
& dotnet run --project $project
if ($LASTEXITCODE -ne 0) { throw 'Live network status probe failed.' }
