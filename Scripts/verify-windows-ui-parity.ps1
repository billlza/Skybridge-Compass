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

$featureContractPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/FeatureEntryContract.cs"
$sessionViewModelPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModel.cs"
$discoveryBrowserPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs"
$manualConnectionPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ManualConnectionClient.cs"
$pairingPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs"
$connectionPreflightPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs"
$usbManagementPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/UsbManagementWorkspaceClient.cs"
$coreDiagnosticsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CoreDiagnosticsClient.cs"
$fileTransferPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
$remoteDesktopPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopWorkspaceClient.cs"
$systemMonitorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SystemMonitorWorkspaceClient.cs"
$settingsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SettingsWorkspaceClient.cs"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml"
$parityDocPath = Join-Path $RepoRoot "docs/windows-ui-parity-contract.md"

foreach ($path in @($featureContractPath, $sessionViewModelPath, $discoveryBrowserPath, $manualConnectionPath, $pairingPath, $connectionPreflightPath, $usbManagementPath, $coreDiagnosticsPath, $fileTransferPath, $remoteDesktopPath, $systemMonitorPath, $settingsPath, $mainWindowPath, $parityDocPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing parity file: $path"
}

$featureContract = Get-Content -Raw -LiteralPath $featureContractPath
$sessionViewModel = Get-Content -Raw -LiteralPath $sessionViewModelPath
$discoveryBrowser = Get-Content -Raw -LiteralPath $discoveryBrowserPath
$manualConnection = Get-Content -Raw -LiteralPath $manualConnectionPath
$pairing = Get-Content -Raw -LiteralPath $pairingPath
$connectionPreflight = Get-Content -Raw -LiteralPath $connectionPreflightPath
$usbManagement = Get-Content -Raw -LiteralPath $usbManagementPath
$coreDiagnostics = Get-Content -Raw -LiteralPath $coreDiagnosticsPath
$fileTransfer = Get-Content -Raw -LiteralPath $fileTransferPath
$remoteDesktop = Get-Content -Raw -LiteralPath $remoteDesktopPath
$systemMonitor = Get-Content -Raw -LiteralPath $systemMonitorPath
$settings = Get-Content -Raw -LiteralPath $settingsPath
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
    "OnlineDeviceCount",
    "ActiveSessionCount",
    "TransferTaskCount",
    "PerformanceStatus",
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
    "DiscoveredPeers",
    "PairingConnectionCode",
    "PairingStatus",
    "PairingFacts",
    "ConnectionPreflightStatus",
    "ConnectionPreflightFacts",
    "IsDeviceDiscoverySelected",
    "UsbManagementStatus",
    "UsbDeviceStats",
    "UsbDevices",
    "IsUsbManagementSelected",
    "FileTransferStatus",
    "FileTransferQueue",
    "FileTransferHistory",
    "FileTransferSecurityFacts",
    "IsFileTransferSelected",
    "RemoteDesktopStatus",
    "RemoteDesktopSessions",
    "RemoteDesktopControlFacts",
    "IsRemoteDesktopSelected",
    "SystemMonitorStatus",
    "SystemMonitorOverview",
    "SystemMonitorDetails",
    "SystemMonitorIndicators",
    "IsSystemMonitorSelected",
    "SettingsStatus",
    "SettingsTabs",
    "SettingsActions",
    "SettingsDetails",
    "IsSettingsSelected",
    "CoreDiagnosticsStatus",
    "CoreDiagnosticFacts",
    "IsQuantumSelected"
)) {
    Assert-Contains -Text $mainWindow -Needle $binding -Message "MainWindow.xaml missing binding: $binding"
    Assert-Contains -Text $sessionViewModel -Needle $binding -Message "SessionViewModel.cs missing property or source: $binding"
}

foreach ($command in @("ConnectCommand", "HeartbeatCommand", "DisconnectCommand", "StartDiscoveryCommand", "StopDiscoveryCommand", "RefreshDiscoveryCommand", "RunExtendedDiscoveryCommand", "PrepareManualConnectionCommand", "ParseAdvertisementCommand", "ValidatePairingCodeCommand", "PrepareConnectionCommand", "RefreshUsbManagementCommand", "RefreshFileTransferCommand", "RefreshRemoteDesktopCommand", "RefreshSystemMonitorCommand", "RefreshSettingsCommand", "RunCoreDiagnosticsCommand")) {
    Assert-Contains -Text $mainWindow -Needle "Command=`"{Binding $command}`"" -Message "MainWindow.xaml missing command binding: $command"
    Assert-Contains -Text $sessionViewModel -Needle $command -Message "SessionViewModel.cs missing command: $command"
}

foreach ($layoutSignal in @(
    "<ColumnDefinition Width=`"252`" />",
    "<RowDefinition Height=`"72`" />",
    "ItemsSource=`"{Binding NavigationItems}`"",
    "SelectedItem=`"{Binding SelectedFeature, Mode=TwoWay}`""
)) {
    Assert-Contains -Text $mainWindow -Needle $layoutSignal -Message "MainWindow.xaml missing shell layout signal: $layoutSignal"
}

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
    "DiscoveredPeerView",
    "Pairing Code",
    "Validate Pairing",
    "Prepare Connection",
    "PairingFactView",
    "ConnectionPreflightFactView",
    "PairingMaterialClient",
    "ConnectionPreflightClient",
    "skybridge-pair:v1",
    "IPeerPublicKeyProvider",
    "PublicKeyFingerprint",
    "fingerprint only; pairing must provide the peer public key",
    "Discovery pubKeyFP is verification input only",
    "Pairing code public key does not match pubKeyFP",
    "BuildReadOnlySnapshotAsync",
    "PlanConnectionAsync",
    "ComputeTransportBindingDigestAsync",
    "Transport binding digest",
    "No connection attempt is started"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $discoveryBrowser + $manualConnection + $pairing + $connectionPreflight) -Needle $discoverySignal -Message "Device Discovery parity signal missing: $discoverySignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.DeviceDiscovery, "Device Discovery", "\uE8B9", "Core TXT parse", true)' -Message "Device Discovery must be marked implemented once the Core-validated parser panel exists."

foreach ($usbSignal in @(
    "USB Management",
    "Refresh Devices",
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
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $usbManagement) -Needle $usbSignal -Message "USB Management parity signal missing: $usbSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.UsbManagement, "USB Management", "\uE88E", "Device routing", true)' -Message "USB Management must be marked implemented once the read-only device workspace exists."

foreach ($fileTransferSignal in @(
    "File Transfer",
    "Select Files",
    "Select Folder",
    "Generate QR",
    "Transfer Queue",
    "Transfer History",
    "HMAC",
    "Signature",
    "FileTransferWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "MapChannelAsync",
    "EncodeFrameAsync"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $fileTransfer) -Needle $fileTransferSignal -Message "File Transfer parity signal missing: $fileTransferSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.FileTransfer, "File Transfer", "\uE8E5", "Queue and history", true)' -Message "File Transfer must be marked implemented once the queue/history workspace exists."

foreach ($remoteDesktopSignal in @(
    "Remote Desktop",
    "Recommended Connect",
    "Advanced Connect",
    "Performance Overlay",
    "Quality",
    "Full Screen",
    "Disconnect Session",
    "Active Sessions",
    "RemoteDesktopWorkspaceClient",
    "BuildReadOnlySnapshotAsync",
    "PlanConnectionAsync",
    "CoreChannelKind.Realtime",
    "CoreChannelKind.Telemetry",
    "EncodeSbp2FrameAsync"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $remoteDesktop) -Needle $remoteDesktopSignal -Message "Remote Desktop parity signal missing: $remoteDesktopSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.RemoteDesktop, "Remote Desktop", "\uE7F4", "Sessions", true)' -Message "Remote Desktop must be marked implemented once the read-only session workspace exists."

foreach ($diagnosticSignal in @(
    "Quantum / Core Diagnostics",
    "Run Diagnostics",
    "CoreDiagnosticFactView",
    "CoreDiagnosticsClient",
    "BuildInteropSnapshotAsync",
    "ComputeTransportBindingDigestAsync",
    "Transport binding digest",
    "diagnostic-only binding material",
    "EncodeSbp2FrameAsync",
    "DecodeFrameMetadataAsync"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $coreDiagnostics) -Needle $diagnosticSignal -Message "Quantum diagnostics parity signal missing: $diagnosticSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.Quantum, "Quantum", "\uE72E", "Core diagnostics", true)' -Message "Quantum must be marked implemented once the Core diagnostics panel exists."

foreach ($systemMonitorSignal in @(
    "System Monitor",
    "Refresh Metrics",
    "Monitoring",
    "Stop Monitoring",
    "Enable Advanced Monitoring",
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
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $systemMonitor) -Needle $systemMonitorSignal -Message "System Monitor parity signal missing: $systemMonitorSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.SystemMonitor, "System Monitor", "\uE9D9", "Metrics", true)' -Message "System Monitor must be marked implemented once the read-only metrics workspace exists."

foreach ($settingsSignal in @(
    "Settings",
    "Refresh Status",
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
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $settings) -Needle $settingsSignal -Message "Settings parity signal missing: $settingsSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.Settings, "Settings", "\uE713", "Preferences", true)' -Message "Settings must be marked implemented once the read-only preferences workspace exists."

foreach ($docSignal in @(
    "origin/tdsc-2026-01-0318-ios-sim-fix-20260211-adr:Sources/SkyBridgeCompassApp/Dashboard/Navigation/NavigationItem.swift",
    "Dashboard, Device Discovery, USB Management, File Transfer, Remote Desktop, Quantum, System Monitor, Settings",
    "ConnectionPreflightClient",
    "Prepare Connection",
    "WindowsDiscoveryBrowserClient",
    "Start Scan",
    "Manual Connect",
    "CoreBridge.PlanConnectionAsync",
    "Visual QA"
)) {
    Assert-Contains -Text $parityDoc -Needle $docSignal -Message "windows-ui-parity-contract.md missing signal: $docSignal"
}

Write-Output "windows-ui-parity: ok"
