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

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    Assert-True -Condition ($Text.Contains($Needle)) -Message $Message
}

function Assert-Count {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$ExpectedCount,
        [string]$Message
    )

    $count = [regex]::Matches($Text, $Pattern).Count
    Assert-True -Condition ($count -eq $ExpectedCount) -Message "$Message Expected $ExpectedCount, got $count."
}

function Assert-Ordered {
    param(
        [string]$Text,
        [string[]]$Needles,
        [string]$Context
    )

    $lastIndex = -1
    foreach ($needle in $Needles) {
        $index = $Text.IndexOf($needle, $lastIndex + 1, [StringComparison]::Ordinal)
        Assert-True -Condition ($index -ge 0) -Message "$Context missing ordered signal after index ${lastIndex}: $needle"
        Assert-True -Condition ($index -gt $lastIndex) -Message "$Context order regression: $needle"
        $lastIndex = $index
    }
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " "
}

function Test-GitObjectExists {
    param([string]$ObjectName)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "git"
    $startInfo.Arguments = Join-ProcessArguments -Arguments @("-C", $RepoRoot, "cat-file", "-e", $ObjectName)
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    return $process.ExitCode -eq 0
}

function Get-MethodSlice {
    param(
        [string]$Text,
        [string]$MethodName
    )

    $signature = "private static IReadOnlyList<WorkspaceActionItem> $MethodName()"
    $start = $Text.IndexOf($signature, [StringComparison]::Ordinal)
    Assert-True -Condition ($start -ge 0) -Message "Missing action catalog method: $MethodName"

    $next = $Text.IndexOf("private static IReadOnlyList<WorkspaceActionItem>", $start + $signature.Length, [StringComparison]::Ordinal)
    if ($next -lt 0) {
        $next = $Text.Length
    }

    return $Text.Substring($start, $next - $start)
}

$matrixPath = Join-Path $RepoRoot "docs/windows-ui-parity-matrix.md"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml"
$featureCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FeatureCatalogClient.cs"
$actionCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs"
$actionOrderSmokePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-action-order.ps1"
$paritySmokePath = Join-Path $RepoRoot "Scripts/verify-windows-ui-parity.ps1"

foreach ($path in @($matrixPath, $mainWindowPath, $featureCatalogPath, $actionCatalogPath, $actionOrderSmokePath, $paritySmokePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing UI parity matrix input: $path"
}

$matrix = Get-Content -Raw -LiteralPath $matrixPath
$mainWindow = Get-Content -Raw -LiteralPath $mainWindowPath
$featureCatalog = Get-Content -Raw -LiteralPath $featureCatalogPath
$actionCatalog = Get-Content -Raw -LiteralPath $actionCatalogPath
$actionOrderSmoke = Get-Content -Raw -LiteralPath $actionOrderSmokePath
$paritySmoke = Get-Content -Raw -LiteralPath $paritySmokePath

$macBaselineCommit = "23ba06343bbaa58c30ef6b9bbddd09bb4e80241c"
$macBaselinePaths = @(
    "Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift",
    "Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift",
    "Sources/SkyBridgeCompassApp/Dashboard/Sections/QuickActionsPanelView.swift",
    "Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift"
)

Assert-Contains -Text $matrix -Needle "Mac baseline commit: ``$macBaselineCommit``" -Message "UI parity matrix must pin the mac baseline commit."
foreach ($macPath in $macBaselinePaths) {
    $macObject = "${macBaselineCommit}:$macPath"
    Assert-Contains -Text $matrix -Needle "``$macObject``" -Message "UI parity matrix must use immutable mac source object: $macObject"
    Assert-True -Condition (Test-GitObjectExists -ObjectName $macObject) -Message "Pinned mac source object is not available in this repository: $macObject"
}

$featureRows = @(
    [pscustomobject]@{ Order = "1"; Id = "Dashboard"; Title = "Dashboard"; Gate = "IsDashboardSelected"; Heading = 'AutomationProperties.AutomationId="Skybridge.SelectedFeature.Title"'; Surfaces = @("DashboardQuickActions"); Anchors = @("Skybridge.Navigation.List", "Skybridge.SelectedFeature.Title", "Skybridge.Actions.DashboardQuickActions") },
    [pscustomobject]@{ Order = "2"; Id = "DeviceDiscovery"; Title = "Device Discovery"; Gate = "IsDeviceDiscoverySelected"; Heading = 'Text="Device Discovery"'; Surfaces = @("DeviceDiscoveryPrimary", "DeviceDiscoveryScan", "DeviceDiscoveryManualConnectFinal", "CrossNetworkQr", "CrossNetworkCodePrimary", "CrossNetworkCodeConnect"); Anchors = @("WorkspaceAction.DeviceDiscoveryPrimary.ParseTxt", "WorkspaceAction.DeviceDiscoveryScan.ManualConnect", "Skybridge.Actions.DeviceDiscoveryManualConnectFinal") },
    [pscustomobject]@{ Order = "3"; Id = "UsbManagement"; Title = "USB Management"; Gate = "IsUsbManagementSelected"; Heading = 'Text="USB Management"'; Surfaces = @("UsbManagementHeader"); Anchors = @("WorkspaceAction.UsbManagementHeader.RefreshDevices") },
    [pscustomobject]@{ Order = "4"; Id = "FileTransfer"; Title = "File Transfer"; Gate = "IsFileTransferSelected"; Heading = 'Text="File Transfer"'; Surfaces = @("FileTransferHeader", "FileTransfer"); Anchors = @("WorkspaceAction.FileTransfer.SelectFiles", "WorkspaceAction.FileTransfer.SelectFolder", "WorkspaceAction.FileTransfer.GenerateQr") },
    [pscustomobject]@{ Order = "5"; Id = "RemoteDesktop"; Title = "Remote Desktop"; Gate = "IsRemoteDesktopSelected"; Heading = 'Text="Remote Desktop"'; Surfaces = @("RemoteDesktopHeader", "RemoteDesktop"); Anchors = @("WorkspaceAction.RemoteDesktop.RecommendedConnect", "WorkspaceAction.RemoteDesktop.AdvancedConnect", "WorkspaceAction.RemoteDesktop.DisconnectSession") },
    [pscustomobject]@{ Order = "6"; Id = "Quantum"; Title = "Quantum / Core Diagnostics"; Gate = "IsQuantumSelected"; Heading = 'Text="Quantum / Core Diagnostics"'; Surfaces = @("QuantumDiagnosticsHeader"); Anchors = @("WorkspaceAction.QuantumDiagnosticsHeader.RunDiagnostics") },
    [pscustomobject]@{ Order = "7"; Id = "SystemMonitor"; Title = "System Monitor"; Gate = "IsSystemMonitorSelected"; Heading = 'Text="System Monitor"'; Surfaces = @("SystemMonitorHeader", "SystemMonitorControls"); Anchors = @("WorkspaceAction.SystemMonitorControls.Monitoring", "WorkspaceAction.SystemMonitorControls.StopMonitoring", "WorkspaceAction.SystemMonitorControls.EnableAdvancedMonitoring") },
    [pscustomobject]@{ Order = "8"; Id = "Settings"; Title = "Settings"; Gate = "IsSettingsSelected"; Heading = 'Text="Settings"'; Surfaces = @("SettingsHeader", "SettingsToolbar", "SettingsMaintenance"); Anchors = @("WorkspaceAction.SettingsToolbar.ExportSettings", "WorkspaceAction.SettingsToolbar.OpenSystemPreferences", "WorkspaceAction.SettingsMaintenance.ApplySettings") }
)

foreach ($row in $featureRows) {
    Assert-Contains -Text $matrix -Needle "| $($row.Order) | $($row.Id) | $($row.Title) | ``$($row.Gate)`` |" -Message "UI parity matrix missing feature row: $($row.Id)"
    Assert-Contains -Text $mainWindow -Needle "Visibility=`"{Binding $($row.Gate)" -Message "MainWindow missing visibility gate: $($row.Gate)"
    Assert-Contains -Text $mainWindow -Needle $row.Heading -Message "MainWindow missing feature heading: $($row.Title)"
    Assert-Contains -Text $featureCatalog -Needle "FeatureEntryId.$($row.Id)" -Message "FeatureCatalog missing feature id: $($row.Id)"

    foreach ($surface in $row.Surfaces) {
        Assert-Contains -Text $matrix -Needle "``$surface``" -Message "UI parity matrix missing surface: $surface"
        Assert-Contains -Text $actionCatalog -Needle "WorkspaceActionSurface.$surface" -Message "WorkspaceActionCatalog missing surface: $surface"
    }

    foreach ($anchor in $row.Anchors) {
        Assert-Contains -Text $matrix -Needle "``$anchor``" -Message "UI parity matrix missing anchor: $anchor"
    }
}

Assert-Ordered -Text $featureCatalog -Context "FeatureCatalog mac navigation order" -Needles @(
    "FeatureEntryId.Dashboard",
    "FeatureEntryId.DeviceDiscovery",
    "FeatureEntryId.UsbManagement",
    "FeatureEntryId.FileTransfer",
    "FeatureEntryId.RemoteDesktop",
    "FeatureEntryId.Quantum",
    "FeatureEntryId.SystemMonitor",
    "FeatureEntryId.Settings"
)

Assert-Ordered -Text $mainWindow -Context "MainWindow selected workspace visibility order" -Needles @(
    "Visibility=`"{Binding IsDashboardSelected",
    "Visibility=`"{Binding IsDeviceDiscoverySelected",
    "Visibility=`"{Binding IsUsbManagementSelected",
    "Visibility=`"{Binding IsFileTransferSelected",
    "Visibility=`"{Binding IsRemoteDesktopSelected",
    "Visibility=`"{Binding IsQuantumSelected",
    "Visibility=`"{Binding IsSystemMonitorSelected",
    "Visibility=`"{Binding IsSettingsSelected"
)

Assert-Ordered -Text $mainWindow -Context "MainWindow global shell anchor order" -Needles @(
    'AutomationProperties.AutomationId="Skybridge.Navigation.List"',
    'ItemsSource="{Binding NavigationItems}"',
    'AutomationProperties.AutomationId="Skybridge.Actions.SidebarSession"',
    'ItemsSource="{Binding SidebarSessionActions}"',
    'AutomationProperties.AutomationId="Skybridge.SelectedFeature.Title"',
    'AutomationProperties.AutomationId="Skybridge.Status.Message"',
    'AutomationProperties.AutomationId="Skybridge.TopBar.ConnectionStatus"',
    'AutomationProperties.AutomationId="Skybridge.TopBar.DiagnosticsStatus"',
    'AutomationProperties.AutomationId="Skybridge.Actions.TopBar"',
    'ItemsSource="{Binding TopBarActions}"'
)

Assert-Ordered -Text $mainWindow -Context "MainWindow action binding order" -Needles @(
    'ItemsSource="{Binding DashboardQuickActions}"',
    'ItemsSource="{Binding DeviceDiscoveryPrimaryActions}"',
    'ItemsSource="{Binding DeviceDiscoveryScanActions}"',
    'ItemsSource="{Binding CrossNetworkQrActions}"',
    'ItemsSource="{Binding CrossNetworkCodePrimaryActions}"',
    'ItemsSource="{Binding CrossNetworkCodeConnectActions}"',
    'ItemsSource="{Binding DeviceDiscoveryManualConnectFinalActions}"',
    'ItemsSource="{Binding UsbManagementHeaderActions}"',
    'ItemsSource="{Binding FileTransferHeaderActions}"',
    'ItemsSource="{Binding FileTransferActions}"',
    'ItemsSource="{Binding RemoteDesktopHeaderActions}"',
    'ItemsSource="{Binding RemoteDesktopActions}"',
    'ItemsSource="{Binding QuantumDiagnosticsHeaderActions}"',
    'ItemsSource="{Binding SystemMonitorHeaderActions}"',
    'ItemsSource="{Binding SystemMonitorActions}"',
    'ItemsSource="{Binding SettingsHeaderActions}"',
    'ItemsSource="{Binding SettingsToolbarActions}"',
    'ItemsSource="{Binding SettingsMaintenanceActions}"',
    'ItemsSource="{Binding SessionControlActions}"'
)

foreach ($templateSignal in @(
    '<DataTemplate x:Key="SidebarWorkspaceActionButtonTemplate">',
    '<DataTemplate x:Key="WorkspaceActionButtonTemplate">',
    '<DataTemplate x:Key="WorkspaceActionButtonWithDetailTemplate">',
    '<DataTemplate x:Key="TopBarStatusActionButtonTemplate">',
    '<DataTemplate x:Key="DashboardQuickActionTemplate">',
    'AutomationProperties.AutomationId="{Binding AutomationId}"',
    'Command="{Binding Command}"'
)) {
    Assert-Contains -Text $mainWindow -Needle $templateSignal -Message "MainWindow missing shared action-template signal: $templateSignal"
}

Assert-Count -Text $mainWindow -Pattern '<Button\b' -ExpectedCount 5 -Message "MainWindow must render action buttons only through the five shared action templates."

Assert-Ordered -Text $mainWindow -Context "MainWindow shared action template usage" -Needles @(
    'ItemsSource="{Binding SidebarSessionActions}"',
    'ItemsPanel="{StaticResource VerticalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource SidebarWorkspaceActionButtonTemplate}"',
    'ItemsSource="{Binding TopBarActions}"',
    'ItemsPanel="{StaticResource HorizontalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource TopBarStatusActionButtonTemplate}"',
    'ItemsSource="{Binding DashboardQuickActions}"',
    'ItemsPanel="{StaticResource DashboardQuickActionItemsPanel}"',
    'ItemTemplate="{StaticResource DashboardQuickActionTemplate}"',
    'ItemsSource="{Binding DeviceDiscoveryPrimaryActions}"',
    'ItemsPanel="{StaticResource HorizontalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource WorkspaceActionButtonTemplate}"',
    'ItemsSource="{Binding DeviceDiscoveryManualConnectFinalActions}"',
    'ItemsPanel="{StaticResource HorizontalWorkspaceActionItemsPanel}"',
    'ItemTemplate="{StaticResource WorkspaceActionButtonWithDetailTemplate}"'
)

foreach ($styleMatrixSignal in @(
    "Shared Style And Template Matrix",
    "Mac baseline commit",
    "SidebarWorkspaceActionButtonTemplate",
    "WorkspaceActionButtonTemplate",
    "WorkspaceActionButtonWithDetailTemplate",
    "TopBarStatusActionButtonTemplate",
    "DashboardQuickActionTemplate",
    "Feature sections must not introduce inline ``Button`` controls"
)) {
    Assert-Contains -Text $matrix -Needle $styleMatrixSignal -Message "UI parity matrix doc missing style/template signal: $styleMatrixSignal"
}

Assert-Ordered -Text $actionCatalog -Context "WorkspaceActionCatalog initial surface order" -Needles @(
    "WorkspaceActionSurface.SidebarSession",
    "WorkspaceActionSurface.TopBarActions",
    "WorkspaceActionSurface.SessionControls",
    "WorkspaceActionSurface.DashboardQuickActions",
    "WorkspaceActionSurface.DeviceDiscoveryPrimary",
    "WorkspaceActionSurface.DeviceDiscoveryScan",
    "WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal",
    "WorkspaceActionSurface.CrossNetworkQr",
    "WorkspaceActionSurface.CrossNetworkCodePrimary",
    "WorkspaceActionSurface.CrossNetworkCodeConnect",
    "WorkspaceActionSurface.UsbManagementHeader",
    "WorkspaceActionSurface.FileTransferHeader",
    "WorkspaceActionSurface.FileTransfer",
    "WorkspaceActionSurface.RemoteDesktopHeader",
    "WorkspaceActionSurface.RemoteDesktop",
    "WorkspaceActionSurface.QuantumDiagnosticsHeader",
    "WorkspaceActionSurface.SystemMonitorHeader",
    "WorkspaceActionSurface.SystemMonitorControls",
    "WorkspaceActionSurface.SettingsHeader",
    "WorkspaceActionSurface.SettingsToolbar",
    "WorkspaceActionSurface.SettingsMaintenance"
)

$surfaceActions = @(
    [pscustomobject]@{ Surface = "SidebarSession"; Method = "BuildSidebarSessionActions"; Keys = @('"Connect"', '"Disconnect"') },
    [pscustomobject]@{ Surface = "TopBarActions"; Method = "BuildTopBarActions"; Keys = @('"Notifications"', '"Theme"') },
    [pscustomobject]@{ Surface = "SessionControls"; Method = "BuildSessionControlActions"; Keys = @('"Connect"', '"Heartbeat"', '"Disconnect"') },
    [pscustomobject]@{ Surface = "DashboardQuickActions"; Method = "BuildDashboardQuickActions"; Keys = @('"ScanDevices"', '"FileTransfer"', '"SystemMonitor"', '"Settings"') },
    [pscustomobject]@{ Surface = "DeviceDiscoveryPrimary"; Method = "BuildDeviceDiscoveryPrimaryActions"; Keys = @('"ParseTxt"', '"ValidatePairing"', '"PrepareConnection"') },
    [pscustomobject]@{ Surface = "DeviceDiscoveryScan"; Method = "BuildDeviceDiscoveryScanActions"; Keys = @('"ExtendedSearch"', '"ManualConnect"', '"StartScan"', '"StopScan"', '"Refresh"') },
    [pscustomobject]@{ Surface = "DeviceDiscoveryManualConnectFinal"; Method = "BuildDeviceDiscoveryManualConnectFinalActions"; Keys = @('"Connect"') },
    [pscustomobject]@{ Surface = "CrossNetworkQr"; Method = "BuildCrossNetworkQrActions"; Keys = @('"GenerateQrCode"', '"ScanQrCode"') },
    [pscustomobject]@{ Surface = "CrossNetworkCodePrimary"; Method = "BuildCrossNetworkCodePrimaryActions"; Keys = @('"GenerateCode"', '"CopyCode"', '"RegenerateCode"') },
    [pscustomobject]@{ Surface = "CrossNetworkCodeConnect"; Method = "BuildCrossNetworkCodeConnectActions"; Keys = @('"ConnectWithCode"') },
    [pscustomobject]@{ Surface = "UsbManagementHeader"; Method = "BuildUsbManagementHeaderActions"; Keys = @('"RefreshDevices"') },
    [pscustomobject]@{ Surface = "FileTransferHeader"; Method = "BuildFileTransferHeaderActions"; Keys = @('"RefreshPlan"') },
    [pscustomobject]@{ Surface = "FileTransfer"; Method = "BuildFileTransferActions"; Keys = @('"SelectFiles"', '"SelectFolder"', '"GenerateQr"') },
    [pscustomobject]@{ Surface = "RemoteDesktopHeader"; Method = "BuildRemoteDesktopHeaderActions"; Keys = @('"RefreshSessions"') },
    [pscustomobject]@{ Surface = "RemoteDesktop"; Method = "BuildRemoteDesktopActions"; Keys = @('"RecommendedConnect"', '"AdvancedConnect"', '"PerformanceOverlay"', '"Quality"', '"Settings"', '"FullScreen"', '"DisconnectSession"') },
    [pscustomobject]@{ Surface = "QuantumDiagnosticsHeader"; Method = "BuildQuantumDiagnosticsHeaderActions"; Keys = @('"RunDiagnostics"') },
    [pscustomobject]@{ Surface = "SystemMonitorHeader"; Method = "BuildSystemMonitorHeaderActions"; Keys = @('"RefreshMetrics"') },
    [pscustomobject]@{ Surface = "SystemMonitorControls"; Method = "BuildSystemMonitorControlActions"; Keys = @('"Monitoring"', '"StopMonitoring"', '"EnableAdvancedMonitoring"') },
    [pscustomobject]@{ Surface = "SettingsHeader"; Method = "BuildSettingsHeaderActions"; Keys = @('"RefreshStatus"') },
    [pscustomobject]@{ Surface = "SettingsToolbar"; Method = "BuildSettingsToolbarActions"; Keys = @('"ExportSettings"', '"ImportSettings"', '"ResetSettings"', '"RequestPermission"', '"OpenSystemPreferences"') },
    [pscustomobject]@{ Surface = "SettingsMaintenance"; Method = "BuildSettingsMaintenanceActions"; Keys = @('"ApplySettings"', '"RestoreDefaults"', '"ResetMonitorData"') }
)

foreach ($surface in $surfaceActions) {
    $slice = Get-MethodSlice -Text $actionCatalog -MethodName $surface.Method
    Assert-Ordered -Text $slice -Context "$($surface.Surface) action order" -Needles $surface.Keys
    Assert-Contains -Text $matrix -Needle "| ``$($surface.Surface)`` |" -Message "UI parity matrix missing action-order row: $($surface.Surface)"
    Assert-Contains -Text $actionOrderSmoke -Needle "WorkspaceActionSurface.$($surface.Surface)" -Message "UI action-order smoke missing surface: $($surface.Surface)"
}

foreach ($matrixSignal in @(
    "Windows UI parity matrix",
    "Fonts, rendering scale, and platform-specific pixel metrics are intentionally out of scope.",
    "Navigation And Workspace Matrix",
    "Global Shell Matrix",
    "Action Order Matrix",
    "verify-windows-ui-parity-matrix.ps1",
    "verify-windows-ui-action-order.ps1",
    "verify-windows-ui-parity.ps1"
)) {
    Assert-Contains -Text $matrix -Needle $matrixSignal -Message "UI parity matrix doc missing signal: $matrixSignal"
}

Assert-Contains -Text $paritySmoke -Needle "windows-ui-parity-matrix.md" -Message "Broad UI parity gate must know about the matrix doc."
Assert-Contains -Text $paritySmoke -Needle "verify-windows-ui-parity-matrix.ps1" -Message "Broad UI parity gate must know about the matrix smoke."

Write-Output "windows-ui-parity-matrix: ok"
