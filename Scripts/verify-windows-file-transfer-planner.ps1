param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

$sourceFiles = @(
    "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows file-transfer planner source file: $sourceFile"
}

$coreManifest = Join-Path $RepoRoot "core/skybridge-core/Cargo.toml"
Assert-True -Condition (Test-Path -LiteralPath $coreManifest) -Message "Missing Rust Core manifest: $coreManifest"

& cargo build --manifest-path $coreManifest --lib
Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "Rust Core library build failed with exit code $LASTEXITCODE"

if ($IsWindows) {
    $nativeLibraryName = "skybridge_core.dll"
} elseif ($IsMacOS) {
    $nativeLibraryName = "libskybridge_core.dylib"
} else {
    $nativeLibraryName = "libskybridge_core.so"
}

$nativeLibrary = Join-Path $RepoRoot (Join-Path "core/skybridge-core/target/debug" $nativeLibraryName)
Assert-True -Condition (Test-Path -LiteralPath $nativeLibrary) -Message "Missing built Rust Core library: $nativeLibrary"

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-file-transfer-planner-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinFileTransferPlannerSmoke.csproj"
$testProgram = Join-Path $tempRoot "Program.cs"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $programXml = [System.Security.SecurityElement]::Escape($testProgram)
    $compileItems = @("    <Compile Include=""$programXml"" />")
    foreach ($sourceFile in $sourceFiles) {
        $sourceFileXml = [System.Security.SecurityElement]::Escape($sourceFile)
        $compileItems += "    <Compile Include=""$sourceFileXml"" />"
    }
    $compileItemText = $compileItems -join "`r`n"

    Set-Content -LiteralPath $testProject -Encoding UTF8 -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
$compileItemText
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="QRCoder" Version="1.8.0" />
  </ItemGroup>
</Project>
"@

    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using Skybridge.WinClient.Services;

var bridge = new CoreBridge();
var channelMappings = BuildWebRtcChannelMappings();
var manifestFiles = new[]
{
    new FileTransferManifestFile(
        "sample.txt",
        "sample.txt",
        12,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "text/plain")
};
var readyCandidate = new FileTransferRouteCandidate(
    "mac-1",
    "Desk Mac",
    "Desk-Mac._skybridge-transfer._tcp.local.",
    "192.168.31.20",
    "_skybridge-transfer._tcp",
    8080,
    CoreFileTransferRouteSource.AuthenticatedSession,
    CoreFileTransferPortProvenance.ListenerTruth,
    7);

var ready = await bridge.PlanFileTransferReadinessAsync(
    new[] { readyCandidate },
    "mac-1",
    7,
    CoreFileTransferManifestMode.Transfer,
    manifestFiles,
    1024 * 1024,
    channelMappings);
AssertEqual(CoreFileTransferReadinessStatus.Ready, ready.Status, "ready status");
AssertEqual(CoreFileTransferReadinessCode.Ok, ready.Code, "ready code");
AssertEqual(CoreFileTransferAddressClass.LanDirect, ready.SelectedAddressClass, "selected address class");
AssertEqual("mac-1", ready.SelectedPeerId, "selected peer id");
AssertEqual("192.168.31.20", ready.SelectedHost, "selected host");
AssertEqual((ushort)8080, ready.SelectedPort, "selected port");
AssertEqual((ushort)1, ready.ManifestVersion, "manifest version");
AssertEqual((nuint)1, ready.ManifestFileCount, "manifest file count");
AssertEqual(12UL, ready.ManifestTotalBytes, "manifest bytes");
AssertEqual(1UL, ready.ManifestTotalChunks, "manifest chunks");
AssertEqual(32, ready.ManifestDigest?.Length ?? 0, "manifest digest");
AssertEqual((CoreAdapterBindingKind?)CoreAdapterBindingKind.WebRtcDataChannel, ready.FileChannelBindingKind, "file channel binding");

var intentOnly = await bridge.PlanFileTransferReadinessAsync(
    Array.Empty<FileTransferRouteCandidate>(),
    null,
    null,
    CoreFileTransferManifestMode.IntentOnly,
    Array.Empty<FileTransferManifestFile>(),
    1024 * 1024,
    channelMappings);
AssertEqual(CoreFileTransferReadinessStatus.IntentOnly, intentOnly.Status, "intent-only status");
AssertEqual(CoreFileTransferReadinessCode.IntentOnlyNoFiles, intentOnly.Code, "intent-only code");
AssertEqual(true, intentOnly.ManifestDigest is null, "intent-only digest");
AssertEqual((CoreAdapterBindingKind?)CoreAdapterBindingKind.WebRtcDataChannel, intentOnly.FileChannelBindingKind, "intent-only file channel binding");

var stale = await bridge.PlanFileTransferReadinessAsync(
    new[]
    {
        readyCandidate with
        {
            Port = 49444,
            PortProvenance = CoreFileTransferPortProvenance.RegistryState
        }
    },
    "mac-1",
    7,
    CoreFileTransferManifestMode.Transfer,
    manifestFiles,
    1024 * 1024,
    channelMappings);
AssertEqual(CoreFileTransferReadinessStatus.Blocked, stale.Status, "stale status");
AssertEqual(CoreFileTransferReadinessCode.RouteStalePort, stale.Code, "stale code");

var pathRejected = await bridge.PlanFileTransferReadinessAsync(
    new[] { readyCandidate },
    "mac-1",
    7,
    CoreFileTransferManifestMode.Transfer,
    new[]
    {
        manifestFiles[0] with
        {
            RelativePath = "../sample.txt"
        }
    },
    1024 * 1024,
    channelMappings);
AssertEqual(CoreFileTransferReadinessStatus.Blocked, pathRejected.Status, "path rejected status");
AssertEqual(CoreFileTransferReadinessCode.ManifestPathRejected, pathRejected.Code, "path rejected code");

var snapshot = await new FileTransferWorkspaceClient(bridge).BuildReadOnlySnapshotAsync();
AssertEqual("Manifest planner", snapshot.Queue[0].Name, "snapshot queue planner row");
AssertEqual("IntentOnly", snapshot.Queue[0].State, "snapshot planner state");
AssertEqual(true, snapshot.Security.Any(fact => fact.Label == "Manifest planner" && fact.Value == "IntentOnly"), "snapshot manifest planner fact");
AssertEqual(false, snapshot.Queue.Any(item => item.Name == "sample.mov"), "snapshot removed fake sample queue item");
AssertEqual(false, snapshot.History.Any(item => item.Name == "archive.zip"), "snapshot removed fake archive history item");

Console.WriteLine("windows-file-transfer-planner: ok");

static IReadOnlyList<ChannelMapping> BuildWebRtcChannelMappings() =>
    new[]
    {
        new ChannelMapping(CoreChannelKind.Control, CoreReliabilityKind.ReliableOrdered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.File, CoreReliabilityKind.ReliableOrdered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.Clipboard, CoreReliabilityKind.ReliableOrdered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.Telemetry, CoreReliabilityKind.ReliableUnordered, 0, CoreAdapterBindingKind.WebRtcDataChannel, true),
        new ChannelMapping(CoreChannelKind.Realtime, CoreReliabilityKind.PartialReliable, 3, CoreAdapterBindingKind.WebRtcDataChannel, true)
    };

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected {expected}, got {actual}");
    }
}
'@

    dotnet build $testProject --nologo
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "windows-file-transfer-planner build failed with exit code $LASTEXITCODE"

    $outputDir = Join-Path $tempRoot "bin/Debug/net10.0"
    $nativeCopy = Join-Path $outputDir $nativeLibraryName
    Copy-Item -LiteralPath $nativeLibrary -Destination $nativeCopy -Force
    if ($IsMacOS) {
        & codesign --force --sign - $nativeCopy
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "macOS ad-hoc signing failed for $nativeCopy"
    }

    $testAssembly = Join-Path $outputDir "Skybridge.WinFileTransferPlannerSmoke.dll"
    dotnet $testAssembly
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "windows-file-transfer-planner smoke failed with exit code $LASTEXITCODE"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
