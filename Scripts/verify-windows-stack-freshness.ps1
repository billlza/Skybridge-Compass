param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$CheckOnline,
    [string]$EvidencePath = ""
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

    $package = $Project.SelectNodes("/Project/ItemGroup/PackageReference") |
        Where-Object { $_.GetAttribute("Include") -eq $PackageId } |
        Select-Object -First 1
    Assert-True -Condition ($null -ne $package) -Message "Missing PackageReference: $PackageId"
    return [string]$package.GetAttribute("Version")
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

function Get-CargoDependencyVersion {
    param(
        [string]$Manifest,
        [string]$Dependency
    )

    $escapedDependency = [regex]::Escape($Dependency)
    $pattern = '(?m)^\s*' + $escapedDependency + '\s*=\s*(?:"(?<simple>[^"]+)"|\{[^\r\n}]*\bversion\s*=\s*"(?<table>[^"]+)")'
    $match = [regex]::Match($Manifest, $pattern)
    Assert-True -Condition $match.Success -Message "Missing Cargo dependency version: $Dependency"
    $version = if ($match.Groups["simple"].Success) {
        $match.Groups["simple"].Value
    } else {
        $match.Groups["table"].Value
    }
    return [string]$version
}

function Get-LatestStableCrateVersion {
    param([string]$CrateName)

    $headers = @{ "User-Agent" = "Skybridge-Compass-dependency-freshness/1.0" }
    $crate = Invoke-RestMethod -Headers $headers -Uri "https://crates.io/api/v1/crates/$CrateName"
    $version = [string]$crate.crate.max_stable_version
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($version)) -Message "Crate has no stable version: $CrateName"
    return $version
}

$sourceUris = [ordered]@{
    dotnetReleaseMetadata = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/10.0/releases.json"
    microsoftWindowsAppSdkNuGet = "https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk/index.json"
    microsoftWindowsSdkBuildToolsNuGet = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/index.json"
    qrCoderNuGet = "https://api.nuget.org/v3-flatcontainer/qrcoder/index.json"
    vorticeDirect3D12NuGet = "https://api.nuget.org/v3-flatcontainer/vortice.direct3d12/index.json"
    vorticeDxgiNuGet = "https://api.nuget.org/v3-flatcontainer/vortice.dxgi/index.json"
    vorticeMathematicsNuGet = "https://api.nuget.org/v3-flatcontainer/vortice.mathematics/index.json"
    vorticeWinUiNuGet = "https://api.nuget.org/v3-flatcontainer/vortice.winui/index.json"
    vorticeD3DCompilerNuGet = "https://api.nuget.org/v3-flatcontainer/vortice.d3dcompiler/index.json"
    protectedDataNuGet = "https://api.nuget.org/v3-flatcontainer/system.security.cryptography.protecteddata/index.json"
    sipsorceryNuGet = "https://api.nuget.org/v3-flatcontainer/sipsorcery/index.json"
    rustStableManifest = "https://static.rust-lang.org/dist/channel-rust-stable.toml"
    cratesApi = "https://crates.io/api/v1/crates"
    checkoutLatestRelease = "https://api.github.com/repos/actions/checkout/releases/latest"
    setupDotnetLatestRelease = "https://api.github.com/repos/actions/setup-dotnet/releases/latest"
    msQuicLatestRelease = "https://api.github.com/repos/microsoft/msquic/releases/latest"
    libdatachannelLatestRelease = "https://api.github.com/repos/paullouisageneau/libdatachannel/releases/latest"
}
$onlineEvidence = [ordered]@{}

$winClientProjectPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Skybridge.WinClient.csproj"
$contractTestsProjectPath = Join-Path $RepoRoot "windows/Skybridge.WinClient.ContractTests/Skybridge.WinClient.ContractTests.csproj"
$webRtcHelperProjectPath = Join-Path $RepoRoot "windows/Skybridge.WebRtcHelper/Skybridge.WebRtcHelper.csproj"
$cargoManifestPath = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
$globalJsonPath = Join-Path $RepoRoot "global.json"
$rustToolchainPath = Join-Path $RepoRoot "rust-toolchain.toml"
$workflowPath = Join-Path $RepoRoot ".github/workflows/windows-portability.yml"
$architecturePath = Join-Path $RepoRoot "docs/windows-architecture.md"
$agentsPath = Join-Path $RepoRoot "AGENTS.md"

foreach ($path in @($winClientProjectPath, $contractTestsProjectPath, $webRtcHelperProjectPath, $cargoManifestPath, $globalJsonPath, $rustToolchainPath, $workflowPath, $architecturePath, $agentsPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing stack freshness file: $path"
}

$project = [xml](Get-Content -Raw -LiteralPath $winClientProjectPath)
$targetFrameworkNode = $project.SelectSingleNode("/Project/PropertyGroup/TargetFramework")
$targetPlatformMinVersionNode = $project.SelectSingleNode("/Project/PropertyGroup/TargetPlatformMinVersion")
Assert-True -Condition ($null -ne $targetFrameworkNode) -Message "Windows client is missing TargetFramework."
Assert-True -Condition ($null -ne $targetPlatformMinVersionNode) -Message "Windows client is missing TargetPlatformMinVersion."
$targetFramework = $targetFrameworkNode.InnerText.Trim()
$targetPlatformMinVersion = $targetPlatformMinVersionNode.InnerText.Trim()
$windowsPackageTypes = @($project.SelectNodes("/Project/PropertyGroup/WindowsPackageType") |
    ForEach-Object { $_.InnerText.Trim() })
$windowsAppSdkVersion = Get-PackageReferenceVersion -Project $project -PackageId "Microsoft.WindowsAppSDK"
$buildToolsVersion = Get-PackageReferenceVersion -Project $project -PackageId "Microsoft.Windows.SDK.BuildTools"
$qrCoderVersion = Get-PackageReferenceVersion -Project $project -PackageId "QRCoder"
$vorticeDirect3D12Version = Get-PackageReferenceVersion -Project $project -PackageId "Vortice.Direct3D12"
$vorticeDxgiVersion = Get-PackageReferenceVersion -Project $project -PackageId "Vortice.DXGI"
$vorticeMathematicsVersion = Get-PackageReferenceVersion -Project $project -PackageId "Vortice.Mathematics"
$vorticeWinUiVersion = Get-PackageReferenceVersion -Project $project -PackageId "Vortice.WinUI"
$vorticeD3DCompilerVersion = Get-PackageReferenceVersion -Project $project -PackageId "Vortice.D3DCompiler"
$protectedDataVersion = Get-PackageReferenceVersion -Project $project -PackageId "System.Security.Cryptography.ProtectedData"
$contractTestsProject = [xml](Get-Content -Raw -LiteralPath $contractTestsProjectPath)
$contractProtectedDataVersion = Get-PackageReferenceVersion -Project $contractTestsProject -PackageId "System.Security.Cryptography.ProtectedData"
$webRtcHelperProject = [xml](Get-Content -Raw -LiteralPath $webRtcHelperProjectPath)
$sipsorceryVersion = Get-PackageReferenceVersion -Project $webRtcHelperProject -PackageId "SIPSorcery"
$cargoManifest = Get-Content -Raw -LiteralPath $cargoManifestPath
$globalJson = Get-Content -Raw -LiteralPath $globalJsonPath | ConvertFrom-Json
$rustToolchain = Get-Content -Raw -LiteralPath $rustToolchainPath
$workflow = Get-Content -Raw -LiteralPath $workflowPath
$architecture = Get-Content -Raw -LiteralPath $architecturePath
$agents = Get-Content -Raw -LiteralPath $agentsPath

Assert-True -Condition ($targetFramework -eq "net10.0-windows10.0.22621.0") -Message "Windows client must target net10.0-windows10.0.22621.0, got $targetFramework"
Assert-True -Condition ($targetPlatformMinVersion -eq "10.0.19041.0") -Message "Windows client must keep TargetPlatformMinVersion=10.0.19041.0, got $targetPlatformMinVersion"
Assert-True -Condition ($windowsPackageTypes -contains "None") -Message "Windows client must keep a default WindowsPackageType=None path so unpackaged WinUI auto-initializes the Windows App SDK runtime. Actual=[$($windowsPackageTypes -join ', ')]"
Assert-True -Condition ($windowsAppSdkVersion -eq "2.4.0") -Message "Windows App SDK must stay on latest stable 2.4.0, got $windowsAppSdkVersion"
Assert-True -Condition ($buildToolsVersion -eq "10.0.28000.2705") -Message "Windows SDK BuildTools must stay on latest stable 10.0.28000.2705, got $buildToolsVersion"
Assert-True -Condition ($qrCoderVersion -eq "1.8.0") -Message "QRCoder must stay on latest stable 1.8.0, got $qrCoderVersion"
foreach ($vorticeVersion in @($vorticeDirect3D12Version, $vorticeDxgiVersion, $vorticeWinUiVersion, $vorticeD3DCompilerVersion)) {
    Assert-True -Condition ($vorticeVersion -eq "3.8.3") -Message "All Vortice packages must stay aligned on latest stable 3.8.3, got $vorticeVersion"
}
Assert-True -Condition ($vorticeMathematicsVersion -eq "2.1.1") -Message "Vortice.Mathematics must stay on latest stable 2.1.1, got $vorticeMathematicsVersion"
Assert-True -Condition ($protectedDataVersion -eq "10.0.12") -Message "ProtectedData must stay on latest stable 10.0.12, got $protectedDataVersion"
Assert-True -Condition ($contractProtectedDataVersion -eq $protectedDataVersion) -Message "ContractTests ProtectedData version must match the product project. product=$protectedDataVersion tests=$contractProtectedDataVersion"
Assert-True -Condition ($sipsorceryVersion -eq "10.0.16") -Message "SIPSorcery must stay on latest stable 10.0.16, got $sipsorceryVersion"
Assert-Contains -Text $cargoManifest -Needle 'edition = "2021"' -Message "Rust core must stay on Rust 2021 edition until a dedicated migration is scheduled."
Assert-Contains -Text $cargoManifest -Needle 'crate-type = ["rlib", "cdylib"]' -Message "Rust core must build both reusable rlib and native cdylib artifacts."
Assert-True -Condition ([string]$globalJson.sdk.version -eq "10.0.401") -Message "global.json must pin the latest .NET 10 SDK 10.0.401."
Assert-True -Condition ([string]$globalJson.sdk.rollForward -eq "latestPatch") -Message "global.json must roll forward only within the pinned feature band."
Assert-True -Condition (-not [bool]$globalJson.sdk.allowPrerelease) -Message "global.json must reject prerelease SDKs."
Assert-Contains -Text $rustToolchain -Needle 'channel = "1.98.1"' -Message "rust-toolchain.toml must pin stable Rust 1.98.1."
Assert-Contains -Text $workflow -Needle 'actions/checkout@v7.0.1' -Message "Windows CI must pin actions/checkout v7.0.1."
Assert-Contains -Text $workflow -Needle 'actions/setup-dotnet@v6.0.0' -Message "Windows CI must pin actions/setup-dotnet v6.0.0."
Assert-Contains -Text $workflow -Needle 'global-json-file: global.json' -Message "Windows CI must consume the repository .NET SDK pin."
Assert-Contains -Text $workflow -Needle 'cargo install cargo-llvm-cov --version 0.9.1 --locked' -Message "Windows CI must pin cargo-llvm-cov 0.9.1."

$approvedCargoVersions = [ordered]@{
    "thiserror" = "2.0.20"
    "async-trait" = "0.1.92"
    "tokio" = "1.53.1"
    "serde" = "1.0.229"
    "serde_json" = "1.0.151"
    "time" = "0.3.55"
    "p256" = "0.14.0"
    "getrandom" = "0.4.3"
    "aes-gcm" = "0.11.1"
    "hkdf" = "0.13.0"
    "sha2" = "0.11.0"
    "zeroize" = "1.9.0"
    "ml-kem" = "0.3.2"
    "ml-dsa" = "0.1.1"
    "x-wing" = "0.1.0"
    "x25519-dalek" = "3.0.0"
}
$cargoVersions = [ordered]@{}
foreach ($dependency in $approvedCargoVersions.Keys) {
    $cargoVersions[$dependency] = Get-CargoDependencyVersion -Manifest $cargoManifest -Dependency $dependency
    Assert-True -Condition ($cargoVersions[$dependency] -eq $approvedCargoVersions[$dependency]) -Message "Cargo dependency $dependency must stay on latest stable $($approvedCargoVersions[$dependency]), got $($cargoVersions[$dependency])"
}

foreach ($architectureSignal in @(
    'Technology stack check',
    'net10.0-windows10.0.22621.0',
    'TargetPlatformMinVersion `10.0.19041.0`',
    'Windows App SDK `2.4.0`',
    'Windows SDK BuildTools `10.0.28000.2705`',
    '`WindowsPackageType=None`',
    'QRCoder `1.8.0`',
    '.NET 10',
    '10.0.12',
    '10.0.401',
    'November 14, 2028',
    'MsQuic v2.6.1',
    'libdatachannel',
    'v0.24.5',
    'SIPSorcery `10.0.16`',
    'Rust 2021 edition',
    'verify-windows-stack-freshness.ps1',
    '-EvidencePath <json>',
    'source URIs',
    'online latest-version results',
    'Stack sources refreshed on 2026-09-11'
)) {
    Assert-Contains -Text $architecture -Needle $architectureSignal -Message "Architecture stack freshness doc missing signal: $architectureSignal"
}

foreach ($agentSignal in @(
    'WinUI 3 + .NET 10',
    'net10.0-windows10.0.22621.0',
    'TargetPlatformMinVersion `10.0.19041.0`',
    'Windows App SDK `2.4.0`',
    'Windows SDK BuildTools `10.0.28000.2705`',
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
    Assert-True -Condition ($dotnet10."latest-runtime" -eq "10.0.12") -Message ".NET 10 latest runtime changed: $($dotnet10.'latest-runtime')"
    Assert-True -Condition ($dotnet10."latest-sdk" -eq [string]$globalJson.sdk.version) -Message ".NET 10 SDK pin is stale: project=$($globalJson.sdk.version) latest=$($dotnet10.'latest-sdk')"

    $latestWindowsAppSdk = Get-LatestStableNuGetVersion -PackageId "Microsoft.WindowsAppSDK"
    Assert-True -Condition ($latestWindowsAppSdk -eq $windowsAppSdkVersion) -Message "Microsoft.WindowsAppSDK package is not current stable: project=$windowsAppSdkVersion latest=$latestWindowsAppSdk"

    $latestBuildTools = Get-LatestStableNuGetVersion -PackageId "Microsoft.Windows.SDK.BuildTools"
    Assert-True -Condition ($latestBuildTools -eq $buildToolsVersion) -Message "Microsoft.Windows.SDK.BuildTools package is not current stable: project=$buildToolsVersion latest=$latestBuildTools"

    $latestQrCoder = Get-LatestStableNuGetVersion -PackageId "QRCoder"
    Assert-True -Condition ($latestQrCoder -eq $qrCoderVersion) -Message "QRCoder package is not current stable: project=$qrCoderVersion latest=$latestQrCoder"

    $latestVorticeDirect3D12 = Get-LatestStableNuGetVersion -PackageId "Vortice.Direct3D12"
    $latestVorticeDxgi = Get-LatestStableNuGetVersion -PackageId "Vortice.DXGI"
    $latestVorticeMathematics = Get-LatestStableNuGetVersion -PackageId "Vortice.Mathematics"
    $latestVorticeWinUi = Get-LatestStableNuGetVersion -PackageId "Vortice.WinUI"
    $latestVorticeD3DCompiler = Get-LatestStableNuGetVersion -PackageId "Vortice.D3DCompiler"
    Assert-True -Condition ($latestVorticeDirect3D12 -eq $vorticeDirect3D12Version) -Message "Vortice.Direct3D12 is not current stable: project=$vorticeDirect3D12Version latest=$latestVorticeDirect3D12"
    Assert-True -Condition ($latestVorticeDxgi -eq $vorticeDxgiVersion) -Message "Vortice.DXGI is not current stable: project=$vorticeDxgiVersion latest=$latestVorticeDxgi"
    Assert-True -Condition ($latestVorticeMathematics -eq $vorticeMathematicsVersion) -Message "Vortice.Mathematics is not current stable: project=$vorticeMathematicsVersion latest=$latestVorticeMathematics"
    Assert-True -Condition ($latestVorticeWinUi -eq $vorticeWinUiVersion) -Message "Vortice.WinUI is not current stable: project=$vorticeWinUiVersion latest=$latestVorticeWinUi"
    Assert-True -Condition ($latestVorticeD3DCompiler -eq $vorticeD3DCompilerVersion) -Message "Vortice.D3DCompiler is not current stable: project=$vorticeD3DCompilerVersion latest=$latestVorticeD3DCompiler"

    $latestProtectedData = Get-LatestStableNuGetVersion -PackageId "System.Security.Cryptography.ProtectedData"
    Assert-True -Condition ($latestProtectedData -eq $protectedDataVersion) -Message "ProtectedData is not current stable: project=$protectedDataVersion latest=$latestProtectedData"

    $latestSipsorcery = Get-LatestStableNuGetVersion -PackageId "SIPSorcery"
    Assert-True -Condition ($latestSipsorcery -eq $sipsorceryVersion) -Message "SIPSorcery is not current stable: project=$sipsorceryVersion latest=$latestSipsorcery"

    $rustStableManifest = Invoke-RestMethod -Uri $sourceUris.rustStableManifest
    $rustVersionMatch = [regex]::Match([string]$rustStableManifest, '(?ms)^\[pkg\.rust\]\s+version\s*=\s*"(?<version>\d+\.\d+\.\d+)\s')
    Assert-True -Condition $rustVersionMatch.Success -Message "Official Rust stable manifest does not contain pkg.rust.version."
    $latestRustStable = $rustVersionMatch.Groups["version"].Value
    Assert-True -Condition ($latestRustStable -eq "1.98.1") -Message "Rust stable toolchain changed: $latestRustStable"

    $latestCrates = [ordered]@{}
    foreach ($dependency in $approvedCargoVersions.Keys) {
        $latestCrates[$dependency] = Get-LatestStableCrateVersion -CrateName $dependency
        Assert-True -Condition ($latestCrates[$dependency] -eq $cargoVersions[$dependency]) -Message "Cargo dependency $dependency is not current stable: project=$($cargoVersions[$dependency]) latest=$($latestCrates[$dependency])"
    }
    $latestCargoLlvmCov = Get-LatestStableCrateVersion -CrateName "cargo-llvm-cov"
    Assert-True -Condition ($latestCargoLlvmCov -eq "0.9.1") -Message "cargo-llvm-cov latest stable changed: $latestCargoLlvmCov"

    $checkoutLatest = Invoke-RestMethod -Uri $sourceUris.checkoutLatestRelease
    Assert-True -Condition ($checkoutLatest.tag_name -eq "v7.0.1") -Message "actions/checkout latest stable changed: $($checkoutLatest.tag_name)"
    Assert-True -Condition (-not [bool]$checkoutLatest.prerelease) -Message "actions/checkout latest release must not be a prerelease."
    $setupDotnetLatest = Invoke-RestMethod -Uri $sourceUris.setupDotnetLatestRelease
    Assert-True -Condition ($setupDotnetLatest.tag_name -eq "v6.0.0") -Message "actions/setup-dotnet latest stable changed: $($setupDotnetLatest.tag_name)"
    Assert-True -Condition (-not [bool]$setupDotnetLatest.prerelease) -Message "actions/setup-dotnet latest release must not be a prerelease."

    $msquicLatest = Invoke-RestMethod -Uri $sourceUris.msQuicLatestRelease
    Assert-True -Condition ($msquicLatest.tag_name -eq "v2.6.1") -Message "MsQuic latest stable changed: $($msquicLatest.tag_name)"
    Assert-True -Condition (-not [bool]$msquicLatest.prerelease) -Message "MsQuic latest release must not be a prerelease."

    $libdatachannelLatest = Invoke-RestMethod -Uri $sourceUris.libdatachannelLatestRelease
    Assert-True -Condition ($libdatachannelLatest.tag_name -eq "v0.24.5") -Message "libdatachannel latest stable changed: $($libdatachannelLatest.tag_name)"
    Assert-True -Condition (-not [bool]$libdatachannelLatest.prerelease) -Message "libdatachannel latest release must not be a prerelease."

    $onlineEvidence = [ordered]@{
        dotnet10 = [ordered]@{
            channelVersion = [string]$dotnet10."channel-version"
            supportPhase = [string]$dotnet10."support-phase"
            latestRuntime = [string]$dotnet10."latest-runtime"
            latestSdk = [string]$dotnet10."latest-sdk"
            eolDate = [string]$dotnet10."eol-date"
        }
        nugetLatestStable = [ordered]@{
            MicrosoftWindowsAppSdk = $latestWindowsAppSdk
            MicrosoftWindowsSdkBuildTools = $latestBuildTools
            QRCoder = $latestQrCoder
            VorticeDirect3D12 = $latestVorticeDirect3D12
            VorticeDxgi = $latestVorticeDxgi
            VorticeMathematics = $latestVorticeMathematics
            VorticeWinUi = $latestVorticeWinUi
            VorticeD3DCompiler = $latestVorticeD3DCompiler
            ProtectedData = $latestProtectedData
            SIPSorcery = $latestSipsorcery
        }
        cratesLatestStable = $latestCrates
        rustStable = $latestRustStable
        cargoLlvmCov = $latestCargoLlvmCov
        githubLatestStable = [ordered]@{
            Checkout = [ordered]@{
                tagName = [string]$checkoutLatest.tag_name
                prerelease = [bool]$checkoutLatest.prerelease
            }
            SetupDotnet = [ordered]@{
                tagName = [string]$setupDotnetLatest.tag_name
                prerelease = [bool]$setupDotnetLatest.prerelease
            }
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
                VorticeDirect3D12 = $vorticeDirect3D12Version
                VorticeDxgi = $vorticeDxgiVersion
                VorticeMathematics = $vorticeMathematicsVersion
                VorticeWinUi = $vorticeWinUiVersion
                VorticeD3DCompiler = $vorticeD3DCompilerVersion
                ProtectedData = $protectedDataVersion
                SIPSorcery = $sipsorceryVersion
            }
        }
        rustCore = [ordered]@{
            edition = "2021"
            crateTypes = @("rlib", "cdylib")
            toolchain = "1.98.1"
            dependencies = $cargoVersions
        }
        approvedVersions = [ordered]@{
            dotnetLatestRuntime = "10.0.12"
            dotnetLatestSdk = "10.0.401"
            dotnetEolDate = "2028-11-14"
            rustStable = "1.98.1"
            cargoLlvmCov = "0.9.1"
            checkout = "v7.0.1"
            setupDotnet = "v6.0.0"
            sipsorcery = "10.0.16"
            msquic = "v2.6.1"
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
