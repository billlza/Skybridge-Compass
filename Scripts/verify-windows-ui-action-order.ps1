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
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/Converters/LabelKeyToLocalizedConverter.cs"
$sourceFiles += Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceItemViews.cs"

foreach ($sourceFile in $sourceFiles) {
    Assert-True -Condition (Test-Path -LiteralPath $sourceFile) -Message "Missing Windows UI action-order source file: $sourceFile"
}

$tempParent = [System.IO.Path]::GetTempPath()
$tempRoot = Join-Path $tempParent ("skybridge-win-ui-action-order-" + [guid]::NewGuid().ToString("N"))
$testProject = Join-Path $tempRoot "Skybridge.WinUiActionOrder.csproj"
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
    <PackageReference Include="Microsoft.Windows.SDK.BuildTools" Version="10.0.28000.2270" PrivateAssets="all" />
    <PackageReference Include="QRCoder" Version="1.8.0" />
    <PackageReference Include="System.Security.Cryptography.ProtectedData" Version="9.0.0" />
  </ItemGroup>
</Project>
"@

    Set-Content -LiteralPath $testProgram -Encoding UTF8 -Value @'
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.GetCultureInfo("en-US");
System.Globalization.CultureInfo.CurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("en-US");

var featureCatalog = new FeatureCatalogClient();
var actionCatalog = new WorkspaceActionCatalogClient();

AssertSequence(
    "navigation feature ids",
    featureCatalog.BuildReadOnlySnapshot().Select(feature => feature.Id.ToString()),
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
AssertSequence(
    "navigation feature titles",
    featureCatalog.BuildReadOnlySnapshot().Select(feature => feature.Title),
    new[]
    {
        "Dashboard",
        "Device Discovery",
        "USB Management",
        "File Transfer",
        "Remote Desktop",
        "Quantum",
        "System Monitor",
        "Settings"
    });

AssertSequence(
    "initial action surfaces",
    actionCatalog.BuildInitialSurfaces().Select(surface => surface.ToString()),
    new[]
    {
        "SidebarSession",
        "TopBarActions",
        "SessionControls",
        "DashboardQuickActions",
        "DeviceDiscoveryPrimary",
        "DeviceDiscoveryScan",
        "DeviceDiscoveryManualConnectFinal",
        "CrossNetworkQr",
        "CrossNetworkCodePrimary",
        "CrossNetworkCodeConnect",
        "UsbManagementHeader",
        "FileTransferHeader",
        "FileTransfer",
        "RemoteDesktopHeader",
        "RemoteDesktop",
        "QuantumDiagnosticsHeader",
        "SystemMonitorHeader",
        "SystemMonitorControls",
        "SettingsHeader",
        "SettingsToolbar",
        "SettingsMaintenance"
    });
AssertSequence(
    "dynamic action surfaces",
    actionCatalog.BuildDynamicRefreshSurfaces().Select(surface => surface.ToString()),
    new[]
    {
        "SidebarSession",
        "TopBarActions",
        "SessionControls",
        "DeviceDiscoveryPrimary",
        "DeviceDiscoveryScan",
        "DeviceDiscoveryManualConnectFinal",
        "CrossNetworkQr",
        "CrossNetworkCodePrimary",
        "CrossNetworkCodeConnect",
        "UsbManagementHeader",
        "FileTransferHeader",
        "FileTransfer",
        "RemoteDesktopHeader",
        "RemoteDesktop",
        "QuantumDiagnosticsHeader",
        "SystemMonitorHeader",
        "SystemMonitorControls",
        "SettingsHeader",
        "SettingsToolbar",
        "SettingsMaintenance"
    });

AssertActionSurface(actionCatalog, WorkspaceActionSurface.SidebarSession, new[] { "Connect", "Disconnect" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.TopBarActions, new[] { "Notifications", "Theme" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.SessionControls, new[] { "Connect", "Heartbeat", "Disconnect" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.DashboardQuickActions, new[] { "ScanDevices", "FileTransfer", "SystemMonitor", "Settings" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.DeviceDiscoveryPrimary, new[] { "ParseTxt", "ValidatePairing", "PrepareConnection" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.DeviceDiscoveryScan, new[] { "ExtendedSearch", "ManualConnect", "StartScan", "StopScan", "Refresh" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal, new[] { "Cancel", "Connect" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.CrossNetworkQr, new[] { "GenerateQrCode", "ScanQrCode" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.CrossNetworkCodePrimary, new[] { "GenerateCode", "CopyCode", "RegenerateCode" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.CrossNetworkCodeConnect, new[] { "ConnectWithCode" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.UsbManagementHeader, new[] { "RefreshDevices" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.FileTransferHeader, new[] { "RefreshPlan" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.FileTransfer, new[] { "SelectFiles", "SelectFolder", "GenerateQr" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.RemoteDesktopHeader, new[] { "RefreshSessions" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.RemoteDesktop, new[] { "RecommendedConnect", "AdvancedConnect", "PerformanceOverlay", "Quality", "Settings", "FullScreen", "DisconnectSession" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.QuantumDiagnosticsHeader, new[] { "RunDiagnostics" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.SystemMonitorHeader, new[] { "RefreshMetrics" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.SystemMonitorControls, new[] { "Monitoring", "StopMonitoring", "EnableAdvancedMonitoring" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.SettingsHeader, new[] { "RefreshStatus" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.SettingsToolbar, new[] { "ExportSettings", "ImportSettings", "ResetSettings", "RequestPermission", "OpenSystemPreferences" });
AssertActionSurface(actionCatalog, WorkspaceActionSurface.SettingsMaintenance, new[] { "ApplySettings", "RestoreDefaults", "ResetMonitorData" });

Console.WriteLine("windows-ui-action-order: ok");

static void AssertActionSurface(
    WorkspaceActionCatalogClient catalog,
    WorkspaceActionSurface surface,
    IReadOnlyList<string> expectedKeys)
{
    var snapshot = catalog.BuildReadOnlySnapshot(new WorkspaceActionCatalogRequest(surface));
    AssertSequence($"{surface} action keys", snapshot.Actions.Select(action => action.Key), expectedKeys);

    foreach (var action in snapshot.Actions)
    {
        var view = WorkspaceActionItemView.FromItem(surface, action);
        AssertEqual(
            $"WorkspaceAction.{surface}.{action.Key}",
            view.AutomationId,
            $"{surface}.{action.Key} automation id");

        if (action.CommandId != WorkspaceActionCommandId.None)
        {
            AssertEqual(action.Key, view.Key, $"{surface}.{action.Key} view key");
            AssertEqual(action.Title, view.Title, $"{surface}.{action.Key} view title");
        }
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
'@

    & dotnet run --project $testProject
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "windows UI action-order smoke failed."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $resolvedTempParent = [System.IO.Path]::GetFullPath($tempParent)
        $isOwnedSmokeDir =
            [System.IO.Path]::GetFileName($resolvedTempRoot).StartsWith(
                "skybridge-win-ui-action-order-",
                [StringComparison]::Ordinal) -and
            $resolvedTempRoot.StartsWith(
                $resolvedTempParent,
                [StringComparison]::Ordinal)

        Assert-True -Condition $isOwnedSmokeDir -Message "Refusing to remove unexpected temp directory: $resolvedTempRoot"
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
