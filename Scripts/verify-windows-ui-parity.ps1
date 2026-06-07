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
$coreDiagnosticsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CoreDiagnosticsClient.cs"
$fileTransferPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
$remoteDesktopPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopWorkspaceClient.cs"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml"
$parityDocPath = Join-Path $RepoRoot "docs/windows-ui-parity-contract.md"

foreach ($path in @($featureContractPath, $sessionViewModelPath, $coreDiagnosticsPath, $fileTransferPath, $remoteDesktopPath, $mainWindowPath, $parityDocPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing parity file: $path"
}

$featureContract = Get-Content -Raw -LiteralPath $featureContractPath
$sessionViewModel = Get-Content -Raw -LiteralPath $sessionViewModelPath
$coreDiagnostics = Get-Content -Raw -LiteralPath $coreDiagnosticsPath
$fileTransfer = Get-Content -Raw -LiteralPath $fileTransferPath
$remoteDesktop = Get-Content -Raw -LiteralPath $remoteDesktopPath
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
    "DiscoveryTxtRecord",
    "DiscoveryStatus",
    "DiscoveredPeers",
    "IsDeviceDiscoverySelected",
    "FileTransferStatus",
    "FileTransferQueue",
    "FileTransferHistory",
    "FileTransferSecurityFacts",
    "IsFileTransferSelected",
    "RemoteDesktopStatus",
    "RemoteDesktopSessions",
    "RemoteDesktopControlFacts",
    "IsRemoteDesktopSelected",
    "CoreDiagnosticsStatus",
    "CoreDiagnosticFacts",
    "IsQuantumSelected"
)) {
    Assert-Contains -Text $mainWindow -Needle $binding -Message "MainWindow.xaml missing binding: $binding"
    Assert-Contains -Text $sessionViewModel -Needle $binding -Message "SessionViewModel.cs missing property or source: $binding"
}

foreach ($command in @("ConnectCommand", "HeartbeatCommand", "DisconnectCommand", "ParseAdvertisementCommand", "RefreshFileTransferCommand", "RefreshRemoteDesktopCommand", "RunCoreDiagnosticsCommand")) {
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
    "pubKeyFP",
    "Core TXT parse",
    "DiscoveredPeerView",
    "PublicKeyFingerprint",
    "fingerprint only; pairing must provide the peer public key"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract) -Needle $discoverySignal -Message "Device Discovery parity signal missing: $discoverySignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.DeviceDiscovery, "Device Discovery", "\uE8B9", "Core TXT parse", true)' -Message "Device Discovery must be marked implemented once the Core-validated parser panel exists."

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
    "EncodeSbp2FrameAsync",
    "DecodeFrameMetadataAsync"
)) {
    Assert-Contains -Text ($mainWindow + $sessionViewModel + $featureContract + $coreDiagnostics) -Needle $diagnosticSignal -Message "Quantum diagnostics parity signal missing: $diagnosticSignal"
}

Assert-Contains -Text $featureContract -Needle 'new(FeatureEntryId.Quantum, "Quantum", "\uE72E", "Core diagnostics", true)' -Message "Quantum must be marked implemented once the Core diagnostics panel exists."

foreach ($docSignal in @(
    "Dashboard, Device Discovery, USB Management, File Transfer, Remote Desktop, Quantum, System Monitor, Settings",
    "CoreBridge.PlanConnectionAsync",
    "Visual QA"
)) {
    Assert-Contains -Text $parityDoc -Needle $docSignal -Message "windows-ui-parity-contract.md missing signal: $docSignal"
}

Write-Output "windows-ui-parity: ok"
