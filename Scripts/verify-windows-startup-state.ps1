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

$sourceFiles = @()
$sourceFiles += Get-ChildItem -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/Services") -Filter "*.cs" |
    Sort-Object Name |
    ForEach-Object { $_.FullName }
$sourceFiles += Get-ChildItem -LiteralPath (Join-Path $RepoRoot "windows/Skybridge.WinClient/Converters") -Filter "*.cs" |
    Sort-Object Name |
    ForEach-Object { $_.FullName }
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceStartupStateBuilder.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModelDependencies.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/SessionViewModelDependencyFactory.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/WindowsNativeRuntimeDependencyFactory.cs"

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows startup-state source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-startup-state-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinStartupState.csproj"
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
    <TargetFramework>net10.0-windows10.0.22621.0</TargetFramework>
    <TargetPlatformMinVersion>10.0.19041.0</TargetPlatformMinVersion>
    <UseWinUI>true</UseWinUI>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
$compileItemText
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="2.2.0" />
    <PackageReference Include="Microsoft.Windows.SDK.BuildTools" Version="10.0.28000.1839" PrivateAssets="all" />
    <PackageReference Include="QRCoder" Version="1.8.0" />
    <PackageReference Include="System.Security.Cryptography.ProtectedData" Version="9.0.0" />
  </ItemGroup>
</Project>
"@

    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using System.Reflection;
using Skybridge.WinClient;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

var runtimeVariables = new[]
{
    "SKYBRIDGE_WINDOWS_RUNTIME",
    "SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER",
    "SKYBRIDGE_WINDOWS_ADAPTER_BINDING",
    "SKYBRIDGE_WINDOWS_LOCAL_ENDPOINT",
    "SKYBRIDGE_WINDOWS_REMOTE_ENDPOINT",
    "SKYBRIDGE_WINDOWS_SELECTED_CANDIDATE_PAIR",
    "SKYBRIDGE_WINDOWS_TRANSPORT_SECRET_FP_HEX",
    "SKYBRIDGE_WINDOWS_CAPABILITY_DIGEST_HEX",
    "SKYBRIDGE_WINDOWS_RELAY_ID",
    "SKYBRIDGE_WINDOWS_ADAPTER_KIND",
    "SKYBRIDGE_WINDOWS_TIMESTAMP_WINDOW_MS"
};
ClearRuntimeEnvironment();

var dependencies = SessionViewModelDependencyFactory.CreateConfigured();
AssertType<FfiEngineClient>(dependencies.EngineClient, "default engine");
AssertType<WindowsDiscoveryBrowserClient>(dependencies.DiscoveryBrowserClient, "default discovery browser");
AssertNestedType<PendingWindowsDnsSdBrowseClient>(dependencies.DiscoveryBrowserClient, "_dnsSdBrowseClient", "default DNS-SD provider");
AssertNestedType<PendingWindowsTransportAdapterClient>(dependencies.ConnectionPreflightClient, "_transportAdapterClient", "default transport adapter");
AssertType<DeviceDiscoveryInputDefaultsClient>(dependencies.DeviceDiscoveryInputDefaultsClient, "default input provider");

var startupBuilder = new WorkspaceStartupStateBuilder(
    dependencies.EngineClient,
    dependencies.DiscoveryBrowserClient,
    dependencies.DeviceDiscoveryInputDefaultsClient,
    dependencies.ConnectionWorkspaceStateClient,
    dependencies.SessionStatusClient,
    dependencies.FeatureCatalogClient,
    dependencies.CoreDiagnosticsClient,
    dependencies.FileTransferClient,
    dependencies.RemoteDesktopClient,
    dependencies.RemoteDesktopProfileCatalogClient,
    dependencies.SystemMonitorClient,
    dependencies.UsbManagementClient,
    dependencies.SettingsClient);
var state = startupBuilder.Build();

AssertEqual("Idle", state.StatusMessage, "initial session status");
AssertEqual("Ready", state.DiscoveryStatus, "initial discovery status");
AssertEqual("Ready", state.DiscoveryBrowserStatus, "initial discovery browser status");
AssertEqual("Ready", state.ManualConnectionStatus, "initial manual connection status");
AssertEqual("Ready", state.CrossNetworkStatus, "initial cross-network status");
AssertEqual("Ready", state.PairingStatus, "initial pairing status");
AssertEqual("Ready", state.ConnectionPreflightStatus, "initial connection preflight status");
AssertEqual(false, state.IsDiscoveryScanning, "initial discovery scanning");
AssertEqual(EngineConnectionState.Disconnected, state.ConnectionState, "initial connection state");

AssertEqual("_skybridge._udp", state.DiscoveryService, "default discovery service");
AssertEqual("11550", state.ManualConnectionPort, "default manual connection port");
AssertEqual("", state.DiscoveryTxtRecord, "default discovery TXT input");
AssertEqual("", state.PairingConnectionCode, "default pairing code input");
// BATCH 2 (B1) — smart-connection-code lease default. Startup default is the short-lived
// assistance window; selecting day-stable extends the REAL generated-code TTL. Pinning the
// default keeps the lease toggle wired to a real backend lifetime, not a label.
AssertEqual("shortLived", state.ConnectionCodeLeaseMode, "default connection-code lease mode");
AssertSequence(
    "default DNS-SD service query order",
    state.DiscoveryBrowserInputPolicy.ServiceQueryOrder,
    new[] { "_skybridge._udp", "_skybridge._tcp" });
AssertEqual(15, state.DiscoveryBrowserInputPolicy.ExtendedSearchSeconds, "default extended search seconds");
AssertEqual(15, state.ExtendedSearchCountdown, "startup extended search countdown");

AssertEqual(dependencies.CoreDiagnosticsClient.BuildInitialStatus(), state.CoreDiagnosticsStatus, "core diagnostics initial status");
AssertEqual(dependencies.FileTransferClient.BuildInitialStatus(), state.FileTransferStatus, "file transfer initial status");
AssertEqual(dependencies.RemoteDesktopClient.BuildInitialStatus(), state.RemoteDesktopStatus, "remote desktop initial status");
AssertEqual(dependencies.SystemMonitorClient.BuildInitialStatus(), state.SystemMonitorStatus, "system monitor initial status");
AssertEqual(dependencies.UsbManagementClient.BuildInitialStatus(), state.UsbManagementStatus, "USB management initial status");
AssertEqual(dependencies.SettingsClient.BuildInitialStatus(), state.SettingsStatus, "settings initial status");

AssertSequence(
    "startup feature order",
    state.FeatureEntries.Select(feature => feature.Id.ToString()),
    new[]
    {
        "Dashboard",
        "DeviceDiscovery",
        "UsbManagement",
        "FileTransfer",
        "RemoteDesktop",
        "Quantum",
        "SystemMonitor",
        "Settings"
    });
AssertEqual(FeatureEntryId.Dashboard, state.SelectedFeature.Id, "default selected feature");
AssertEqual(true, state.FeatureEntries.All(feature => feature.IsImplemented), "all startup features implemented");

AssertSequence(
    "default bitrate profiles",
    state.RemoteDesktopProfileCatalog.BitrateProfiles,
    new[] { "Low", "Medium", "High" });
AssertSequence(
    "default framerate profiles",
    state.RemoteDesktopProfileCatalog.FramerateProfiles,
    new[] { "Fps30", "Fps60" });
AssertEqual("Medium", state.RemoteDesktopProfileCatalog.DefaultBitrateProfile, "default bitrate profile");
AssertEqual("Fps60", state.RemoteDesktopProfileCatalog.DefaultFramerateProfile, "default framerate profile");

var defaultInputs = string.Join(
    "|",
    new[]
    {
        state.DiscoveryService,
        state.ManualConnectionPort,
        state.DiscoveryTxtRecord,
        state.PairingConnectionCode
    });
AssertDoesNotContain(defaultInputs, "deviceId=", "startup must not preload sample Bonjour TXT");
AssertDoesNotContain(defaultInputs, "pubKeyFP=", "startup must not preload sample pubKeyFP");
AssertDoesNotContain(defaultInputs, "skybridge-pair:v1", "startup must not preload pairing material");
AssertDoesNotContain(defaultInputs, "sample", "startup must not preload sample material");

Console.WriteLine("windows-startup-state: ok");

void ClearRuntimeEnvironment()
{
    foreach (var variable in runtimeVariables)
    {
        Environment.SetEnvironmentVariable(variable, null);
    }
}

static void AssertType<TExpected>(object value, string label)
{
    if (value is not TExpected)
    {
        throw new InvalidOperationException($"{label}: expected {typeof(TExpected).Name}, got {value.GetType().Name}.");
    }
}

static void AssertNestedType<TExpected>(object owner, string fieldName, string label)
{
    var field = owner.GetType().GetField(fieldName, BindingFlags.Instance | BindingFlags.NonPublic);
    if (field is null)
    {
        throw new InvalidOperationException($"{label}: missing field {fieldName}.");
    }

    var value = field.GetValue(owner);
    if (value is not TExpected)
    {
        throw new InvalidOperationException($"{label}: expected {typeof(TExpected).Name}, got {value?.GetType().Name ?? "<null>"}.");
    }
}

static void AssertSequence<T>(string label, IEnumerable<T> actualValues, IReadOnlyList<T> expectedValues)
{
    var actual = actualValues.ToArray();
    if (actual.Length != expectedValues.Count)
    {
        throw new InvalidOperationException($"{label}: expected {expectedValues.Count} items, got {actual.Length}.");
    }

    for (var index = 0; index < expectedValues.Count; index++)
    {
        AssertEqual(expectedValues[index], actual[index], $"{label}[{index}]");
    }
}

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
    }
}

static void AssertDoesNotContain(string text, string unexpected, string label)
{
    if (text.Contains(unexpected, StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException($"{label}: unexpected '{unexpected}' in '{text}'.");
    }
}
'@

    & dotnet run --project $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "windows startup-state smoke failed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $resolvedTempParent = [System.IO.Path]::GetFullPath($tempParent)
        $isOwnedSmokeDir =
            [System.IO.Path]::GetFileName($resolvedTempRoot).StartsWith(
                "skybridge-win-startup-state-",
                [StringComparison]::Ordinal) -and
            $resolvedTempRoot.StartsWith(
                $resolvedTempParent,
                [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
