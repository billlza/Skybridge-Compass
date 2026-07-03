param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$CheckOnline,
    [string]$EvidencePath = ""
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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition ($Text.Contains($Needle)) -Message $Message
}

function Get-PackageReferenceVersion {
    param(
        [xml]$Project,
        [string]$PackageId
    )

    $package = $Project.Project.ItemGroup.PackageReference |
        Where-Object { $_.Include -eq $PackageId } |
        Select-Object -First 1
    Assert-True -Condition ($null -ne $package) -Message "Missing PackageReference: $PackageId"
    return [string]$package.Version
}

function Get-LatestStableNuGetVersion {
    param([string]$PackageId)

    $packageLower = $PackageId.ToLowerInvariant()
    $index = Invoke-RestMethod -Uri "https://api.nuget.org/v3-flatcontainer/$packageLower/index.json"
    $stableVersions = $index.versions |
        Where-Object { $_ -notmatch "-" } |
        Sort-Object { [version]$_ } -Descending

    Assert-True -Condition ($stableVersions.Count -gt 0) -Message "NuGet package has no stable versions: $PackageId"
    return [string]($stableVersions | Select-Object -First 1)
}

$sourceUris = [ordered]@{
    dotnetReleaseMetadata = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/10.0/releases.json"
    microsoftWindowsAppSdkNuGet = "https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk/index.json"
    microsoftWindowsSdkBuildToolsNuGet = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/index.json"
    qrCoderNuGet = "https://api.nuget.org/v3-flatcontainer/qrcoder/index.json"
    sipsorceryNuGet = "https://api.nuget.org/v3-flatcontainer/sipsorcery/index.json"
    msQuicLatestRelease = "https://api.github.com/repos/microsoft/msquic/releases/latest"
    libdatachannelLatestRelease = "https://api.github.com/repos/paullouisageneau/libdatachannel/releases/latest"
}
$onlineEvidence = [ordered]@{}

$winClientProjectPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Skybridge.WinClient.csproj"
$cargoManifestPath = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
$architecturePath = Join-Path $RepoRoot "docs/windows-architecture.md"
$agentsPath = Join-Path $RepoRoot "AGENTS.md"

foreach ($path in @($winClientProjectPath, $cargoManifestPath, $architecturePath, $agentsPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing stack freshness file: $path"
}

$project = [xml](Get-Content -Raw -LiteralPath $winClientProjectPath)
$targetFramework = ([string]$project.Project.PropertyGroup.TargetFramework).Trim()
$targetPlatformMinVersion = ([string]$project.Project.PropertyGroup.TargetPlatformMinVersion).Trim()
$windowsPackageTypes = @($project.Project.PropertyGroup |
    ForEach-Object { $_.WindowsPackageType } |
    Where-Object { $null -ne $_ } |
    ForEach-Object { $_.InnerText.Trim() })
$windowsAppSdkVersion = Get-PackageReferenceVersion -Project $project -PackageId "Microsoft.WindowsAppSDK"
$buildToolsVersion = Get-PackageReferenceVersion -Project $project -PackageId "Microsoft.Windows.SDK.BuildTools"
$qrCoderVersion = Get-PackageReferenceVersion -Project $project -PackageId "QRCoder"
$cargoManifest = Get-Content -Raw -LiteralPath $cargoManifestPath
$architecture = Get-Content -Raw -LiteralPath $architecturePath
$agents = Get-Content -Raw -LiteralPath $agentsPath

Assert-True -Condition ($targetFramework -eq "net10.0-windows10.0.22621.0") -Message "Windows client must target net10.0-windows10.0.22621.0, got $targetFramework"
Assert-True -Condition ($targetPlatformMinVersion -eq "10.0.19041.0") -Message "Windows client must keep TargetPlatformMinVersion=10.0.19041.0, got $targetPlatformMinVersion"
Assert-True -Condition ($windowsPackageTypes -contains "None") -Message "Windows client must keep a default WindowsPackageType=None path so unpackaged WinUI auto-initializes the Windows App SDK runtime. Actual=[$($windowsPackageTypes -join ', ')]"
Assert-True -Condition ($windowsAppSdkVersion -eq "2.2.0") -Message "Windows App SDK must stay on latest stable 2.2.0, got $windowsAppSdkVersion"
Assert-True -Condition ($buildToolsVersion -eq "10.0.28000.2270") -Message "Windows SDK BuildTools must stay on latest stable 10.0.28000.2270, got $buildToolsVersion"
Assert-True -Condition ($qrCoderVersion -eq "1.8.0") -Message "QRCoder must stay on latest stable 1.8.0, got $qrCoderVersion"
Assert-Contains -Text $cargoManifest -Needle 'edition = "2021"' -Message "Rust core must stay on Rust 2021 edition until a dedicated migration is scheduled."
Assert-Contains -Text $cargoManifest -Needle 'crate-type = ["rlib", "cdylib"]' -Message "Rust core must build both reusable rlib and native cdylib artifacts."

foreach ($architectureSignal in @(
    'Technology stack check',
    'net10.0-windows10.0.22621.0',
    'TargetPlatformMinVersion `10.0.19041.0`',
    'Windows App SDK `2.2.0`',
    'Windows SDK BuildTools `10.0.28000.2270`',
    '`WindowsPackageType=None`',
    'QRCoder `1.8.0`',
    '.NET 10',
    '10.0.9',
    'November 14, 2028',
    'MsQuic v2.5.9',
    'libdatachannel',
    'v0.24.5',
    'SIPSorcery `10.0.11`',
    'Rust 2021 edition',
    'verify-windows-stack-freshness.ps1',
    '-EvidencePath <json>',
    'source URIs',
    'online latest-version results',
    'Stack sources refreshed on 2026-07-03'
)) {
    Assert-Contains -Text $architecture -Needle $architectureSignal -Message "Architecture stack freshness doc missing signal: $architectureSignal"
}

foreach ($agentSignal in @(
    'WinUI 3 + .NET 10',
    'net10.0-windows10.0.22621.0',
    'TargetPlatformMinVersion `10.0.19041.0`',
    'Windows App SDK `2.2.0`',
    'Windows SDK BuildTools `10.0.28000.2270`',
    'QRCoder `1.8.0`',
    '-EvidencePath <json>',
    'verify-windows-stack-freshness.ps1'
)) {
    Assert-Contains -Text $agents -Needle $agentSignal -Message "AGENTS.md stack guidance missing signal: $agentSignal"
}
Assert-True -Condition (-not $agents.Contains("Target WinUI 3 + .NET 9")) -Message "AGENTS.md must not point Windows agents back to the retired .NET 9 target."

if ($CheckOnline) {
    $dotnet10 = Invoke-RestMethod -Uri $sourceUris.dotnetReleaseMetadata
    Assert-True -Condition ($dotnet10."channel-version" -eq "10.0") -Message ".NET release metadata channel mismatch."
    Assert-True -Condition ($dotnet10."support-phase" -eq "active") -Message ".NET 10 must remain active."
    Assert-True -Condition ($dotnet10."eol-date" -eq "2028-11-14") -Message ".NET 10 EOL date changed: $($dotnet10.'eol-date')"
    Assert-True -Condition ($dotnet10."latest-runtime" -eq "10.0.9") -Message ".NET 10 latest runtime changed: $($dotnet10.'latest-runtime')"

    $latestWindowsAppSdk = Get-LatestStableNuGetVersion -PackageId "Microsoft.WindowsAppSDK"
    Assert-True -Condition ($latestWindowsAppSdk -eq $windowsAppSdkVersion) -Message "Microsoft.WindowsAppSDK package is not current stable: project=$windowsAppSdkVersion latest=$latestWindowsAppSdk"

    $latestBuildTools = Get-LatestStableNuGetVersion -PackageId "Microsoft.Windows.SDK.BuildTools"
    Assert-True -Condition ($latestBuildTools -eq $buildToolsVersion) -Message "Microsoft.Windows.SDK.BuildTools package is not current stable: project=$buildToolsVersion latest=$latestBuildTools"

    $latestQrCoder = Get-LatestStableNuGetVersion -PackageId "QRCoder"
    Assert-True -Condition ($latestQrCoder -eq $qrCoderVersion) -Message "QRCoder package is not current stable: project=$qrCoderVersion latest=$latestQrCoder"

    $latestSipsorcery = Get-LatestStableNuGetVersion -PackageId "SIPSorcery"
    Assert-True -Condition ($latestSipsorcery -eq "10.0.11") -Message "SIPSorcery latest stable changed: $latestSipsorcery"

    $msquicLatest = Invoke-RestMethod -Uri $sourceUris.msQuicLatestRelease
    Assert-True -Condition ($msquicLatest.tag_name -eq "v2.5.9") -Message "MsQuic latest stable changed: $($msquicLatest.tag_name)"
    Assert-True -Condition (-not [bool]$msquicLatest.prerelease) -Message "MsQuic latest release must not be a prerelease."

    $libdatachannelLatest = Invoke-RestMethod -Uri $sourceUris.libdatachannelLatestRelease
    Assert-True -Condition ($libdatachannelLatest.tag_name -eq "v0.24.5") -Message "libdatachannel latest stable changed: $($libdatachannelLatest.tag_name)"
    Assert-True -Condition (-not [bool]$libdatachannelLatest.prerelease) -Message "libdatachannel latest release must not be a prerelease."

    $onlineEvidence = [ordered]@{
        dotnet10 = [ordered]@{
            channelVersion = [string]$dotnet10."channel-version"
            supportPhase = [string]$dotnet10."support-phase"
            latestRuntime = [string]$dotnet10."latest-runtime"
            eolDate = [string]$dotnet10."eol-date"
        }
        nugetLatestStable = [ordered]@{
            MicrosoftWindowsAppSdk = $latestWindowsAppSdk
            MicrosoftWindowsSdkBuildTools = $latestBuildTools
            QRCoder = $latestQrCoder
            SIPSorcery = $latestSipsorcery
        }
        githubLatestStable = [ordered]@{
            MsQuic = [ordered]@{
                tagName = [string]$msquicLatest.tag_name
                prerelease = [bool]$msquicLatest.prerelease
            }
            libdatachannel = [ordered]@{
                tagName = [string]$libdatachannelLatest.tag_name
                prerelease = [bool]$libdatachannelLatest.prerelease
            }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $resolvedEvidencePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidencePath)
    $evidenceDirectory = Split-Path -Parent $resolvedEvidencePath
    if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
        New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    }

    $onlineEvidenceValue = if ($CheckOnline) { $onlineEvidence } else { $null }
    [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        checkOnline = [bool]$CheckOnline
	        project = [ordered]@{
	            targetFramework = $targetFramework
	            targetPlatformMinVersion = $targetPlatformMinVersion
	            windowsPackageTypes = @($windowsPackageTypes)
	            packageVersions = [ordered]@{
	                MicrosoftWindowsAppSdk = $windowsAppSdkVersion
	                MicrosoftWindowsSdkBuildTools = $buildToolsVersion
                QRCoder = $qrCoderVersion
            }
        }
        rustCore = [ordered]@{
            edition = "2021"
            crateTypes = @("rlib", "cdylib")
        }
        approvedVersions = [ordered]@{
            dotnetLatestRuntime = "10.0.9"
            dotnetEolDate = "2028-11-14"
            sipsorcery = "10.0.11"
            msquic = "v2.5.9"
            libdatachannel = "v0.24.5"
        }
        sourceUris = $sourceUris
        online = $onlineEvidenceValue
    } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $resolvedEvidencePath -Encoding UTF8
    Write-Output "windows-stack-freshness: evidence=$resolvedEvidencePath"
}

Write-Output "windows-stack-freshness: ok"
