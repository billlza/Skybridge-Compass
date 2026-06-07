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

function Assert-ActionItemsControlResources {
    param(
        [string]$Text,
        [string]$Binding,
        [string]$ItemsPanel,
        [string]$ItemTemplate
    )

    $bindingPattern = [regex]::Escape("ItemsSource=`"{Binding $Binding}`"")
    $panelPattern = [regex]::Escape("ItemsPanel=`"{StaticResource $ItemsPanel}`"")
    $templatePattern = [regex]::Escape("ItemTemplate=`"{StaticResource $ItemTemplate}`"")
    $pattern = "<ItemsControl\b(?=[^>]*$bindingPattern)(?=[^>]*$panelPattern)(?=[^>]*$templatePattern)[^>]*/>"

    Assert-True -Condition ([regex]::IsMatch($Text, $pattern)) -Message "MainWindow.xaml action surface must use shared resources: $Binding"
}

function Assert-ItemsControlResources {
    param(
        [string]$Text,
        [string]$Binding,
        [string]$ItemsPanel,
        [string]$ItemTemplate
    )

    $bindingPattern = [regex]::Escape("ItemsSource=`"{Binding $Binding}`"")
    $panelPattern = [regex]::Escape("ItemsPanel=`"{StaticResource $ItemsPanel}`"")
    $templatePattern = [regex]::Escape("ItemTemplate=`"{StaticResource $ItemTemplate}`"")
    $pattern = "<ItemsControl\b(?=[^>]*$bindingPattern)(?=[^>]*$panelPattern)(?=[^>]*$templatePattern)[^>]*/>"

    Assert-True -Condition ([regex]::IsMatch($Text, $pattern)) -Message "MainWindow.xaml item source must use shared resources: $Binding"
}

function Assert-ItemsControlTemplate {
    param(
        [string]$Text,
        [string]$Binding,
        [string]$ItemTemplate
    )

    $bindingPattern = [regex]::Escape("ItemsSource=`"{Binding $Binding}`"")
    $templatePattern = [regex]::Escape("ItemTemplate=`"{StaticResource $ItemTemplate}`"")
    $pattern = "<(?:ItemsControl|ListView)\b(?=[^>]*$bindingPattern)(?=[^>]*$templatePattern)[^>]*/>"

    Assert-True -Condition ([regex]::IsMatch($Text, $pattern)) -Message "MainWindow.xaml item source must use shared template: $Binding"
}

$featureContractPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/FeatureEntryContract.cs"
$sessionViewModelPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModel.cs"
$dashboardMetricsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DashboardMetricsClient.cs"
$discoveryBrowserPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs"
$deviceDiscoveryInputDefaultsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DeviceDiscoveryInputDefaultsClient.cs"
$manualConnectionPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ManualConnectionClient.cs"
$crossNetworkPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CrossNetworkConnectionClient.cs"
$pairingPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs"
$connectionPreflightPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs"
$connectionWorkspaceStatePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionWorkspaceStateClient.cs"
$usbManagementPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/UsbManagementWorkspaceClient.cs"
$coreDiagnosticsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CoreDiagnosticsClient.cs"
$fileTransferPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
$workspaceActionCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs"
$remoteDesktopPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopWorkspaceClient.cs"
$remoteDesktopProfileCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopProfileCatalogClient.cs"
$systemMonitorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SystemMonitorWorkspaceClient.cs"
$settingsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SettingsWorkspaceClient.cs"
$topBarStatusPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/TopBarStatusClient.cs"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml"
$parityDocPath = Join-Path $RepoRoot "docs/windows-ui-parity-contract.md"

foreach ($path in @($featureContractPath, $sessionViewModelPath, $dashboardMetricsPath, $discoveryBrowserPath, $deviceDiscoveryInputDefaultsPath, $manualConnectionPath, $crossNetworkPath, $pairingPath, $connectionPreflightPath, $connectionWorkspaceStatePath, $usbManagementPath, $coreDiagnosticsPath, $fileTransferPath, $workspaceActionCatalogPath, $remoteDesktopPath, $remoteDesktopProfileCatalogPath, $systemMonitorPath, $settingsPath, $topBarStatusPath, $mainWindowPath, $parityDocPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing parity file: $path"
}

$featureContract = Get-Content -Raw -LiteralPath $featureContractPath
$sessionViewModel = Get-Content -Raw -LiteralPath $sessionViewModelPath
$dashboardMetrics = Get-Content -Raw -LiteralPath $dashboardMetricsPath
$discoveryBrowser = Get-Content -Raw -LiteralPath $discoveryBrowserPath
$deviceDiscoveryInputDefaults = Get-Content -Raw -LiteralPath $deviceDiscoveryInputDefaultsPath
$manualConnection = Get-Content -Raw -LiteralPath $manualConnectionPath
$crossNetwork = Get-Content -Raw -LiteralPath $crossNetworkPath
$pairing = Get-Content -Raw -LiteralPath $pairingPath
$connectionPreflight = Get-Content -Raw -LiteralPath $connectionPreflightPath
$connectionWorkspaceState = Get-Content -Raw -LiteralPath $connectionWorkspaceStatePath
$usbManagement = Get-Content -Raw -LiteralPath $usbManagementPath
$coreDiagnostics = Get-Content -Raw -LiteralPath $coreDiagnosticsPath
$fileTransfer = Get-Content -Raw -LiteralPath $fileTransferPath
$workspaceActionCatalog = Get-Content -Raw -LiteralPath $workspaceActionCatalogPath
$remoteDesktop = Get-Content -Raw -LiteralPath $remoteDesktopPath
$remoteDesktopProfileCatalog = Get-Content -Raw -LiteralPath $remoteDesktopProfileCatalogPath
$systemMonitor = Get-Content -Raw -LiteralPath $systemMonitorPath
$settings = Get-Content -Raw -LiteralPath $settingsPath
$topBarStatus = Get-Content -Raw -LiteralPath $topBarStatusPath
$mainWindow = Get-Content -Raw -LiteralPath $mainWindowPath
$parityDoc = Get-Content -Raw -LiteralPath $parityDocPath

$parsedXaml = [xml]$mainWindow
Assert-True -Condition ($null -ne $parsedXaml) -Message "MainWindow.xaml is not well-formed XML."

$expectedEntries = @(
    "Dashboard",
    "DeviceDiscovery",
    "UsbManagement",
    "FileTransfer",
    "RemoteDesktop",
    "Quantum",
    "SystemMonitor",
    "Settings"
)

$actualEntries = [regex]::Matches($featureContract, "new\(FeatureEntryId\.([A-Za-z]+)") |
    ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -in $expectedEntries }

Assert-True -Condition ($actualEntries.Count -eq $expectedEntries.Count) -Message "Feature entry count mismatch."
for ($index = 0; $index -lt $expectedEntries.Count; $index++) {
    Assert-True -Condition ($actualEntries[$index] -eq $expectedEntries[$index]) -Message "Feature entry order mismatch at index ${index}: expected $($expectedEntries[$index]), got $($actualEntries[$index])."
}

Assert-True -Condition (-not $featureContract.Contains(", false)")) -Message "All mac parity navigation entries must remain implemented once read-only workspaces exist."

foreach ($binding in @(
    "NavigationItems",
    "SelectedFeature",
    "ConnectionStatus",
    "StatusMessage",
    "DashboardMetrics",
    "TopBarConnectionStatus",
    "TopBarDiagnosticsStatus",
    "SidebarSessionActions",
    "TopBarActions",
    "SessionControlActions",
    "BitrateProfiles",
    "FramerateProfiles",
    "DiscoveryService",
    "DiscoverySearchText",
    "DiscoveryTxtRecord",
    "DiscoveryStatus",
    "DiscoveryBrowserStatus",
    "DiscoveryBrowserFacts",
    "IsDiscoveryCompatibilityModeEnabled",
    "ExtendedSearchCountdown",
    "ManualConnectionHost",
    "ManualConnectionPort",
    "ManualConnectionCode",
    "ManualConnectionStatus",
    "ManualConnectionFacts",
    "CrossNetworkQrInput",
    "CrossNetworkCodeInput",
    "CrossNetworkGeneratedCode",
    "CrossNetworkStatus",
    "CrossNetworkConnectionFacts",
    "DiscoveredPeers",
    "PairingConnectionCode",
    "PairingStatus",
    "PairingFacts",
    "ConnectionPreflightStatus",
    "ConnectionPreflightFacts",
    "DeviceDiscoveryPrimaryActions",
    "DeviceDiscoveryScanActions",
    "CrossNetworkQrActions",
    "CrossNetworkCodePrimaryActions",
    "CrossNetworkCodeConnectActions",
    "IsDeviceDiscoverySelected",
    "UsbManagementStatus",
    "UsbManagementHeaderActions",
    "UsbDeviceStats",
    "UsbDevices",
    "IsUsbManagementSelected",
    "FileTransferHeaderActions",
    "FileTransferActions",
    "FileTransferStatus",
    "FileTransferQueue",
    "FileTransferHistory",
    "FileTransferSecurityFacts",
    "IsFileTransferSelected",
    "RemoteDesktopHeaderActions",
    "RemoteDesktopActions",
    "RemoteDesktopStatus",
    "RemoteDesktopSessions",
    "RemoteDesktopControlFacts",
    "IsRemoteDesktopSelected",
    "SystemMonitorStatus",
    "SystemMonitorHeaderActions",
    "SystemMonitorActions",
    "SystemMonitorOverview",
    "SystemMonitorDetails",
    "SystemMonitorIndicators",
    "IsSystemMonitorSelected",
    "SettingsStatus",
    "SettingsHeaderActions",
    "SettingsTabs",
    "SettingsActions",
    "SettingsToolbarActions",
    "SettingsMaintenanceActions",
    "SettingsDetails",
    "IsSettingsSelected",
    "CoreDiagnosticsStatus",
    "QuantumDiagnosticsHeaderActions",
    "CoreDiagnosticFacts",
    "IsQuantumSelected"
)) {
    Assert-Contains -Text $mainWindow -Needle $binding -Message "MainWindow.xaml missing binding: $binding"
    Assert-Contains -Text $sessionViewModel -Needle $binding -Message "SessionViewModel.cs missing property or source: $binding"
}

foreach ($dashboardScalar in @(
    "OnlineDeviceCount",
    "ActiveSessionCount",
    "TransferTaskCount",
    "PerformanceStatus"
)) {
    Assert-Contains -Text ($sessionViewModel + $dashboardMetrics) -Needle $dashboardScalar -Message "Dashboard scalar status signal missing: $dashboardScalar"
}

foreach ($command in @("RefreshUsbManagementCommand", "RefreshFileTransferCommand", "RefreshRemoteDesktopCommand", "RefreshSettingsCommand", "RunCoreDiagnosticsCommand")) {
    Assert-Contains -Text $sessionViewModel -Needle $command -Message "SessionViewModel.cs missing command: $command"
}

foreach ($command in @("ConnectCommand", "HeartbeatCommand", "DisconnectCommand", "StartDiscoveryCommand", "StopDiscoveryCommand", "RefreshDiscoveryCommand", "RunExtendedDiscoveryCommand", "PrepareManualConnectionCommand", "GenerateQRCodeCommand", "ScanQRCodeCommand", "GenerateConnectionCodeCommand", "RegenerateConnectionCodeCommand", "CopyConnectionCodeCommand", "ConnectConnectionCodeCommand", "ParseAdvertisementCommand", "ValidatePairingCodeCommand", "PrepareConnectionCommand", "RefreshUsbManagementCommand", "RefreshFileTransferCommand", "RefreshRemoteDesktopCommand", "RunCoreDiagnosticsCommand", "RefreshSystemMonitorCommand", "RefreshSettingsCommand")) {
    Assert-Contains -Text $sessionViewModel -Needle $command -Message "SessionViewModel.cs missing catalog-mapped command: $command"
}

foreach ($migratedCommand in @("ConnectCommand", "HeartbeatCommand", "DisconnectCommand", "StartDiscoveryCommand", "StopDiscoveryCommand", "RefreshDiscoveryCommand", "RunExtendedDiscoveryCommand", "PrepareManualConnectionCommand", "GenerateQRCodeCommand", "ScanQRCodeCommand", "GenerateConnectionCodeCommand", "RegenerateConnectionCodeCommand", "CopyConnectionCodeCommand", "ConnectConnectionCodeCommand", "ParseAdvertisementCommand", "ValidatePairingCodeCommand", "PrepareConnectionCommand", "RefreshUsbManagementCommand", "RefreshFileTransferCommand", "RefreshRemoteDesktopCommand", "RunCoreDiagnosticsCommand", "RefreshSystemMonitorCommand", "RefreshSettingsCommand")) {
    Assert-True -Condition (-not $mainWindow.Contains("Command=`"{Binding $migratedCommand}`"")) -Message "MainWindow.xaml still hardcodes migrated action command: $migratedCommand"
}

foreach ($resourceSignal in @(
    'x:Key="VerticalWorkspaceActionItemsPanel"',
    'x:Key="HorizontalWorkspaceActionItemsPanel"',
    'x:Key="SessionWorkspaceActionItemsPanel"',
    'x:Key="NavigationItemTemplate"',
    'x:Key="SidebarWorkspaceActionButtonTemplate"',
    'x:Key="WorkspaceActionButtonTemplate"',
    'x:Key="WorkspaceActionButtonWithDetailTemplate"',
    'x:Key="WorkspaceMetricCardItemsPanel"',
    'x:Key="WorkspaceMetricCardTemplate"',
    'x:Key="WorkspaceFactRowTemplate"',
    'x:Key="DiscoveredPeerItemTemplate"',
    'x:Key="UsbDeviceItemTemplate"',
    'x:Key="FileTransferQueueItemTemplate"',
    'x:Key="FileTransferHistoryItemTemplate"',
    'x:Key="RemoteDesktopSessionItemTemplate"',
    'x:Key="WorkspaceStateRowTemplate"',
    'x:Key="SettingsDetailRowTemplate"',
    'x:Key="SettingsActionRowTemplate"',
    'x:Key="SettingsTabItemTemplate"',
    'Command="{Binding Command}"',
    'IsEnabled="{Binding IsEnabled}"',
    'Text="{Binding Detail}"',
    '<ColumnDefinition Width="170" />',
    '<ColumnDefinition Width="220" />'
)) {
    Assert-Contains -Text $mainWindow -Needle $resourceSignal -Message "MainWindow.xaml missing shared action resource signal: $resourceSignal"
}

Assert-ActionItemsControlResources -Text $mainWindow -Binding "SidebarSessionActions" -ItemsPanel "VerticalWorkspaceActionItemsPanel" -ItemTemplate "SidebarWorkspaceActionButtonTemplate"
Assert-ActionItemsControlResources -Text $mainWindow -Binding "TopBarActions" -ItemsPanel "HorizontalWorkspaceActionItemsPanel" -ItemTemplate "WorkspaceActionButtonWithDetailTemplate"

Assert-ItemsControlTemplate -Text $mainWindow -Binding "NavigationItems" -ItemTemplate "NavigationItemTemplate"
Assert-ItemsControlResources -Text $mainWindow -Binding "DashboardMetrics" -ItemsPanel "WorkspaceMetricCardItemsPanel" -ItemTemplate "WorkspaceMetricCardTemplate"
Assert-ItemsControlResources -Text $mainWindow -Binding "UsbDeviceStats" -ItemsPanel "WorkspaceMetricCardItemsPanel" -ItemTemplate "WorkspaceMetricCardTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "DiscoveredPeers" -ItemTemplate "DiscoveredPeerItemTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "UsbDevices" -ItemTemplate "UsbDeviceItemTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "FileTransferQueue" -ItemTemplate "FileTransferQueueItemTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "FileTransferHistory" -ItemTemplate "FileTransferHistoryItemTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "RemoteDesktopSessions" -ItemTemplate "RemoteDesktopSessionItemTemplate"
Assert-True -Condition (-not $mainWindow.Contains("<ListView.ItemTemplate>")) -Message "MainWindow.xaml must not use inline ListView item templates; add a named Window.Resources template instead."

foreach ($actionBinding in @(
    "DeviceDiscoveryPrimaryActions",
    "DeviceDiscoveryScanActions",
    "CrossNetworkQrActions",
    "CrossNetworkCodePrimaryActions",
    "CrossNetworkCodeConnectActions",
    "UsbManagementHeaderActions",
    "FileTransferHeaderActions",
    "FileTransferActions",
    "RemoteDesktopHeaderActions",
    "RemoteDesktopActions",
    "QuantumDiagnosticsHeaderActions",
    "SystemMonitorHeaderActions",
    "SystemMonitorActions",
    "SettingsHeaderActions",
    "SettingsToolbarActions",
    "SettingsMaintenanceActions"
)) {
    Assert-ActionItemsControlResources -Text $mainWindow -Binding $actionBinding -ItemsPanel "HorizontalWorkspaceActionItemsPanel" -ItemTemplate "WorkspaceActionButtonTemplate"
}

Assert-ActionItemsControlResources -Text $mainWindow -Binding "SessionControlActions" -ItemsPanel "SessionWorkspaceActionItemsPanel" -ItemTemplate "WorkspaceActionButtonTemplate"

foreach ($factBinding in @(
    "DiscoveryBrowserFacts",
    "ManualConnectionFacts",
    "CrossNetworkConnectionFacts",
    "PairingFacts",
    "ConnectionPreflightFacts",
    "FileTransferSecurityFacts",
    "RemoteDesktopControlFacts",
    "CoreDiagnosticFacts",
    "SystemMonitorOverview",
    "SystemMonitorDetails"
)) {
    Assert-ItemsControlTemplate -Text $mainWindow -Binding $factBinding -ItemTemplate "WorkspaceFactRowTemplate"
}

Assert-ItemsControlTemplate -Text $mainWindow -Binding "SystemMonitorIndicators" -ItemTemplate "WorkspaceStateRowTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "SettingsTabs" -ItemTemplate "SettingsTabItemTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "SettingsDetails" -ItemTemplate "SettingsDetailRowTemplate"
Assert-ItemsControlTemplate -Text $mainWindow -Binding "SettingsActions" -ItemTemplate "SettingsActionRowTemplate"

foreach ($layoutSignal in @(
    "<ColumnDefinition Width=`"252`" />",
    "<RowDefinition Height=`"72`" />",
    "ItemsSource=`"{Binding NavigationItems}`"",
    "SelectedItem=`"{Binding SelectedFeature, Mode=TwoWay}`""
)) {
    Assert-Contains -Text $mainWindow -Needle $layoutSignal -Message "MainWindow.xaml missing shell layout signal: $layoutSignal"
}

Assert-Ordered -Text $mainWindow -Context "Main workspace feature section order" -Needles @(
    '<TextBlock Text="Device Discovery"',
    '<TextBlock Text="USB Management"',
    '<TextBlock Text="File Transfer"',
    '<TextBlock Text="Remote Desktop"',
    '<TextBlock Text="Quantum / Core Diagnostics"',
    '<TextBlock Text="System Monitor"',
    '<TextBlock Text="Settings"',
    '<TextBlock Text="Session Controls"'
)

Assert-Ordered -Text $mainWindow -Context "Top bar parity action order" -Needles @(
    '<TextBlock Text="{Binding SelectedFeature.Title}"',
    '<TextBlock Text="{Binding StatusMessage}"',
    '<TextBlock Text="{Binding TopBarConnectionStatus}" FontWeight="SemiBold"',
    '<TextBlock Text="FPS / Diagnostics"',
    '<TextBlock Text="{Binding TopBarDiagnosticsStatus}" FontWeight="SemiBold"',
    'ItemsSource="{Binding TopBarActions}"'
)

Assert-Ordered -Text $mainWindow -Context "Sidebar session action order" -Needles @(
    'ItemsSource="{Binding NavigationItems}"',
    'ItemsSource="{Binding SidebarSessionActions}"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Sidebar session action catalog order" -Needles @(
    'BuildSidebarSessionActions',
    '"Connect"',
    '"Connect"',
    '"Disconnect"',
    '"Disconnect"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Top bar action catalog order" -Needles @(
    'BuildTopBarActions',
    '"Notifications"',
    '"Notifications"',
    '"Theme"',
    '"Theme"',
    '"Heartbeat"',
    '"Heartbeat"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Session controls action catalog order" -Needles @(
    'BuildSessionControlActions',
    '"Connect"',
    '"Connect"',
    '"Heartbeat"',
    '"Heartbeat"',
    '"Disconnect"',
    '"Disconnect"'
)

Assert-Ordered -Text $mainWindow -Context "Session controls action order" -Needles @(
    '<TextBlock Text="{Binding SelectedFeature.Title}" FontSize="18"',
    'ItemsSource="{Binding SessionControlActions}"',
    '<TextBlock Text="Session Controls"'
)

Assert-Ordered -Text $dashboardMetrics -Context "Dashboard metrics service order" -Needles @(
    '"Online Devices"',
    '"Active Sessions"',
    '"Transfer Tasks"',
    '"Performance"'
)

foreach ($dashboardSignal in @(
    "public interface IDashboardMetricsClient",
    "public sealed class DashboardMetricsClient : IDashboardMetricsClient",
    "BuildReadOnlySnapshot",
    "DashboardMetricsRequest",
    "DashboardMetricsSnapshot",
    "DashboardMetric",
    "DashboardMetricView",
    "DashboardMetricCount",
    "DashboardMetrics",
    "OnlineDeviceCount",
    "ActiveSessionCount",
    "TransferTaskCount",
    "PerformanceStatus",
    "new DashboardMetricsClient()",
    "Core engine connected peer count placeholder",
    "renderer and ETW telemetry providers"
)) {
    Assert-Contains -Text ($dashboardMetrics + $sessionViewModel + $mainWindow) -Needle $dashboardSignal -Message "Dashboard metrics parity signal missing: $dashboardSignal"
}

Assert-Ordered -Text $topBarStatus -Context "Top bar service parity order" -Needles @(
    '"Connection"',
    '"FPS / Diagnostics"',
    '"Notifications"',
    '"Theme"'
)

foreach ($topBarSignal in @(
    "public interface ITopBarStatusClient",
    "public sealed class TopBarStatusClient : ITopBarStatusClient",
    "BuildReadOnlySnapshot",
    "TopBarStatusRequest",
    "TopBarStatusSnapshot",
    "TopBarStatusItem",
    "TopBarStatusSlot",
    "TopBarStatusSlot.Connection",
    "TopBarStatusSlot.Diagnostics",
    "TopBarStatusSlot.Notifications",
    "TopBarStatusSlot.Theme",
    "TopBarConnectionStatus",
    "TopBarDiagnosticsStatus",
    "TopBarNotificationsStatus",
    "TopBarThemeStatus",
    "SidebarSessionActions",
    "TopBarActions",
    "SessionControlActions",
    "WorkspaceActionSurface.SidebarSession",
    "WorkspaceActionSurface.TopBarActions",
    "WorkspaceActionSurface.SessionControls",
    "WorkspaceActionCommandId",
    "WorkspaceActionGateId",
    "WorkspaceActionDetailSlot",
    "ResolveWorkspaceActionCommand",
    "ResolveWorkspaceActionEnabled",
    "new TopBarStatusClient()",
    "WorkspaceActionCatalogClient",
    "Visible mac-parity notification entry point",
    "Visible mac-parity theme entry point"
)) {
    Assert-Contains -Text ($topBarStatus + $sessionViewModel + $mainWindow + $workspaceActionCatalog) -Needle $topBarSignal -Message "Top bar parity signal missing: $topBarSignal"
}

foreach ($workspaceActionRoleSignal in @(
    "WorkspaceActionCommandId.Connect",
    "WorkspaceActionCommandId.Heartbeat",
    "WorkspaceActionCommandId.ParseTxt",
    "WorkspaceActionCommandId.RefreshSettings",
    "WorkspaceActionGateId.CanConnect",
    "WorkspaceActionGateId.CanRefreshSettings",
    "WorkspaceActionDetailSlot.TopBarNotifications",
    "WorkspaceActionDetailSlot.TopBarTheme"
)) {
    Assert-Contains -Text ($workspaceActionCatalog + $sessionViewModel) -Needle $workspaceActionRoleSignal -Message "Workspace action role signal missing: $workspaceActionRoleSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("string actionKey")) -Message "SessionViewModel must resolve workspace actions by catalog role ids, not action-key strings."
Assert-True -Condition (-not $sessionViewModel.Contains("ResolveWorkspaceActionCommand(surface")) -Message "SessionViewModel must not pass surface/key pairs to action command resolution."

foreach ($topBarLabelLookup in @(
    'GetTopBarStatusValue(snapshot, "Connection"',
    'GetTopBarStatusValue(snapshot, "FPS / Diagnostics"',
    'GetTopBarStatusValue(snapshot, "Notifications"',
    'GetTopBarStatusValue(snapshot, "Theme"'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($topBarLabelLookup)) -Message "SessionViewModel must map top-bar scalar status by TopBarStatusSlot instead of display label: $topBarLabelLookup"
}

foreach ($connectionStateSignal in @(
    "public interface IConnectionWorkspaceStateClient",
    "public sealed class ConnectionWorkspaceStateClient : IConnectionWorkspaceStateClient",
    "BuildInputResetPatch",
    "BuildErrorPatch",
    "BuildDiscoveryBrowserResultPatch",
    "BuildManualTargetPreparedPatch",
    "BuildCrossNetworkPreparedPatch",
    "BuildDiscoveryPeerValidatedPatch",
    "BuildPairingValidatedPatch",
    "BuildPreflightReadiness",
    "BuildPreflightPreparedPatch",
    "ConnectionWorkspaceResetReason",
    "ConnectionWorkspaceStatusPatch",
    "ConnectionWorkspacePreflightReadiness",
    "DiscoveryInputChanged",
    "ManualTargetInputChanged",
    "CrossNetworkInputChanged",
    "PairingInputChanged",
    "PreflightCleared",
    "Parse a Core-validated discovery TXT record before connection preflight.",
    "Validate pairing material before connection preflight.",
    "new ConnectionWorkspaceStateClient()"
)) {
    Assert-Contains -Text ($connectionWorkspaceState + $sessionViewModel + $mainWindow) -Needle $connectionStateSignal -Message "Connection workspace state signal missing: $connectionStateSignal"
}

foreach ($deviceDiscoveryDefaultSignal in @(
    "public interface IDeviceDiscoveryInputDefaultsClient",
    "public sealed class DeviceDiscoveryInputDefaultsClient : IDeviceDiscoveryInputDefaultsClient",
    "DeviceDiscoveryInputDefaultsSnapshot",
    "BuildReadOnlySnapshot",
    "DiscoveryService",
    "ManualConnectionPort",
    "DiscoveryTxtRecord",
    "PairingConnectionCode",
    "_skybridge._udp",
    "11550",
    "deviceId=mac-1",
    "Desk Mac",
    "skybridge-pair:v1",
    "SampleFingerprint",
    "SamplePairingPublicKey",
    "new DeviceDiscoveryInputDefaultsClient()"
)) {
    Assert-Contains -Text ($deviceDiscoveryInputDefaults + $sessionViewModel) -Needle $deviceDiscoveryDefaultSignal -Message "Device Discovery default-input signal missing: $deviceDiscoveryDefaultSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("SampleFingerprint")) -Message "SessionViewModel must not own Device Discovery sample fingerprints."
Assert-True -Condition (-not $sessionViewModel.Contains("SamplePairingPublicKey")) -Message "SessionViewModel must not own Device Discovery sample pairing keys."

foreach ($crossNetworkInputPolicySignal in @(
    "BuildCodeInputPolicy",
    "CrossNetworkCodeInputPolicy",
    "DefaultCodeInputPolicy",
    "CodeLength",
    "Alphabet",
    "_crossNetworkCodeInputPolicy",
    "NormalizeCrossNetworkCodeInput(value, _crossNetworkCodeInputPolicy)"
)) {
    Assert-Contains -Text ($crossNetwork + $sessionViewModel) -Needle $crossNetworkInputPolicySignal -Message "Cross-network input policy signal missing: $crossNetworkInputPolicySignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("CrossNetworkCodeAlphabet")) -Message "SessionViewModel must not duplicate the Smart Connection Code alphabet."

Assert-Ordered -Text $mainWindow -Context "Device Discovery action order" -Needles @(
    '<TextBlock Text="Device Discovery"',
    'ItemsSource="{Binding DeviceDiscoveryPrimaryActions}"',
    'Content="Compatibility Mode"',
    'ItemsSource="{Binding DeviceDiscoveryScanActions}"',
    'PlaceholderText="Search devices"',
    '<TextBlock Text="Manual Host / IP"',
    '<TextBlock Text="Port"',
    '<TextBlock Text="Code"',
    '<TextBlock Text="Dynamic Encrypted QR Code"',
    'ItemsSource="{Binding CrossNetworkQrActions}"',
    '<TextBlock Text="Smart Connection Code"',
    'ItemsSource="{Binding CrossNetworkCodePrimaryActions}"',
    'Text="{Binding CrossNetworkCodeInput',
    'ItemsSource="{Binding CrossNetworkCodeConnectActions}"',
    '<TextBlock Text="Service"',
    '<TextBlock Text="TXT record"',
    '<TextBlock Text="Pairing Code"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Device Discovery primary action catalog order" -Needles @(
    '"ParseTxt"',
    '"Parse TXT"',
    '"ValidatePairing"',
    '"Validate Pairing"',
    '"PrepareConnection"',
    '"Prepare Connection"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Device Discovery scan action catalog order" -Needles @(
    '"ExtendedSearch"',
    '"Extended Search"',
    '"ManualConnect"',
    '"Manual Connect"',
    '"StartScan"',
    '"Start Scan"',
    '"StopScan"',
    '"Stop Scan"',
    '"Refresh"',
    '"Refresh"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Cross-network QR action catalog order" -Needles @(
    '"GenerateQrCode"',
    '"Generate QR Code"',
    '"ScanQrCode"',
    '"Scan QR Code"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Cross-network smart-code action catalog order" -Needles @(
    '"GenerateCode"',
    '"Generate Code"',
    '"CopyCode"',
    '"Copy"',
    '"RegenerateCode"',
    '"Regenerate"',
    '"ConnectWithCode"',
    '"Connect"'
)

Assert-Ordered -Text $mainWindow -Context "USB Management action order" -Needles @(
    '<TextBlock Text="USB Management"',
    'ItemsSource="{Binding UsbManagementHeaderActions}"',
    'ItemsSource="{Binding UsbDeviceStats}"',
    'ItemsSource="{Binding UsbDevices}"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "USB Management header action catalog order" -Needles @(
    'BuildUsbManagementHeaderActions',
    '"RefreshDevices"',
    '"Refresh Devices"'
)

Assert-Ordered -Text $mainWindow -Context "File Transfer action order" -Needles @(
    '<TextBlock Text="File Transfer"',
    'ItemsSource="{Binding FileTransferHeaderActions}"',
    'ItemsSource="{Binding FileTransferActions}"',
    '<TextBlock Text="Transfer Queue"',
    '<TextBlock Text="Transfer History"',
    '<TextBlock Text="File Transfer Security"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "File Transfer header action catalog order" -Needles @(
    'BuildFileTransferHeaderActions',
    '"RefreshPlan"',
    '"Refresh Plan"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "File Transfer action catalog order" -Needles @(
    '"SelectFiles"',
    '"Select Files"',
    '"SelectFolder"',
    '"Select Folder"',
    '"GenerateQr"',
    '"Generate QR"'
)

Assert-Ordered -Text $mainWindow -Context "Remote Desktop action order" -Needles @(
    '<TextBlock Text="Remote Desktop"',
    'ItemsSource="{Binding RemoteDesktopHeaderActions}"',
    'ItemsSource="{Binding RemoteDesktopActions}"',
    '<TextBlock Text="Active Sessions"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Remote Desktop header action catalog order" -Needles @(
    'BuildRemoteDesktopHeaderActions',
    '"RefreshSessions"',
    '"Refresh Sessions"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Remote Desktop action catalog order" -Needles @(
    '"RecommendedConnect"',
    '"Recommended Connect"',
    '"AdvancedConnect"',
    '"Advanced Connect"',
    '"PerformanceOverlay"',
    '"Performance Overlay"',
    '"Quality"',
    '"Settings"',
    '"FullScreen"',
    '"Full Screen"',
    '"DisconnectSession"',
    '"Disconnect Session"'
)

Assert-Ordered -Text $remoteDesktopProfileCatalog -Context "Remote Desktop profile catalog order" -Needles @(
    '"Low"',
    '"Medium"',
    '"High"',
    '"Fps30"',
    '"Fps60"'
)

foreach ($profileCatalogSignal in @(
    "public interface IRemoteDesktopProfileCatalogClient",
    "public sealed class RemoteDesktopProfileCatalogClient : IRemoteDesktopProfileCatalogClient",
    "RemoteDesktopProfileCatalogSnapshot",
    "BuildReadOnlySnapshot",
    "DefaultBitrateProfile",
    "DefaultFramerateProfile",
    "new RemoteDesktopProfileCatalogClient()"
)) {
    Assert-Contains -Text ($remoteDesktopProfileCatalog + $sessionViewModel + $mainWindow) -Needle $profileCatalogSignal -Message "Remote Desktop profile catalog signal missing: $profileCatalogSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("Enum.GetValues")) -Message "SessionViewModel must not build Remote Desktop profile lists from local enum reflection."

Assert-Ordered -Text $mainWindow -Context "Quantum diagnostics action order" -Needles @(
    '<TextBlock Text="Quantum / Core Diagnostics"',
    'ItemsSource="{Binding QuantumDiagnosticsHeaderActions}"',
    'ItemsSource="{Binding CoreDiagnosticFacts}"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Quantum diagnostics header action catalog order" -Needles @(
    'BuildQuantumDiagnosticsHeaderActions',
    '"RunDiagnostics"',
    '"Run Diagnostics"'
)

Assert-Ordered -Text $mainWindow -Context "Settings action order" -Needles @(
    '<TextBlock Text="Settings" FontSize="18"',
    'ItemsSource="{Binding SettingsHeaderActions}"',
    'ItemsSource="{Binding SettingsToolbarActions}"',
    '<TextBlock Text="Settings Tabs"',
    '<TextBlock Text="Settings Details"',
    '<TextBlock Text="Settings Actions"',
    'ItemsSource="{Binding SettingsMaintenanceActions}"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Settings header action catalog order" -Needles @(
    'BuildSettingsHeaderActions',
    '"RefreshStatus"',
    '"Refresh Status"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Settings toolbar action catalog order" -Needles @(
    '"ExportSettings"',
    '"Export"',
    '"ImportSettings"',
    '"Import"',
    '"ResetSettings"',
    '"Reset"',
    '"RequestPermission"',
    '"Request Permission"',
    '"OpenSystemPreferences"',
    '"Open System Preferences"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "Settings maintenance action catalog order" -Needles @(
    '"ApplySettings"',
    '"Apply Settings"',
    '"RestoreDefaults"',
    '"Restore Defaults"',
    '"ResetMonitorData"',
    '"Reset Monitor Data"'
)

foreach ($discoverySignal in @(
    "Device Discovery",
    "_skybridge._udp",
    "_skybridge._tcp",
    "pubKeyFP",
    "Core TXT parse",
    "Start Scan",
    "Stop Scan",
    "Refresh",
    "Extended Search",
    "Compatibility Mode",
    "Search devices",
    "DiscoveryBrowserFactView",
    "WindowsDiscoveryBrowserClient",
    "DeviceDiscoveryInputDefaultsClient",
    "DnsServiceBrowse",
    "Manual Host / IP",
    "Port",
    "11550",
    "Code",
    "Manual Connect",
    "ManualConnectionClient",
    "ManualConnectionFactView",
    "Manual connection port must be between 1 and 65535",
    "no connection started",
    "Dynamic Encrypted QR Code",
    "Generate QR Code",
    "Scan QR Code",
    "QR URI",
    "skybridge://connect/",
    "skybridge://connect?data=",
    "SignedQRPayload",
    "DynamicQRCodeData",
    "QRCodeSignatureEnvelope",
    "QRCodeSignatureQuery",
    "sessionID",
    "deviceFingerprint",
    "signingPublicKey",
    "signatureTimestamp",
    "expiresAt",
    "QR signature verified",
    "QR payload validated",
    "P256 raw signature verified",
    "P256 canonical signature verified",
    "pending canonical verifier",
    "Scan Error",
    "Smart Connection Code",
    "CrossNetworkCodeInputPolicy",
    "Generate Code",
    "Copy",
    "Regenerate",
    "Connect",
    "Waiting for connection...",
    "ABCDEFGHJKLMNPQRSTUVWXYZ23456789",
    "6-digit code, valid for 10 mins, for remote assistance",
    "CrossNetworkConnectionClient",
    "CrossNetworkConnectionFactView",
    "CrossNetworkReadiness",
    "no WebRTC offerer started",
    "no WebRTC answerer started",
    "no signaling room registered",
    "DiscoveredPeerView",
    "Pairing Code",
    "Validate Pairing",
    "Prepare Connection",
    "DeviceDiscoveryPrimaryActions",
    "DeviceDiscoveryScanActions",
    "CrossNetworkQrActions",
    "CrossNetworkCodePrimaryActions",
    "CrossNetworkCodeConnectActions",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionItemView",
    "WorkspaceActionSurface.DeviceDiscoveryPrimary",
    "WorkspaceActionSurface.DeviceDiscoveryScan",
    "WorkspaceActionSurface.CrossNetworkQr",
    "WorkspaceActionSurface.CrossNetworkCodePrimary",
    "WorkspaceActionSurface.CrossNetworkCodeConnect",
    "PairingFactView",
    "PairingMaterialSnapshot",
    "PairingFact",
    "ConnectionPreflightFactView",
    "ConnectionWorkspaceStateClient",
    "PairingMaterialClient",
    "ConnectionPreflightClient",
    "skybridge-pair:v1",
    "IPeerPublicKeyProvider",
    "PublicKeyFingerprint",
    "fingerprint only; pairing must provide the peer public key",
    "Discovery pubKeyFP is verification input only",
    "Pairing code public key does not match pubKeyFP",
    "Peer key provider",
    "BuildReadOnlySnapshotAsync",
    "BuildPreflightReadiness",
    "PlanConnectionAsync",
    "ComputeTransportBindingDigestAsync",
    "Transport binding digest",
    "No connection attempt is started"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $discoveryBrowser + $deviceDiscoveryInputDefaults + $manualConnection + $crossNetwork + $pairing + $connectionPreflight + $connectionWorkspaceState + $workspaceActionCatalog) -Needle $discoverySignal -Message "Device Discovery parity signal missing: $discoverySignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("PairingFacts.Add(new PairingFactView")) -Message "SessionViewModel must map pairing facts from PairingMaterialClient instead of constructing pairing/trust facts inline."

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.DeviceDiscovery, "Device Discovery", "\uE8B9", "Core TXT parse", true)' -Message "Device Discovery must be marked implemented once the Core-validated parser panel exists."

foreach ($usbSignal in @(
    "USB Management",
    "Refresh Devices",
    "UsbManagementHeaderActions",
    "WorkspaceActionSurface.UsbManagementHeader",
    "RefreshDevices",
    "MFi Certified",
    "Android Devices",
    "Storage Devices",
    "Total Devices",
    "Connected Devices",
    "Device ID",
    "Vendor / Product",
    "SerialNumber",
    "ConnectionInterface",
    "Capabilities",
    "No USB devices detected",
    "UsbManagementWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "DriveInfo.GetDrives",
    "provider pending"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $usbManagement + $workspaceActionCatalog) -Needle $usbSignal -Message "USB Management parity signal missing: $usbSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.UsbManagement, "USB Management", "\uE88E", "Device routing", true)' -Message "USB Management must be marked implemented once the read-only device workspace exists."

foreach ($fileTransferSignal in @(
    "File Transfer",
    "Refresh Plan",
    "FileTransferHeaderActions",
    "Select Files",
    "Select Folder",
    "Generate QR",
    "FileTransferActions",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionItemView",
    "WorkspaceActionSurface.FileTransferHeader",
    "WorkspaceActionSurface.FileTransfer",
    "RefreshPlan",
    "Transfer Queue",
    "Transfer History",
    "HMAC",
    "Signature",
    "FileTransferWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "MapChannelAsync",
    "EncodeFrameAsync"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $fileTransfer + $workspaceActionCatalog) -Needle $fileTransferSignal -Message "File Transfer parity signal missing: $fileTransferSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.FileTransfer, "File Transfer", "\uE8E5", "Queue and history", true)' -Message "File Transfer must be marked implemented once the queue/history workspace exists."

foreach ($remoteDesktopSignal in @(
    "Remote Desktop",
    "Refresh Sessions",
    "RemoteDesktopHeaderActions",
    "Recommended Connect",
    "Advanced Connect",
    "Performance Overlay",
    "Quality",
    "Full Screen",
    "Disconnect Session",
    "RemoteDesktopActions",
    "RemoteDesktopProfileCatalogClient",
    "WorkspaceActionSurface.RemoteDesktopHeader",
    "WorkspaceActionSurface.RemoteDesktop",
    "RefreshSessions",
    "Active Sessions",
    "RemoteDesktopWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "PlanConnectionAsync",
    "CoreChannelKind.Realtime",
    "CoreChannelKind.Telemetry",
    "EncodeSbp2FrameAsync",
    "BitrateProfiles",
    "FramerateProfiles"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $remoteDesktop + $remoteDesktopProfileCatalog + $workspaceActionCatalog) -Needle $remoteDesktopSignal -Message "Remote Desktop parity signal missing: $remoteDesktopSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.RemoteDesktop, "Remote Desktop", "\uE7F4", "Sessions", true)' -Message "Remote Desktop must be marked implemented once the read-only session workspace exists."

foreach ($diagnosticSignal in @(
    "Quantum / Core Diagnostics",
    "Run Diagnostics",
    "QuantumDiagnosticsHeaderActions",
    "WorkspaceActionSurface.QuantumDiagnosticsHeader",
    "RunDiagnostics",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionItemView",
    "CoreDiagnosticFactView",
    "CoreDiagnosticsClient",
    "BuildInteropSnapshotAsync",
    "ComputeTransportBindingDigestAsync",
    "Transport binding digest",
    "diagnostic-only binding material",
    "EncodeSbp2FrameAsync",
    "DecodeFrameMetadataAsync"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $coreDiagnostics + $workspaceActionCatalog) -Needle $diagnosticSignal -Message "Quantum diagnostics parity signal missing: $diagnosticSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.Quantum, "Quantum", "\uE72E", "Core diagnostics", true)' -Message "Quantum must be marked implemented once the Core diagnostics panel exists."

Assert-Ordered -Text $mainWindow -Context "System Monitor action order" -Needles @(
    '<TextBlock Text="System Monitor" FontSize="18"',
    'ItemsSource="{Binding SystemMonitorHeaderActions}"',
    'ItemsSource="{Binding SystemMonitorActions}"',
    '<TextBlock Text="Overview"',
    '<TextBlock Text="Indicators"',
    '<TextBlock Text="Detailed Monitoring"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "System Monitor header action catalog order" -Needles @(
    'BuildSystemMonitorHeaderActions',
    '"RefreshMetrics"',
    '"Refresh Metrics"'
)

Assert-Ordered -Text $workspaceActionCatalog -Context "System Monitor control action catalog order" -Needles @(
    'BuildSystemMonitorControlActions',
    '"Monitoring"',
    '"Monitoring"',
    '"StopMonitoring"',
    '"Stop Monitoring"',
    '"EnableAdvancedMonitoring"',
    '"Enable Advanced Monitoring"'
)

foreach ($systemMonitorSignal in @(
    "System Monitor",
    "Refresh Metrics",
    "Monitoring",
    "Stop Monitoring",
    "Enable Advanced Monitoring",
    "SystemMonitorHeaderActions",
    "SystemMonitorActions",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionItemView",
    "WorkspaceActionSurface.SystemMonitorHeader",
    "WorkspaceActionSurface.SystemMonitorControls",
    "Overview",
    "Indicators",
    "Detailed Monitoring",
    "CPU",
    "Memory",
    "GPU",
    "Thermal",
    "Helper",
    "SystemMonitorWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "SystemMonitorMetric",
    "SystemMonitorIndicator"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $systemMonitor + $workspaceActionCatalog) -Needle $systemMonitorSignal -Message "System Monitor parity signal missing: $systemMonitorSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.SystemMonitor, "System Monitor", "\uE9D9", "Metrics", true)' -Message "System Monitor must be marked implemented once the read-only metrics workspace exists."

foreach ($settingsSignal in @(
    "Settings",
    "Refresh Status",
    "SettingsHeaderActions",
    "Export",
    "Import",
    "Reset",
    "Request Permission",
    "Open System Preferences",
    "Settings Tabs",
    "Settings Details",
    "Settings Actions",
    "General",
    "Network",
    "Devices",
    "File Transfer",
    "Remote Desktop",
    "System Monitor",
    "Permissions",
    "Advanced",
    "Apply Settings",
    "Restore Defaults",
    "Reset Monitor Data",
    "SettingsToolbarActions",
    "SettingsMaintenanceActions",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionItemView",
    "WorkspaceActionSurface.SettingsHeader",
    "WorkspaceActionSurface.SettingsToolbar",
    "WorkspaceActionSurface.SettingsMaintenance",
    "RefreshStatus",
    "SettingsWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "SettingsTabItem",
    "SettingsActionItem",
    "SettingsDetailItem",
    "ExportSettings",
    "ImportSettings",
    "ResetSettings",
    "ApplyFileTransferSettings",
    "ApplyRemoteDesktopSettings",
    "ResetMonitorData",
    "ClearHistoryData",
    "defaultTransferPath",
    "maxConcurrentConnections",
    "transferBufferSize",
    "autoRetryFailedTransfers",
    "keepTransferHistory",
    "keepSystemAwakeDuringTransfer",
    "scanTransferFilesForVirus",
    "scanLevel",
    "encryptionAlgorithm",
    "currentConfig",
    "optimized / needsAdjust",
    "estimatedRate",
    "resolution 1080p/2k/4k/5k",
    "framerate 30/60/120 fps",
    "preset balanced/highPerformance/highQuality/lowLatency",
    "compression none/fast/balanced/maximum",
    "videoQuality",
    "compressionLevel",
    "refreshRate",
    "enableAdaptiveQuality",
    "fullScreenMode",
    "clipboardSync",
    "audioRedirection",
    "trackpadGestures",
    "mouseSensitivity",
    "doubleClickInterval",
    "enableUDP",
    "bandwidthLimit",
    "bufferSize",
    "refreshInterval",
    "enableAutoRefresh",
    "showTrendIndicators/history",
    "enablePerformanceAlerts",
    "retentionDays/maxHistoryPoints",
    "CPU/Memory/Disk/Network/Temperature/FanSpeed",
    "enableSoundAlerts/enableNotifications",
    "PQC policy",
    "Disabled"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $settings + $workspaceActionCatalog) -Needle $settingsSignal -Message "Settings parity signal missing: $settingsSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.Settings, "Settings", "\uE713", "Preferences", true)' -Message "Settings must be marked implemented once the read-only preferences workspace exists."

foreach ($docSignal in @(
    "origin/tdsc-2026-01-0318-ios-sim-fix:Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift",
    "origin/tdsc-2026-01-0318-ios-sim-fix:Sources/SkyBridgeCompassApp/Dashboard/TopBar/TopNavigationBarView.swift",
    "origin/tdsc-2026-01-0318-ios-sim-fix:Docs/CoreLayering.md",
    "origin/tdsc-2026-01-0318-ios-sim-fix:Docs/ProtocolAlignmentPlan.md",
    "origin/tdsc-2026-01-0318-ios-sim-fix-20260211-adr:Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md",
    "Dashboard, Device Discovery, USB Management, File Transfer, Remote Desktop, Quantum, System Monitor, Settings",
    "DashboardMetricsClient",
    "ConnectionPreflightClient",
    "ConnectionWorkspaceStateClient",
    "Prepare Connection",
    "WindowsDiscoveryBrowserClient",
    "DeviceDiscoveryInputDefaultsClient",
    "Start Scan",
    "Manual Connect",
    "FPS / Diagnostics",
    "Notifications",
    "Theme",
    "TopBarStatusClient",
    "TopBarStatusSlot",
    "WorkspaceActionCommandId",
    "WorkspaceActionGateId",
    "WorkspaceActionDetailSlot",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionButtonTemplate",
    "WorkspaceActionButtonWithDetailTemplate",
    "SidebarWorkspaceActionButtonTemplate",
    "ItemsPanelTemplate",
    "DiscoveredPeerItemTemplate",
    "UsbDeviceItemTemplate",
    "FileTransferQueueItemTemplate",
    "FileTransferHistoryItemTemplate",
    "RemoteDesktopSessionItemTemplate",
    "UsbManagementHeaderActions",
    "FileTransferHeaderActions",
    "RemoteDesktopHeaderActions",
    "RemoteDesktopProfileCatalogClient",
    "QuantumDiagnosticsHeaderActions",
    "SettingsHeaderActions",
    "CrossNetworkConnectionClient",
    "Generate QR Code",
    "Smart Connection Code",
    "CoreBridge.PlanConnectionAsync",
    "Visual QA"
)) {
    Assert-Contains -Text $parityDoc -Needle $docSignal -Message "windows-ui-parity-contract.md missing signal: $docSignal"
}

Write-Output "windows-ui-parity: ok"
