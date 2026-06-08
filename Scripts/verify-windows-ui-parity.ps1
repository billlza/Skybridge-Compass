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

$featureContractPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FeatureCatalogClient.cs"
$legacyFeatureContractPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/FeatureEntryContract.cs"
$sessionViewModelDependencyFactoryPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/SessionViewModelDependencyFactory.cs"
$sessionViewModelPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModel.cs"
$sessionViewModelDependenciesPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionViewModelDependencies.cs"
$sessionEngineActionsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionEngineActions.cs"
$sessionEngineStateProjectorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/SessionEngineStateProjector.cs"
$discoveryBrowserActionsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/DiscoveryBrowserActions.cs"
$crossNetworkConnectionActionsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/CrossNetworkConnectionActions.cs"
$connectionWorkspaceActionsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/ConnectionWorkspaceActions.cs"
$asyncRelayCommandPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/AsyncRelayCommand.cs"
$workspaceCommandGateCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandGateCoordinator.cs"
$workspaceCommandAvailabilityPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandAvailability.cs"
$workspaceCommandBindingsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandBindings.cs"
$workspaceCommandRegistryPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandRegistry.cs"
$workspaceActionSurfaceTargetsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceActionSurfaceTargets.cs"
$workspaceActionSurfaceLoaderPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceActionSurfaceLoader.cs"
$workspaceActionRenderContextBuilderPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceActionRenderContextBuilder.cs"
$workspaceShellRefreshCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceShellRefreshCoordinator.cs"
$workspaceShellNotificationCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceShellNotificationCatalog.cs"
$workspaceShellStateAccessorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceShellStateAccessor.cs"
$workspaceViewStateBuilderPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceViewStateBuilder.cs"
$workspaceStartupStateBuilderPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceStartupStateBuilder.cs"
$workspaceStatusPatchApplierPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceStatusPatchApplier.cs"
$workspaceBusyCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceBusyCoordinator.cs"
$readOnlyWorkspaceRefreshCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/ReadOnlyWorkspaceRefreshCoordinator.cs"
$readOnlyWorkspaceRefreshActionsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/ReadOnlyWorkspaceRefreshActions.cs"
$readOnlyWorkspaceSnapshotHandlersPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/ReadOnlyWorkspaceSnapshotHandlers.cs"
$workspaceCountNotifierPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCountNotifier.cs"
$workspaceObservableCollectionsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceObservableCollections.cs"
$workspaceCollectionProjectorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceCollectionProjector.cs"
$workspaceSnapshotApplierPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceSnapshotApplier.cs"
$dashboardMetricsUpdaterPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/DashboardMetricsUpdater.cs"
$topBarStatusUpdaterPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/TopBarStatusUpdater.cs"
$crossNetworkCodeInputCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/CrossNetworkCodeInputCoordinator.cs"
$connectionWorkspaceInputCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/ConnectionWorkspaceInputCoordinator.cs"
$connectionWorkspaceResultProjectorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/ConnectionWorkspaceResultProjector.cs"
$workspaceItemViewsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/WorkspaceItemViews.cs"
$dashboardMetricsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DashboardMetricsClient.cs"
$discoveryBrowserPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs"
$deviceDiscoveryInputDefaultsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/DeviceDiscoveryInputDefaultsClient.cs"
$manualConnectionPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ManualConnectionClient.cs"
$crossNetworkPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CrossNetworkConnectionClient.cs"
$pairingPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/PairingMaterialClient.cs"
$connectionPreflightPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionPreflightClient.cs"
$connectionWorkspaceStatePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/ConnectionWorkspaceStateClient.cs"
$workspaceErrorStatusPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceErrorStatusClient.cs"
$usbManagementPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/UsbManagementWorkspaceClient.cs"
$coreDiagnosticsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/CoreDiagnosticsClient.cs"
$fileTransferPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/FileTransferWorkspaceClient.cs"
$workspaceActionCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceActionCatalogClient.cs"
$remoteDesktopPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopWorkspaceClient.cs"
$remoteDesktopProfileCatalogPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/RemoteDesktopProfileCatalogClient.cs"
$remoteDesktopProfileSelectionCoordinatorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/ViewModels/RemoteDesktopProfileSelectionCoordinator.cs"
$systemMonitorPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SystemMonitorWorkspaceClient.cs"
$settingsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SettingsWorkspaceClient.cs"
$topBarStatusPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/TopBarStatusClient.cs"
$sessionStatusPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SessionStatusClient.cs"
$sessionCommandStatePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/SessionCommandStateClient.cs"
$workspaceCommandStatePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/WorkspaceCommandStateClient.cs"
$unavailableClientStubsPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/Services/UnavailableClientStubs.cs"
$mainWindowPath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml"
$mainWindowCodePath = Join-Path $RepoRoot "windows/Skybridge.WinClient/MainWindow.xaml.cs"
$parityDocPath = Join-Path $RepoRoot "docs/windows-ui-parity-contract.md"

foreach ($path in @($featureContractPath, $sessionViewModelDependencyFactoryPath, $sessionViewModelPath, $sessionViewModelDependenciesPath, $sessionEngineActionsPath, $sessionEngineStateProjectorPath, $discoveryBrowserActionsPath, $crossNetworkConnectionActionsPath, $connectionWorkspaceActionsPath, $asyncRelayCommandPath, $workspaceCommandGateCoordinatorPath, $workspaceCommandAvailabilityPath, $workspaceCommandBindingsPath, $workspaceCommandRegistryPath, $workspaceActionSurfaceTargetsPath, $workspaceActionSurfaceLoaderPath, $workspaceActionRenderContextBuilderPath, $workspaceShellRefreshCoordinatorPath, $workspaceShellNotificationCatalogPath, $workspaceShellStateAccessorPath, $workspaceViewStateBuilderPath, $workspaceStartupStateBuilderPath, $workspaceStatusPatchApplierPath, $workspaceBusyCoordinatorPath, $readOnlyWorkspaceRefreshCoordinatorPath, $readOnlyWorkspaceRefreshActionsPath, $readOnlyWorkspaceSnapshotHandlersPath, $workspaceCountNotifierPath, $workspaceObservableCollectionsPath, $workspaceCollectionProjectorPath, $workspaceSnapshotApplierPath, $dashboardMetricsUpdaterPath, $topBarStatusUpdaterPath, $crossNetworkCodeInputCoordinatorPath, $connectionWorkspaceInputCoordinatorPath, $connectionWorkspaceResultProjectorPath, $workspaceItemViewsPath, $dashboardMetricsPath, $discoveryBrowserPath, $deviceDiscoveryInputDefaultsPath, $manualConnectionPath, $crossNetworkPath, $pairingPath, $connectionPreflightPath, $connectionWorkspaceStatePath, $workspaceErrorStatusPath, $usbManagementPath, $coreDiagnosticsPath, $fileTransferPath, $workspaceActionCatalogPath, $remoteDesktopPath, $remoteDesktopProfileCatalogPath, $remoteDesktopProfileSelectionCoordinatorPath, $systemMonitorPath, $settingsPath, $topBarStatusPath, $sessionStatusPath, $sessionCommandStatePath, $workspaceCommandStatePath, $unavailableClientStubsPath, $mainWindowPath, $mainWindowCodePath, $parityDocPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path) -Message "Missing parity file: $path"
}
Assert-True -Condition (-not (Test-Path -LiteralPath $legacyFeatureContractPath)) -Message "Feature catalog must live under Services, not ViewModels: $legacyFeatureContractPath"

$featureContract = Get-Content -Raw -LiteralPath $featureContractPath
$sessionViewModelDependencyFactory = Get-Content -Raw -LiteralPath $sessionViewModelDependencyFactoryPath
$sessionViewModelSource = Get-Content -Raw -LiteralPath $sessionViewModelPath
$sessionViewModelDependencies = Get-Content -Raw -LiteralPath $sessionViewModelDependenciesPath
$sessionEngineActions = Get-Content -Raw -LiteralPath $sessionEngineActionsPath
$sessionEngineStateProjector = Get-Content -Raw -LiteralPath $sessionEngineStateProjectorPath
$discoveryBrowserActions = Get-Content -Raw -LiteralPath $discoveryBrowserActionsPath
$crossNetworkConnectionActions = Get-Content -Raw -LiteralPath $crossNetworkConnectionActionsPath
$connectionWorkspaceActions = Get-Content -Raw -LiteralPath $connectionWorkspaceActionsPath
$asyncRelayCommand = Get-Content -Raw -LiteralPath $asyncRelayCommandPath
$workspaceCommandGateCoordinator = Get-Content -Raw -LiteralPath $workspaceCommandGateCoordinatorPath
$workspaceCommandAvailability = Get-Content -Raw -LiteralPath $workspaceCommandAvailabilityPath
$workspaceCommandBindings = Get-Content -Raw -LiteralPath $workspaceCommandBindingsPath
$workspaceCommandRegistry = Get-Content -Raw -LiteralPath $workspaceCommandRegistryPath
$workspaceActionSurfaceTargets = Get-Content -Raw -LiteralPath $workspaceActionSurfaceTargetsPath
$workspaceActionSurfaceLoader = Get-Content -Raw -LiteralPath $workspaceActionSurfaceLoaderPath
$workspaceActionRenderContextBuilder = Get-Content -Raw -LiteralPath $workspaceActionRenderContextBuilderPath
$workspaceShellRefreshCoordinator = Get-Content -Raw -LiteralPath $workspaceShellRefreshCoordinatorPath
$workspaceShellNotificationCatalog = Get-Content -Raw -LiteralPath $workspaceShellNotificationCatalogPath
$workspaceShellStateAccessor = Get-Content -Raw -LiteralPath $workspaceShellStateAccessorPath
$workspaceViewStateBuilder = Get-Content -Raw -LiteralPath $workspaceViewStateBuilderPath
$workspaceStartupStateBuilder = Get-Content -Raw -LiteralPath $workspaceStartupStateBuilderPath
$workspaceStatusPatchApplier = Get-Content -Raw -LiteralPath $workspaceStatusPatchApplierPath
$workspaceBusyCoordinator = Get-Content -Raw -LiteralPath $workspaceBusyCoordinatorPath
$readOnlyWorkspaceRefreshCoordinator = Get-Content -Raw -LiteralPath $readOnlyWorkspaceRefreshCoordinatorPath
$readOnlyWorkspaceRefreshActions = Get-Content -Raw -LiteralPath $readOnlyWorkspaceRefreshActionsPath
$readOnlyWorkspaceSnapshotHandlers = Get-Content -Raw -LiteralPath $readOnlyWorkspaceSnapshotHandlersPath
$workspaceCountNotifier = Get-Content -Raw -LiteralPath $workspaceCountNotifierPath
$workspaceObservableCollections = Get-Content -Raw -LiteralPath $workspaceObservableCollectionsPath
$workspaceCollectionProjector = Get-Content -Raw -LiteralPath $workspaceCollectionProjectorPath
$workspaceSnapshotApplier = Get-Content -Raw -LiteralPath $workspaceSnapshotApplierPath
$dashboardMetricsUpdater = Get-Content -Raw -LiteralPath $dashboardMetricsUpdaterPath
$topBarStatusUpdater = Get-Content -Raw -LiteralPath $topBarStatusUpdaterPath
$crossNetworkCodeInputCoordinator = Get-Content -Raw -LiteralPath $crossNetworkCodeInputCoordinatorPath
$connectionWorkspaceInputCoordinator = Get-Content -Raw -LiteralPath $connectionWorkspaceInputCoordinatorPath
$connectionWorkspaceResultProjector = Get-Content -Raw -LiteralPath $connectionWorkspaceResultProjectorPath
$remoteDesktopProfileSelectionCoordinator = Get-Content -Raw -LiteralPath $remoteDesktopProfileSelectionCoordinatorPath
$workspaceItemViews = Get-Content -Raw -LiteralPath $workspaceItemViewsPath
$sessionViewModel = $sessionViewModelSource + $sessionViewModelDependencies + $sessionEngineActions + $sessionEngineStateProjector + $discoveryBrowserActions + $crossNetworkConnectionActions + $connectionWorkspaceActions + $workspaceItemViews + $workspaceCommandGateCoordinator + $workspaceCommandAvailability + $workspaceCommandBindings + $workspaceCommandRegistry + $workspaceActionSurfaceTargets + $workspaceActionSurfaceLoader + $workspaceActionRenderContextBuilder + $workspaceShellRefreshCoordinator + $workspaceShellNotificationCatalog + $workspaceShellStateAccessor + $workspaceViewStateBuilder + $workspaceStartupStateBuilder + $workspaceStatusPatchApplier + $workspaceBusyCoordinator + $readOnlyWorkspaceRefreshCoordinator + $readOnlyWorkspaceRefreshActions + $readOnlyWorkspaceSnapshotHandlers + $workspaceCountNotifier + $workspaceObservableCollections + $workspaceCollectionProjector + $workspaceSnapshotApplier + $dashboardMetricsUpdater + $topBarStatusUpdater + $crossNetworkCodeInputCoordinator + $connectionWorkspaceInputCoordinator + $connectionWorkspaceResultProjector + $remoteDesktopProfileSelectionCoordinator
$dashboardMetrics = Get-Content -Raw -LiteralPath $dashboardMetricsPath
$discoveryBrowser = Get-Content -Raw -LiteralPath $discoveryBrowserPath
$deviceDiscoveryInputDefaults = Get-Content -Raw -LiteralPath $deviceDiscoveryInputDefaultsPath
$manualConnection = Get-Content -Raw -LiteralPath $manualConnectionPath
$crossNetwork = Get-Content -Raw -LiteralPath $crossNetworkPath
$pairing = Get-Content -Raw -LiteralPath $pairingPath
$connectionPreflight = Get-Content -Raw -LiteralPath $connectionPreflightPath
$connectionWorkspaceState = Get-Content -Raw -LiteralPath $connectionWorkspaceStatePath
$workspaceErrorStatus = Get-Content -Raw -LiteralPath $workspaceErrorStatusPath
$usbManagement = Get-Content -Raw -LiteralPath $usbManagementPath
$coreDiagnostics = Get-Content -Raw -LiteralPath $coreDiagnosticsPath
$fileTransfer = Get-Content -Raw -LiteralPath $fileTransferPath
$workspaceActionCatalog = Get-Content -Raw -LiteralPath $workspaceActionCatalogPath
$remoteDesktop = Get-Content -Raw -LiteralPath $remoteDesktopPath
$remoteDesktopProfileCatalog = Get-Content -Raw -LiteralPath $remoteDesktopProfileCatalogPath
$systemMonitor = Get-Content -Raw -LiteralPath $systemMonitorPath
$settings = Get-Content -Raw -LiteralPath $settingsPath
$topBarStatus = Get-Content -Raw -LiteralPath $topBarStatusPath
$sessionStatus = Get-Content -Raw -LiteralPath $sessionStatusPath
$sessionCommandState = Get-Content -Raw -LiteralPath $sessionCommandStatePath
$workspaceCommandState = Get-Content -Raw -LiteralPath $workspaceCommandStatePath
$unavailableClientStubs = Get-Content -Raw -LiteralPath $unavailableClientStubsPath
$mainWindow = Get-Content -Raw -LiteralPath $mainWindowPath
$mainWindowCode = Get-Content -Raw -LiteralPath $mainWindowCodePath
$parityDoc = Get-Content -Raw -LiteralPath $parityDocPath

$parsedXaml = [xml]$mainWindow
Assert-True -Condition ($null -ne $parsedXaml) -Message "MainWindow.xaml is not well-formed XML."

foreach ($compositionSignal in @(
    "SessionViewModelDependencies",
    "SessionViewModelDependencyFactory",
    "SessionViewModelDependencyFactory.CreateDefault()",
    "new SessionViewModel(SessionViewModelDependencyFactory.CreateDefault())"
)) {
    Assert-Contains -Text ($sessionViewModelDependencyFactory + $sessionViewModel + $mainWindowCode + $parityDoc) -Needle $compositionSignal -Message "Windows composition signal missing: $compositionSignal"
}

Assert-True -Condition (-not [regex]::IsMatch($mainWindowCode, "new\s+(CoreBridge|CoreDiscoveryClient|WindowsDiscoveryBrowserClient|DummyEngineClient|DeviceDiscoveryInputDefaultsClient|ManualConnectionClient|CrossNetworkConnectionClient|PairingMaterialClient|ConnectionPreflightClient|CoreDiagnosticsClient|FileTransferWorkspaceClient|RemoteDesktopWorkspaceClient|RemoteDesktopProfileCatalogClient|SystemMonitorWorkspaceClient|UsbManagementWorkspaceClient|SettingsWorkspaceClient|DashboardMetricsClient|TopBarStatusClient|ConnectionWorkspaceStateClient|WorkspaceActionCatalogClient|WorkspaceErrorStatusClient|SessionStatusClient|FeatureCatalogClient|SessionCommandStateClient|WorkspaceCommandStateClient)\(")) -Message "MainWindow.xaml.cs must create SessionViewModel through SessionViewModelDependencyFactory, not direct service construction."

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

foreach ($featureCatalogSignal in @(
    "public interface IFeatureCatalogClient",
    "public sealed class FeatureCatalogClient : IFeatureCatalogClient",
    "BuildReadOnlySnapshot",
    "ResolveDefaultSelection",
    "IsSelected",
    "FeatureEntryId",
    "public sealed record FeatureEntry",
    "Entries",
    "_featureCatalogClient.BuildReadOnlySnapshot()",
    "_featureCatalogClient.ResolveDefaultSelection(featureEntries)",
    "ApplyWorkspaceInputChange",
    "RefreshSelectedFeatureState",
    "RefreshConnectionState",
    "RefreshShellRuntimeState",
    "private bool IsFeatureSelected(FeatureEntryId featureId)",
    "_workspaceCommandGateCoordinator.IsFeatureSelected(SelectedFeature, featureId)",
    "_featureCatalogClient.IsSelected(selectedFeature, featureId)",
    "IsFeatureSelected(FeatureEntryId.DeviceDiscovery)",
    "IsFeatureSelected(FeatureEntryId.Settings)",
    "new FeatureCatalogClient()"
)) {
    Assert-Contains -Text ($featureContract + $sessionViewModel) -Needle $featureCatalogSignal -Message "Feature catalog service signal missing: $featureCatalogSignal"
}
Assert-True -Condition (-not $sessionViewModel.Contains("FeatureEntryContract")) -Message "SessionViewModel must source navigation entries from FeatureCatalogClient instead of FeatureEntryContract."
Assert-True -Condition (-not $sessionViewModel.Contains("NavigationItems[0]")) -Message "SessionViewModel must source default navigation selection from FeatureCatalogClient."
Assert-True -Condition (-not $sessionViewModelSource.Contains("SelectedFeature.Id == FeatureEntryId.")) -Message "SessionViewModel must source selected-feature predicates from FeatureCatalogClient.IsSelected."
$featureSelectedMatches = [regex]::Matches($workspaceCommandGateCoordinator, [regex]::Escape("_featureCatalogClient.IsSelected("))
Assert-True -Condition ($featureSelectedMatches.Count -eq 1) -Message "WorkspaceCommandGateCoordinator must centralize selected-feature predicates through FeatureCatalogClient.IsSelected."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_featureCatalogClient.IsSelected(")) -Message "SessionViewModel must delegate selected-feature predicates through WorkspaceCommandGateCoordinator."
Assert-True -Condition ($sessionViewModelSource.Contains("RefreshSelectedFeatureState();")) -Message "SelectedFeature setter must delegate selected-state notifications to RefreshSelectedFeatureState."
Assert-True -Condition ($sessionViewModelSource.Contains("RefreshConnectionState();")) -Message "ConnectionState setter must delegate shell refresh to RefreshConnectionState."
Assert-True -Condition ($sessionViewModelSource.Contains("RefreshShellRuntimeState();")) -Message "Runtime shell refresh must be centralized through RefreshShellRuntimeState."
foreach ($inputChangeSignal in @(
    "ApplyWorkspaceInputChange(_connectionInputCoordinator.InvalidatePairingAndPreflight)",
    "ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetManualConnectionInput)",
    "ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetCrossNetworkInput)",
    "ApplyWorkspaceInputChange(_connectionInputCoordinator.ResetPairingInput)"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $inputChangeSignal -Message "Workspace input change helper missing signal: $inputChangeSignal"
}

foreach ($workspaceItemViewSignal in @(
    "public sealed record SettingsTabItemView",
    "public sealed record DashboardMetricView",
    "public sealed record WorkspaceActionItemView",
    "public sealed record DiscoveredPeerView",
    "public sealed record DiscoveryBrowserFactView",
    "public sealed record ManualConnectionFactView",
    "public sealed record CrossNetworkConnectionFactView",
    "public sealed record ConnectionPreflightFactView",
    "public sealed record PairingFactView",
    "public sealed record CoreDiagnosticFactView",
    "FromItem",
    "FromFact",
    "FromCandidate"
)) {
    Assert-Contains -Text $workspaceItemViews -Needle $workspaceItemViewSignal -Message "Workspace item view contract missing from WorkspaceItemViews.cs: $workspaceItemViewSignal"
}

foreach ($viewModelOwnedItemView in @(
    "public sealed record SettingsTabItemView",
    "public sealed record DashboardMetricView",
    "public sealed record WorkspaceActionItemView",
    "public sealed record DiscoveredPeerView"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($viewModelOwnedItemView)) -Message "SessionViewModel.cs must not own reusable workspace item view records: $viewModelOwnedItemView"
}

foreach ($viewModelProjectionSignal in @(
    "WorkspaceCountNotifier",
    "new DashboardMetricsUpdater(",
    "new WorkspaceShellRefreshCoordinator(",
    "BuildDashboardMetricsRequest",
    "new WorkspaceSnapshotApplier(_workspaceCountNotifier, RefreshDashboardMetrics)",
    "new ReadOnlyWorkspaceRefreshActions(",
    "new ReadOnlyWorkspaceSnapshotHandlers(",
    "_readOnlyWorkspaceRefreshActions.RefreshFileTransferAsync()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $viewModelProjectionSignal -Message "SessionViewModel reusable projection helper missing: $viewModelProjectionSignal"
}
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "OnPropertyChanged\(nameof\([A-Za-z]+Count\)\)")) -Message "SessionViewModel must notify derived count properties through WorkspaceCountNotifier."

foreach ($observableCollectionsSignal in @(
    "internal sealed class WorkspaceObservableCollections",
    "IEnumerable<FeatureEntry> featureEntries",
    "RemoteDesktopProfileCatalogSnapshot profileCatalog",
    "NavigationItems = new ObservableCollection<FeatureEntry>(featureEntries)",
    "DashboardMetrics = new ObservableCollection<DashboardMetricView>()",
    "BitrateProfiles = new ObservableCollection<string>(profileCatalog.BitrateProfiles)",
    "FramerateProfiles = new ObservableCollection<string>(profileCatalog.FramerateProfiles)",
    "SidebarSessionActions = new ObservableCollection<WorkspaceActionItemView>()",
    "TopBarActions = new ObservableCollection<WorkspaceActionItemView>()",
    "SessionControlActions = new ObservableCollection<WorkspaceActionItemView>()",
    "DiscoveredPeers = new ObservableCollection<DiscoveredPeerView>()",
    "DiscoveryBrowserFacts = new ObservableCollection<DiscoveryBrowserFactView>()",
    "CrossNetworkConnectionFacts = new ObservableCollection<CrossNetworkConnectionFactView>()",
    "CoreDiagnosticFacts = new ObservableCollection<CoreDiagnosticFactView>()",
    "RemoteDesktopSessions = new ObservableCollection<RemoteDesktopSessionItemView>()",
    "SystemMonitorIndicators = new ObservableCollection<SystemMonitorIndicatorView>()",
    "SettingsDetails = new ObservableCollection<SettingsDetailItemView>()"
)) {
    Assert-Contains -Text $workspaceObservableCollections -Needle $observableCollectionsSignal -Message "WorkspaceObservableCollections contract missing: $observableCollectionsSignal"
}
foreach ($sessionViewModelCollectionSignal in @(
    "var collections = new WorkspaceObservableCollections(",
    "startupState.FeatureEntries,",
    "startupState.RemoteDesktopProfileCatalog);",
    "NavigationItems = collections.NavigationItems;",
    "DashboardMetrics = collections.DashboardMetrics;",
    "BitrateProfiles = collections.BitrateProfiles;",
    "FramerateProfiles = collections.FramerateProfiles;",
    "DiscoveredPeers = collections.DiscoveredPeers;",
    "CoreDiagnosticFacts = collections.CoreDiagnosticFacts;",
    "RemoteDesktopSessions = collections.RemoteDesktopSessions;",
    "SettingsDetails = collections.SettingsDetails;"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelCollectionSignal -Message "SessionViewModel must receive XAML-bound collections from WorkspaceObservableCollections: $sessionViewModelCollectionSignal"
}
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "new\s+ObservableCollection<")) -Message "SessionViewModel must not construct XAML-bound ObservableCollection instances directly."

foreach ($collectionProjectorSignal in @(
    "internal static class WorkspaceCollectionProjector",
    "public static void Replace<TSource, TItem>",
    "ObservableCollection<TItem> target",
    "IEnumerable<TSource> source",
    "Func<TSource, TItem> map"
)) {
    Assert-Contains -Text $workspaceCollectionProjector -Needle $collectionProjectorSignal -Message "WorkspaceCollectionProjector contract missing: $collectionProjectorSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("ReplaceCollection(")) -Message "SessionViewModel must use WorkspaceCollectionProjector.Replace instead of owning ReplaceCollection."
Assert-True -Condition (-not $workspaceSnapshotApplier.Contains("ReplaceCollection(")) -Message "WorkspaceSnapshotApplier must reuse WorkspaceCollectionProjector.Replace instead of owning ReplaceCollection."

foreach ($dashboardUpdaterSignal in @(
    "internal sealed class DashboardMetricsUpdater",
    "IDashboardMetricsClient dashboardMetricsClient",
    "BuildReadOnlySnapshot(request)",
    "_setOnlineDeviceCount(snapshot.OnlineDeviceCount)",
    "_setActiveSessionCount(snapshot.ActiveSessionCount)",
    "_setTransferTaskCount(snapshot.TransferTaskCount)",
    "_setPerformanceStatus(snapshot.PerformanceStatus)",
    "WorkspaceCollectionProjector.Replace(_dashboardMetrics, snapshot.Metrics, DashboardMetricView.FromMetric)",
    "_countNotifier.DashboardMetricsChanged()"
)) {
    Assert-Contains -Text $dashboardMetricsUpdater -Needle $dashboardUpdaterSignal -Message "DashboardMetricsUpdater contract missing: $dashboardUpdaterSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("_dashboardMetricsClient.BuildReadOnlySnapshot(")) -Message "SessionViewModel must refresh dashboard metric snapshots through DashboardMetricsUpdater."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_dashboardMetricsUpdater.Refresh(")) -Message "SessionViewModel must route dashboard refresh cadence through WorkspaceShellRefreshCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("WorkspaceCollectionProjector.Replace(DashboardMetrics, snapshot.Metrics, DashboardMetricView.FromMetric)")) -Message "SessionViewModel must project dashboard metric rows through DashboardMetricsUpdater."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceCountNotifier.DashboardMetricsChanged()")) -Message "SessionViewModel must notify dashboard metric count through DashboardMetricsUpdater."

foreach ($snapshotApplierSignal in @(
    "internal sealed class WorkspaceSnapshotApplier",
    "ApplyCoreDiagnostics(",
    "ApplyFileTransfer(",
    "ApplyUsbManagement(",
    "ApplyRemoteDesktop(",
    "ApplySystemMonitor(",
    "ApplySettings(",
    "WorkspaceCollectionProjector.Replace(queue, snapshot.Queue, FileTransferQueueItemView.FromItem)",
    "WorkspaceCollectionProjector.Replace(details, snapshot.Details, SettingsDetailItemView.FromItem)",
    "_refreshDashboardMetrics();",
    "_countNotifier.SettingsActionsChanged()"
)) {
    Assert-Contains -Text $workspaceSnapshotApplier -Needle $snapshotApplierSignal -Message "WorkspaceSnapshotApplier contract missing: $snapshotApplierSignal"
}

foreach ($snapshotHandlerSignal in @(
    "internal sealed class ReadOnlyWorkspaceSnapshotHandlers",
    "WorkspaceSnapshotApplier snapshotApplier",
    "WorkspaceObservableCollections collections",
    "ApplyCoreDiagnostics(CoreDiagnosticsSnapshot snapshot)",
    "_snapshotApplier.ApplyCoreDiagnostics(snapshot, _collections.CoreDiagnosticFacts)",
    "ApplyFileTransfer(FileTransferWorkspaceSnapshot snapshot)",
    "_collections.FileTransferQueue",
    "_collections.FileTransferHistory",
    "_collections.FileTransferSecurityFacts",
    "ApplyUsbManagement(UsbManagementWorkspaceSnapshot snapshot)",
    "_collections.UsbDeviceStats",
    "_collections.UsbDevices",
    "ApplyRemoteDesktop(RemoteDesktopWorkspaceSnapshot snapshot)",
    "_collections.RemoteDesktopSessions",
    "_collections.RemoteDesktopControlFacts",
    "ApplySystemMonitor(SystemMonitorWorkspaceSnapshot snapshot)",
    "_collections.SystemMonitorOverview",
    "_collections.SystemMonitorDetails",
    "_collections.SystemMonitorIndicators",
    "ApplySettings(SettingsWorkspaceSnapshot snapshot)",
    "_collections.SettingsTabs",
    "_collections.SettingsActions",
    "_collections.SettingsDetails"
)) {
    Assert-Contains -Text $readOnlyWorkspaceSnapshotHandlers -Needle $snapshotHandlerSignal -Message "ReadOnlyWorkspaceSnapshotHandlers contract missing: $snapshotHandlerSignal"
}
foreach ($viewModelSnapshotHandlerReturnSignal in @(
    "ApplyCoreDiagnosticsSnapshot",
    "ApplyFileTransferSnapshot",
    "ApplyUsbManagementSnapshot",
    "ApplyRemoteDesktopSnapshot",
    "ApplySystemMonitorSnapshot",
    "ApplySettingsSnapshot",
    "_workspaceSnapshotApplier.ApplyCoreDiagnostics(",
    "_workspaceSnapshotApplier.ApplyFileTransfer(",
    "_workspaceSnapshotApplier.ApplyUsbManagement(",
    "_workspaceSnapshotApplier.ApplyRemoteDesktop(",
    "_workspaceSnapshotApplier.ApplySystemMonitor(",
    "_workspaceSnapshotApplier.ApplySettings("
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($viewModelSnapshotHandlerReturnSignal)) -Message "SessionViewModel must route read-only snapshot collection maps through ReadOnlyWorkspaceSnapshotHandlers: $viewModelSnapshotHandlerReturnSignal"
}

foreach ($viewModelSnapshotProjection in @(
    "ReplaceCollection(CoreDiagnosticFacts, snapshot.Facts, CoreDiagnosticFactView.FromFact)",
    "ReplaceCollection(FileTransferQueue, snapshot.Queue, FileTransferQueueItemView.FromItem)",
    "ReplaceCollection(FileTransferHistory, snapshot.History, FileTransferHistoryItemView.FromItem)",
    "ReplaceCollection(UsbDevices, snapshot.Devices, UsbDeviceItemView.FromItem)",
    "ReplaceCollection(RemoteDesktopSessions, snapshot.Sessions, RemoteDesktopSessionItemView.FromItem)",
    "ReplaceCollection(SystemMonitorOverview, snapshot.Overview, SystemMonitorMetricView.FromMetric)",
    "ReplaceCollection(SettingsDetails, snapshot.Details, SettingsDetailItemView.FromItem)",
    "_workspaceCountNotifier.FileTransferHistoryChanged()",
    "_workspaceCountNotifier.SettingsActionsChanged()"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($viewModelSnapshotProjection)) -Message "SessionViewModel must apply read-only workspace snapshots through WorkspaceSnapshotApplier instead of inline projection: $viewModelSnapshotProjection"
}

foreach ($asyncRelayCommandSignal in @(
    "public sealed class AsyncRelayCommand : ICommand",
    "Func<Task>",
    "RaiseCanExecuteChanged"
)) {
    Assert-Contains -Text $asyncRelayCommand -Needle $asyncRelayCommandSignal -Message "AsyncRelayCommand contract missing from AsyncRelayCommand.cs: $asyncRelayCommandSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("public sealed class AsyncRelayCommand")) -Message "SessionViewModel.cs must not own the reusable AsyncRelayCommand adapter."

foreach ($commandBindingsSignal in @(
    "internal sealed class WorkspaceCommandBindings",
    "new AsyncRelayCommand(connectAsync, canConnect)",
    "new AsyncRelayCommand(refreshSettingsAsync, canRefreshSettings)",
    "Registry = WorkspaceCommandRegistry.Create(",
    "WorkspaceActionCommandId.Connect",
    "WorkspaceActionCommandId.RefreshSettings",
    "public WorkspaceCommandRegistry Registry { get; }"
)) {
    Assert-Contains -Text $workspaceCommandBindings -Needle $commandBindingsSignal -Message "WorkspaceCommandBindings contract missing: $commandBindingsSignal"
}

foreach ($commandRegistrySignal in @(
    "public sealed class WorkspaceCommandRegistry",
    "WorkspaceCommandRegistration",
    "RefreshableCommands",
    "public void RefreshAll()",
    "(command as AsyncRelayCommand)?.RaiseCanExecuteChanged();",
    "Resolve(WorkspaceActionCommandId commandId)",
    "Duplicate workspace command registration"
)) {
    Assert-Contains -Text $workspaceCommandRegistry -Needle $commandRegistrySignal -Message "WorkspaceCommandRegistry contract missing: $commandRegistrySignal"
}

foreach ($commandRefreshSignal in @(
    "private readonly WorkspaceCommandRegistry _workspaceCommandRegistry;",
    "new WorkspaceCommandBindings(",
    "_workspaceCommandRegistry = commandBindings.Registry;"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $commandRefreshSignal -Message "SessionViewModel command refresh registry missing: $commandRefreshSignal"
}
Assert-Contains -Text $workspaceShellRefreshCoordinator -Needle "_commandRegistry.RefreshAll();" -Message "WorkspaceShellRefreshCoordinator must own command refresh registry iteration."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceCommandRegistry.RefreshAll();")) -Message "SessionViewModel must route command refresh through WorkspaceShellRefreshCoordinator."
Assert-Contains -Text $workspaceActionSurfaceLoader -Needle "_commandRegistry.Resolve(action.CommandId)" -Message "WorkspaceActionSurfaceLoader must bind action role commands through WorkspaceCommandRegistry."
Assert-True -Condition (-not $sessionViewModelSource.Contains("(ConnectCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();")) -Message "SessionViewModel must refresh command states through WorkspaceCommandRegistry.RefreshAll instead of per-command cast calls."
Assert-True -Condition (-not $sessionViewModelSource.Contains("(command as AsyncRelayCommand)?.RaiseCanExecuteChanged();")) -Message "SessionViewModel must delegate command refresh iteration to WorkspaceCommandRegistry.RefreshAll."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceCommandRegistry.RefreshableCommands")) -Message "SessionViewModel must not enumerate refreshable commands directly."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_refreshableCommands")) -Message "SessionViewModel must source refreshable commands from WorkspaceCommandRegistry."
Assert-True -Condition (-not $sessionViewModelSource.Contains("new AsyncRelayCommand(")) -Message "SessionViewModel must create bindable commands through WorkspaceCommandBindings."
Assert-True -Condition (-not $sessionViewModelSource.Contains("WorkspaceCommandRegistry.Create(")) -Message "SessionViewModel must source the command registry from WorkspaceCommandBindings."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceCommandRegistry.Resolve(action.CommandId)")) -Message "SessionViewModel must bind action role commands through WorkspaceActionSurfaceLoader."

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
    "BuildResolvedStatusSnapshot",
    "BuildStatusUpdate",
    "BuildDefaultStatusValue",
    "ResolveStatusValue",
    "BuildWorkspaceActionDetailSnapshot",
    "DefaultNotificationsStatus",
    "DefaultThemeStatus",
    "TopBarStatusRequest",
    "TopBarStatusSnapshot",
    "TopBarResolvedStatusSnapshot",
    "TopBarStatusUpdateSnapshot",
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
    "WorkspaceCommandRegistry",
    "TopBarStatusUpdater",
    "ResolveEnabled",
    "ResolveDetail",
    "_topBarStatusUpdater.Refresh(",
    "_topBarStatusUpdater.BuildActionDetails(",
    "WorkspaceActionRenderContext",
    "WorkspaceActionRenderContextBuilder",
    "BuildContext",
    "ResolvedStatus",
    "ActionDetails",
    "NotificationsStatus",
    "ThemeStatus",
    "WorkspaceActionGateSnapshot",
    "WorkspaceActionDetailSnapshot",
    "new TopBarStatusClient()",
    "WorkspaceActionCatalogClient",
    "Visible mac-parity notification entry point",
    "Visible mac-parity theme entry point"
)) {
    Assert-Contains -Text ($topBarStatus + $sessionViewModel + $mainWindow + $workspaceActionCatalog) -Needle $topBarSignal -Message "Top bar parity signal missing: $topBarSignal"
}

foreach ($topBarUpdaterSignal in @(
    "internal sealed class TopBarStatusUpdater",
    "ITopBarStatusClient topBarStatusClient",
    "WorkspaceActionSurfaceLoader actionSurfaceLoader",
    "BuildActionDetails(TopBarStatusRequest request)",
    "BuildStatusUpdate(request)",
    "_setConnectionStatus(update.ResolvedStatus.ConnectionStatus)",
    "_setDiagnosticsStatus(update.ResolvedStatus.DiagnosticsStatus)",
    "_setNotificationsStatus(update.ResolvedStatus.NotificationsStatus)",
    "_setThemeStatus(update.ResolvedStatus.ThemeStatus)",
    "WorkspaceActionSurface.TopBarActions",
    "new WorkspaceActionRenderContext(gates, update.ActionDetails)"
)) {
    Assert-Contains -Text $topBarStatusUpdater -Needle $topBarUpdaterSignal -Message "TopBarStatusUpdater contract missing: $topBarUpdaterSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("_topBarStatusClient")) -Message "SessionViewModel must refresh top-bar status through TopBarStatusUpdater."
Assert-True -Condition (-not $sessionViewModelSource.Contains("BuildWorkspaceActionRenderContext(update.ActionDetails)")) -Message "SessionViewModel must let TopBarStatusUpdater project top-bar action details."

foreach ($renderContextBuilderSignal in @(
    "internal sealed class WorkspaceActionRenderContextBuilder",
    "IWorkspaceCommandStateClient workspaceCommandStateClient",
    "ISessionCommandStateClient sessionCommandStateClient",
    "TopBarStatusUpdater topBarStatusUpdater",
    "BuildGateSnapshot(WorkspaceActionRenderState state)",
    "BuildTopBarStatusRequest(WorkspaceActionRenderState state)",
    "BuildContext(",
    "new WorkspaceCommandGateRequest(",
    "_sessionCommandStateClient.BuildGateSnapshot(",
    "_topBarStatusUpdater.BuildActionDetails(BuildTopBarStatusRequest(state))",
    "internal sealed record WorkspaceActionRenderState",
    "internal sealed record WorkspaceActionRenderContext"
)) {
    Assert-Contains -Text $workspaceActionRenderContextBuilder -Needle $renderContextBuilderSignal -Message "WorkspaceActionRenderContextBuilder contract missing: $renderContextBuilderSignal"
}
Assert-Contains -Text $sessionViewModelSource -Needle "new WorkspaceActionRenderContextBuilder(" -Message "SessionViewModel must compose action render contexts through WorkspaceActionRenderContextBuilder."
Assert-Contains -Text $sessionViewModelSource -Needle "_workspaceShellStateAccessor.BuildActionRenderState" -Message "SessionViewModel must provide a single render state snapshot through WorkspaceShellStateAccessor."
Assert-True -Condition (-not $sessionViewModelSource.Contains("BuildWorkspaceActionGateSnapshot")) -Message "SessionViewModel must build workspace action gates through WorkspaceActionRenderContextBuilder."
Assert-True -Condition (-not $sessionViewModelSource.Contains("BuildWorkspaceActionRenderContext")) -Message "SessionViewModel must build action render contexts through WorkspaceActionRenderContextBuilder."
Assert-True -Condition (-not $sessionViewModelSource.Contains("new WorkspaceCommandGateRequest(")) -Message "SessionViewModel must not construct workspace command gate requests directly."
Assert-True -Condition (-not $sessionViewModelSource.Contains("internal sealed record WorkspaceActionRenderContext")) -Message "WorkspaceActionRenderContext must live with WorkspaceActionRenderContextBuilder."

foreach ($viewStateBuilderSignal in @(
    "internal sealed class WorkspaceViewStateBuilder",
    "BuildDiscoveryBrowserRequest",
    "BuildManualConnectionRequest",
    "BuildCrossNetworkConnectionRequest",
    "BuildDashboardMetricsRequest",
    "BuildCommandGateState",
    "BuildActionRenderState",
    "DiscoveryBrowserRequest",
    "ManualConnectionRequest",
    "CrossNetworkConnectionRequest",
    "DashboardMetricsRequest",
    "WorkspaceCommandGateState",
    "WorkspaceActionRenderState"
)) {
    Assert-Contains -Text $workspaceViewStateBuilder -Needle $viewStateBuilderSignal -Message "WorkspaceViewStateBuilder contract missing: $viewStateBuilderSignal"
}
foreach ($sessionViewModelViewStateSignal in @(
    "new WorkspaceViewStateBuilder()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelViewStateSignal -Message "SessionViewModel must delegate request/state construction through WorkspaceViewStateBuilder: $sessionViewModelViewStateSignal"
}
Assert-Contains -Text $discoveryBrowserActions -Needle "_viewStateBuilder.BuildDiscoveryBrowserRequest(" -Message "DiscoveryBrowserActions must build browser requests through WorkspaceViewStateBuilder."
Assert-Contains -Text $crossNetworkConnectionActions -Needle "_viewStateBuilder.BuildCrossNetworkConnectionRequest(" -Message "CrossNetworkConnectionActions must build cross-network requests through WorkspaceViewStateBuilder."
Assert-Contains -Text $connectionWorkspaceActions -Needle "_viewStateBuilder.BuildManualConnectionRequest(" -Message "ConnectionWorkspaceActions must build manual connection requests through WorkspaceViewStateBuilder."
foreach ($workspaceShellStateAccessorViewStateSignal in @(
    "_viewStateBuilder.BuildDashboardMetricsRequest(",
    "_viewStateBuilder.BuildCommandGateState(",
    "_viewStateBuilder.BuildActionRenderState("
)) {
    Assert-Contains -Text $workspaceShellStateAccessor -Needle $workspaceShellStateAccessorViewStateSignal -Message "WorkspaceShellStateAccessor must build shell state through WorkspaceViewStateBuilder: $workspaceShellStateAccessorViewStateSignal"
}
foreach ($sessionViewModelDirectViewStateConstructionPattern in @(
    "new\s+DiscoveryBrowserRequest\s*\(",
    "new\s+ManualConnectionRequest\s*\(",
    "new\s+CrossNetworkConnectionRequest\s*\(",
    "BuildDashboardMetricsRequest\(\)\s*=>",
    "BuildWorkspaceCommandGateState\(\)\s*=>",
    "BuildWorkspaceActionRenderState\(\)\s*=>",
    "_workspaceViewStateBuilder\.BuildDashboardMetricsRequest\(",
    "_workspaceViewStateBuilder\.BuildCommandGateState\(",
    "_workspaceViewStateBuilder\.BuildActionRenderState\("
)) {
    Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, $sessionViewModelDirectViewStateConstructionPattern)) -Message "SessionViewModel must not construct request/state snapshots directly: $sessionViewModelDirectViewStateConstructionPattern"
}

foreach ($workspaceShellStateAccessorSignal in @(
    "internal sealed class WorkspaceShellStateAccessor",
    "WorkspaceViewStateBuilder viewStateBuilder",
    "Func<EngineConnectionState> getConnectionState",
    "Func<int> getTransferTaskCount",
    "Func<bool> getIsBusy",
    "Func<FeatureEntry> getSelectedFeature",
    "Func<ConnectionWorkspaceValidatedState> getValidatedState",
    "BuildDashboardMetricsRequest()",
    "_viewStateBuilder.BuildDashboardMetricsRequest(",
    "_getTransferTaskCount()",
    "BuildCommandGateState()",
    "_viewStateBuilder.BuildCommandGateState(",
    "_getValidatedState()",
    "BuildActionRenderState()",
    "var selectedFeature = _getSelectedFeature()",
    "_viewStateBuilder.BuildActionRenderState(",
    "selectedFeature.Title"
)) {
    Assert-Contains -Text $workspaceShellStateAccessor -Needle $workspaceShellStateAccessorSignal -Message "WorkspaceShellStateAccessor contract missing: $workspaceShellStateAccessorSignal"
}
foreach ($sessionViewModelShellStateAccessorSignal in @(
    "new WorkspaceShellStateAccessor(",
    "() => FileTransferQueue.Count",
    "() => _connectionInputCoordinator.ValidatedState",
    "_workspaceShellStateAccessor.BuildCommandGateState",
    "_workspaceShellStateAccessor.BuildDashboardMetricsRequest",
    "_workspaceShellStateAccessor.BuildActionRenderState"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelShellStateAccessorSignal -Message "SessionViewModel must source shell state through WorkspaceShellStateAccessor: $sessionViewModelShellStateAccessorSignal"
}

foreach ($shellRefreshCoordinatorSignal in @(
    "internal sealed class WorkspaceShellRefreshCoordinator",
    "WorkspaceCommandRegistry commandRegistry",
    "WorkspaceActionSurfaceLoader actionSurfaceLoader",
    "WorkspaceActionRenderContextBuilder renderContextBuilder",
    "DashboardMetricsUpdater dashboardMetricsUpdater",
    "TopBarStatusUpdater topBarStatusUpdater",
    "Func<DashboardMetricsRequest> buildDashboardMetricsRequest",
    "Func<WorkspaceActionRenderState> buildActionRenderState",
    "Action<string> notifyPropertyChanged",
    "IReadOnlyList<string> selectedFeaturePropertyNames",
    "RefreshCommandStates",
    "ApplyWorkspaceInputChange",
    "RefreshSelectedFeatureState",
    "RefreshConnectionState",
    "RefreshShellRuntimeState",
    "LoadWorkspaceActions",
    "RefreshTopBarStatus",
    "RefreshDashboardMetrics",
    "_commandRegistry.RefreshAll()",
    "_actionSurfaceLoader.RefreshDynamicSurfaces(",
    "_actionSurfaceLoader.LoadInitialSurfaces(",
    "_dashboardMetricsUpdater.Refresh(_buildDashboardMetricsRequest())",
    "_topBarStatusUpdater.Refresh(",
    "foreach (var propertyName in _selectedFeaturePropertyNames)",
    "_notifyPropertyChanged(_connectionStatusPropertyName)"
)) {
    Assert-Contains -Text $workspaceShellRefreshCoordinator -Needle $shellRefreshCoordinatorSignal -Message "WorkspaceShellRefreshCoordinator contract missing: $shellRefreshCoordinatorSignal"
}
foreach ($shellNotificationCatalogSignal in @(
    "internal static class WorkspaceShellNotificationCatalog",
    "public static IReadOnlyList<string> SelectedFeaturePropertyNames",
    "nameof(SessionViewModel.IsDeviceDiscoverySelected)",
    "nameof(SessionViewModel.IsUsbManagementSelected)",
    "nameof(SessionViewModel.IsFileTransferSelected)",
    "nameof(SessionViewModel.IsRemoteDesktopSelected)",
    "nameof(SessionViewModel.IsQuantumSelected)",
    "nameof(SessionViewModel.IsSystemMonitorSelected)",
    "nameof(SessionViewModel.IsSettingsSelected)",
    "public static string ConnectionStatusPropertyName",
    "nameof(SessionViewModel.ConnectionStatus)"
)) {
    Assert-Contains -Text $workspaceShellNotificationCatalog -Needle $shellNotificationCatalogSignal -Message "WorkspaceShellNotificationCatalog contract missing: $shellNotificationCatalogSignal"
}
foreach ($sessionViewModelShellRefreshSignal in @(
    "WorkspaceShellNotificationCatalog.SelectedFeaturePropertyNames",
    "WorkspaceShellNotificationCatalog.ConnectionStatusPropertyName",
    "_workspaceShellRefreshCoordinator.RefreshCommandStates();",
    "_workspaceShellRefreshCoordinator.ApplyWorkspaceInputChange(resetInput);",
    "_workspaceShellRefreshCoordinator.RefreshSelectedFeatureState();",
    "_workspaceShellRefreshCoordinator.RefreshConnectionState();",
    "_workspaceShellRefreshCoordinator.RefreshShellRuntimeState();",
    "_workspaceShellRefreshCoordinator.RefreshDashboardMetrics();",
    "_workspaceShellRefreshCoordinator.LoadWorkspaceActions();",
    "_workspaceShellRefreshCoordinator.RefreshTopBarStatus();"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelShellRefreshSignal -Message "SessionViewModel must delegate shell refresh cadence through WorkspaceShellRefreshCoordinator: $sessionViewModelShellRefreshSignal"
}
foreach ($sessionViewModelDirectShellRefreshSignal in @(
    "nameof(IsDeviceDiscoverySelected)",
    "nameof(IsUsbManagementSelected)",
    "nameof(IsFileTransferSelected)",
    "nameof(IsRemoteDesktopSelected)",
    "nameof(IsQuantumSelected)",
    "nameof(IsSystemMonitorSelected)",
    "nameof(IsSettingsSelected)",
    "nameof(ConnectionStatus)",
    "_workspaceCommandRegistry.RefreshAll()",
    "_workspaceActionSurfaceLoader.RefreshDynamicSurfaces(",
    "_workspaceActionSurfaceLoader.LoadInitialSurfaces(",
    "_topBarStatusUpdater.Refresh("
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectShellRefreshSignal)) -Message "SessionViewModel must not own shell refresh cadence directly: $sessionViewModelDirectShellRefreshSignal"
}

foreach ($sessionStatusSignal in @(
    "public interface ISessionStatusClient",
    "public sealed class SessionStatusClient : ISessionStatusClient",
    "internal sealed class SessionEngineActions",
    "internal sealed class SessionEngineStateProjector",
    "SessionStatusAction",
    "BuildInitialStatusMessage",
    "BuildPendingStatus",
    "BuildCompletedStatus",
    "BuildEngineStateStatus",
    "DefaultInitialStatusMessage",
    "BuildDefaultPendingStatus",
    "BuildDefaultCompletedStatus",
    "BuildDefaultEngineStateStatus",
    "new SessionStatusClient()",
    "_sessionStatusClient.BuildInitialStatusMessage()",
    "_sessionEngineActions.ConnectAsync()",
    "_sessionEngineActions.DisconnectAsync()",
    "_sessionEngineActions.SendHeartbeatAsync()",
    "_sessionEngineStateProjector.Apply(newState)",
    "_sessionStatusClient.BuildPendingStatus(action)",
    "_sessionStatusClient.BuildCompletedStatus(action)",
    "_sessionStatusClient.BuildEngineStateStatus(state)"
)) {
    Assert-Contains -Text ($sessionStatus + $sessionViewModel + $mainWindow) -Needle $sessionStatusSignal -Message "Session status service signal missing: $sessionStatusSignal"
}

foreach ($sessionEngineActionsSignal in @(
    "internal sealed class SessionEngineActions",
    "IEngineClient engineClient",
    "WorkspaceBusyCoordinator busyCoordinator",
    "ISessionStatusClient sessionStatusClient",
    "Action<string> setStatusMessage",
    "ConnectAsync()",
    "RunAsync(SessionStatusAction.Connect, _engineClient.ConnectAsync)",
    "DisconnectAsync()",
    "RunAsync(SessionStatusAction.Disconnect, _engineClient.DisconnectAsync)",
    "SendHeartbeatAsync()",
    "RunAsync(SessionStatusAction.Heartbeat, _engineClient.SendHeartbeatAsync)",
    "_busyCoordinator.RunAsync(WorkspaceErrorScope.Session",
    "_setStatusMessage(_sessionStatusClient.BuildPendingStatus(action))",
    "_setStatusMessage(_sessionStatusClient.BuildCompletedStatus(action))"
)) {
    Assert-Contains -Text $sessionEngineActions -Needle $sessionEngineActionsSignal -Message "SessionEngineActions contract missing: $sessionEngineActionsSignal"
}
foreach ($sessionViewModelEngineActionSignal in @(
    "new SessionEngineActions(",
    "_sessionEngineActions.ConnectAsync()",
    "_sessionEngineActions.DisconnectAsync()",
    "_sessionEngineActions.SendHeartbeatAsync()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelEngineActionSignal -Message "SessionViewModel must delegate session engine actions through SessionEngineActions: $sessionViewModelEngineActionSignal"
}
foreach ($sessionViewModelDirectEngineActionSignal in @(
    "RunSessionEngineActionAsync",
    "_workspaceBusyCoordinator.RunAsync(WorkspaceErrorScope.Session",
    "_sessionStatusClient.BuildPendingStatus(action)",
    "_sessionStatusClient.BuildCompletedStatus(action)"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectEngineActionSignal)) -Message "SessionViewModel must not compose session engine lifecycle directly: $sessionViewModelDirectEngineActionSignal"
}
foreach ($sessionEngineStateProjectorSignal in @(
    "internal sealed class SessionEngineStateProjector",
    "ISessionStatusClient sessionStatusClient",
    "Action<EngineConnectionState> setConnectionState",
    "Action<string> setStatusMessage",
    "Apply(EngineConnectionState state)",
    "_setConnectionState(state)",
    "_setStatusMessage(_sessionStatusClient.BuildEngineStateStatus(state))"
)) {
    Assert-Contains -Text $sessionEngineStateProjector -Needle $sessionEngineStateProjectorSignal -Message "SessionEngineStateProjector contract missing: $sessionEngineStateProjectorSignal"
}
foreach ($sessionViewModelEngineStateSignal in @(
    "new SessionEngineStateProjector(",
    "_sessionEngineStateProjector.Apply(newState)"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelEngineStateSignal -Message "SessionViewModel must project engine state through SessionEngineStateProjector: $sessionViewModelEngineStateSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("_sessionStatusClient.BuildEngineStateStatus(newState)")) -Message "SessionViewModel must project engine-state status through SessionEngineStateProjector."

foreach ($viewModelSessionStatusLiteral in @(
    '_statusMessage = "Idle"',
    'StatusMessage = "Connecting..."',
    'StatusMessage = "Connected"',
    'StatusMessage = "Disconnecting..."',
    'StatusMessage = "Disconnected"',
    'StatusMessage = "Heartbeat acknowledged"',
    'StatusMessage = newState switch'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelSessionStatusLiteral)) -Message "SessionViewModel must source session status text from SessionStatusClient instead of literal: $viewModelSessionStatusLiteral"
}

foreach ($sessionCommandStateSignal in @(
    "public interface ISessionCommandStateClient",
    "public sealed class SessionCommandStateClient : ISessionCommandStateClient",
    "CanConnect",
    "CanDisconnect",
    "CanSendHeartbeat",
    "BuildGateSnapshot",
    "SessionCommandGateSnapshot",
    "EngineConnectionState.Disconnected",
    "EngineConnectionState.Connected",
    "EngineConnectionState.Reconnecting",
    "new SessionCommandStateClient()",
    "_workspaceCommandAvailability.CanConnect()",
    "_sessionCommandStateClient.CanConnect(state.ConnectionState, state.IsBusy)",
    "_sessionCommandStateClient.CanDisconnect(state.ConnectionState, state.IsBusy)",
    "_sessionCommandStateClient.CanSendHeartbeat(state.ConnectionState, state.IsBusy)",
    "_sessionCommandStateClient.BuildGateSnapshot(",
    "state.ConnectionState"
)) {
    Assert-Contains -Text ($sessionCommandState + $sessionViewModel + $workspaceCommandGateCoordinator + $workspaceActionRenderContextBuilder) -Needle $sessionCommandStateSignal -Message "Session command state service signal missing: $sessionCommandStateSignal"
}

foreach ($viewModelSessionCommandGate in @(
    "ConnectionState == EngineConnectionState.Disconnected",
    "ConnectionState == EngineConnectionState.Connected || ConnectionState == EngineConnectionState.Reconnecting",
    "ConnectionState == EngineConnectionState.Connected"
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelSessionCommandGate)) -Message "SessionViewModel must source connect/disconnect/heartbeat enablement from SessionCommandStateClient instead of inline gate: $viewModelSessionCommandGate"
}

foreach ($workspaceCommandStateSignal in @(
    "public interface IWorkspaceCommandStateClient",
    "public sealed class WorkspaceCommandStateClient : IWorkspaceCommandStateClient",
    "WorkspaceCommandGateRequest",
    "SessionCommandGateSnapshot",
    "SessionGates",
    "CanUseDeviceDiscovery",
    "CanUseDeviceDiscoveryAction",
    "CanUseCrossNetworkConnection",
    "CanUseCrossNetworkConnectionAction",
    "CanUseWorkspaceFeature",
    "BuildActionGateSnapshot",
    "new WorkspaceCommandStateClient()",
    "WorkspaceCommandGateCoordinator",
    "WorkspaceCommandAvailability",
    "WorkspaceCommandGateState",
    "_workspaceCommandAvailability.CanUseDiscoveryBrowser()",
    "CanUseDeviceDiscoveryAction(",
    "_workspaceCommandStateClient.CanUseDeviceDiscoveryAction(",
    "_workspaceCommandStateClient.CanUseCrossNetworkConnection(",
    "CanUseCrossNetworkConnectionAction(",
    "_workspaceCommandStateClient.CanUseCrossNetworkConnectionAction(",
    "CanUseSelectedWorkspaceFeature(",
    "_workspaceCommandStateClient.CanUseWorkspaceFeature(",
    "_workspaceCommandStateClient.BuildActionGateSnapshot(",
    "new WorkspaceCommandGateRequest("
)) {
    Assert-Contains -Text ($workspaceCommandState + $sessionViewModel + $mainWindow) -Needle $workspaceCommandStateSignal -Message "Workspace command state service signal missing: $workspaceCommandStateSignal"
}

foreach ($workspaceGateCoordinatorSignal in @(
    "internal sealed class WorkspaceCommandGateCoordinator",
    "ISessionCommandStateClient sessionCommandStateClient",
    "IFeatureCatalogClient featureCatalogClient",
    "IWorkspaceCommandStateClient workspaceCommandStateClient",
    "IManualConnectionClient manualConnectionClient",
    "ICrossNetworkConnectionClient crossNetworkConnectionClient",
    "IDiscoveryClient discoveryClient",
    "IPairingMaterialClient pairingMaterialClient",
    "IConnectionWorkspaceStateClient connectionWorkspaceStateClient",
    "IsFeatureSelected(FeatureEntry selectedFeature, FeatureEntryId featureId)",
    "_featureCatalogClient.IsSelected(selectedFeature, featureId)",
    "_sessionCommandStateClient.CanConnect(state.ConnectionState, state.IsBusy)",
    "_workspaceCommandStateClient.CanUseDeviceDiscovery(",
    "_manualConnectionClient.CanPrepareTarget(",
    "_crossNetworkConnectionClient.CanScanQrCode(state.CrossNetworkQrInput)",
    "_crossNetworkConnectionClient.CanCopyCode(state.CrossNetworkGeneratedCode)",
    "_crossNetworkConnectionClient.CanConnectWithCode(state.CrossNetworkCodeInput)",
    "_discoveryClient.CanParseAdvertisement(",
    "_pairingMaterialClient.CanValidate(state.PairingConnectionCode)",
    "_connectionWorkspaceStateClient.CanPreparePreflight(",
    "_workspaceCommandStateClient.CanUseDeviceDiscoveryAction(",
    "_workspaceCommandStateClient.CanUseCrossNetworkConnectionAction(",
    "_workspaceCommandStateClient.CanUseWorkspaceFeature(",
    "internal sealed record WorkspaceCommandGateState("
)) {
    Assert-Contains -Text $workspaceCommandGateCoordinator -Needle $workspaceGateCoordinatorSignal -Message "WorkspaceCommandGateCoordinator contract missing: $workspaceGateCoordinatorSignal"
}

foreach ($workspaceCommandAvailabilitySignal in @(
    "internal sealed class WorkspaceCommandAvailability",
    "WorkspaceCommandGateCoordinator coordinator",
    "Func<WorkspaceCommandGateState> buildState",
    "private WorkspaceCommandGateState BuildState() => _buildState();",
    "_coordinator.CanConnect(BuildState())",
    "_coordinator.CanDisconnect(BuildState())",
    "_coordinator.CanSendHeartbeat(BuildState())",
    "_coordinator.CanUseDiscoveryBrowser(BuildState())",
    "_coordinator.CanPrepareManualConnection(BuildState())",
    "_coordinator.CanUseCrossNetworkConnection(BuildState())",
    "_coordinator.CanScanQrCode(BuildState())",
    "_coordinator.CanCopyConnectionCode(BuildState())",
    "_coordinator.CanConnectConnectionCode(BuildState())",
    "_coordinator.CanParseAdvertisement(BuildState())",
    "_coordinator.CanValidatePairingCode(BuildState())",
    "_coordinator.CanPrepareConnection(BuildState())",
    "_coordinator.CanRefreshUsbManagement(BuildState())",
    "_coordinator.CanRunCoreDiagnostics(BuildState())",
    "_coordinator.CanRefreshFileTransfer(BuildState())",
    "_coordinator.CanRefreshRemoteDesktop(BuildState())",
    "_coordinator.CanRefreshSystemMonitor(BuildState())",
    "_coordinator.CanRefreshSettings(BuildState())"
)) {
    Assert-Contains -Text $workspaceCommandAvailability -Needle $workspaceCommandAvailabilitySignal -Message "WorkspaceCommandAvailability contract missing: $workspaceCommandAvailabilitySignal"
}

foreach ($sessionViewModelGateSignal in @(
    "new WorkspaceCommandGateCoordinator(",
    "new WorkspaceCommandAvailability(",
    "_workspaceShellStateAccessor.BuildCommandGateState",
    "_workspaceCommandAvailability.CanConnect()",
    "_workspaceCommandAvailability.CanDisconnect()",
    "_workspaceCommandAvailability.CanSendHeartbeat()",
    "_workspaceCommandGateCoordinator.IsFeatureSelected(SelectedFeature, featureId)",
    "_workspaceCommandAvailability.CanPrepareManualConnection()",
    "_workspaceCommandAvailability.CanUseCrossNetworkConnection()",
    "_workspaceCommandAvailability.CanPrepareConnection()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelGateSignal -Message "SessionViewModel must delegate command gates through WorkspaceCommandGateCoordinator: $sessionViewModelGateSignal"
}

foreach ($sessionViewModelDirectGateSignal in @(
    "_workspaceCommandGateCoordinator.CanConnect(",
    "_workspaceCommandGateCoordinator.CanDisconnect(",
    "_workspaceCommandGateCoordinator.CanSendHeartbeat(",
    "_workspaceCommandGateCoordinator.CanUseDiscoveryBrowser(",
    "_workspaceCommandGateCoordinator.CanPrepareManualConnection(",
    "_workspaceCommandGateCoordinator.CanUseCrossNetworkConnection(",
    "_workspaceCommandGateCoordinator.CanScanQrCode(",
    "_workspaceCommandGateCoordinator.CanCopyConnectionCode(",
    "_workspaceCommandGateCoordinator.CanConnectConnectionCode(",
    "_workspaceCommandGateCoordinator.CanParseAdvertisement(",
    "_workspaceCommandGateCoordinator.CanValidatePairingCode(",
    "_workspaceCommandGateCoordinator.CanPrepareConnection(",
    "_workspaceCommandGateCoordinator.CanRefreshUsbManagement(",
    "_workspaceCommandGateCoordinator.CanRunCoreDiagnostics(",
    "_workspaceCommandGateCoordinator.CanRefreshFileTransfer(",
    "_workspaceCommandGateCoordinator.CanRefreshRemoteDesktop(",
    "_workspaceCommandGateCoordinator.CanRefreshSystemMonitor(",
    "_workspaceCommandGateCoordinator.CanRefreshSettings(",
    "_sessionCommandStateClient.CanConnect(",
    "_sessionCommandStateClient.CanDisconnect(",
    "_sessionCommandStateClient.CanSendHeartbeat(",
    "_workspaceCommandStateClient.CanUseDeviceDiscovery(",
    "_workspaceCommandStateClient.CanUseCrossNetworkConnection(",
    "_workspaceCommandStateClient.CanUseDeviceDiscoveryAction(",
    "_workspaceCommandStateClient.CanUseCrossNetworkConnectionAction(",
    "_workspaceCommandStateClient.CanUseWorkspaceFeature(",
    "_manualConnectionClient.CanPrepareTarget(",
    "_crossNetworkConnectionClient.CanScanQrCode(",
    "_crossNetworkConnectionClient.CanCopyCode(",
    "_crossNetworkConnectionClient.CanConnectWithCode(",
    "_discoveryClient.CanParseAdvertisement(",
    "_pairingMaterialClient.CanValidate("
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectGateSignal)) -Message "SessionViewModel must not own command gate composition directly: $sessionViewModelDirectGateSignal"
}

foreach ($viewModelWorkspaceCommandGate in @(
    "!IsBusy && IsDeviceDiscoverySelected",
    "!IsBusy && IsUsbManagementSelected",
    "!IsBusy && IsFileTransferSelected",
    "!IsBusy && IsRemoteDesktopSelected",
    "!IsBusy && IsQuantumSelected",
    "!IsBusy && IsSystemMonitorSelected",
    "!IsBusy && IsSettingsSelected"
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelWorkspaceCommandGate)) -Message "SessionViewModel must source workspace feature command enablement from WorkspaceCommandStateClient instead of inline gate: $viewModelWorkspaceCommandGate"
}

Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "CanUseDeviceDiscovery\(\)\s*&&")) -Message "SessionViewModel must let WorkspaceCommandStateClient compose Device Discovery action readiness with busy/selection state."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "CanUseCrossNetworkConnection\(\)\s*&&")) -Message "SessionViewModel must let WorkspaceCommandStateClient compose Cross-network action readiness with busy/selection state."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "new WorkspaceCommandGateRequest\([\s\S]*?CanConnect\(\)")) -Message "SessionViewModel must pass SessionCommandStateClient.BuildGateSnapshot into workspace action gates instead of scattered session command booleans."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "new WorkspaceCommandGateRequest\([\s\S]*?CanDisconnect\(\)")) -Message "SessionViewModel must pass SessionCommandStateClient.BuildGateSnapshot into workspace action gates instead of scattered session command booleans."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "new WorkspaceCommandGateRequest\([\s\S]*?CanSendHeartbeat\(\)")) -Message "SessionViewModel must pass SessionCommandStateClient.BuildGateSnapshot into workspace action gates instead of scattered session command booleans."

foreach ($workspaceActionRoleSignal in @(
    "BuildInitialSurfaces",
    "BuildDynamicRefreshSurfaces",
    "BuildResolvedSnapshot",
    "WorkspaceActionSurfaceTargets",
    "WorkspaceActionSurfaceLoader",
    "_surfaceTargets.Resolve(surface)",
    "InitialSurfaces",
    "DynamicRefreshSurfaces",
    "_actionCatalogClient.BuildInitialSurfaces()",
    "_actionCatalogClient.BuildDynamicRefreshSurfaces()",
    "_actionCatalogClient.BuildResolvedSnapshot(",
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

foreach ($surfaceTargetsSignal in @(
    "public WorkspaceActionSurfaceTargets(WorkspaceObservableCollections collections)",
    "private WorkspaceActionSurfaceTargets(",
    "collections.SidebarSessionActions",
    "collections.TopBarActions",
    "collections.SessionControlActions",
    "collections.DeviceDiscoveryPrimaryActions",
    "collections.CrossNetworkCodeConnectActions",
    "collections.SettingsMaintenanceActions",
    "WorkspaceActionSurface.SidebarSession",
    "WorkspaceActionSurface.TopBarActions",
    "WorkspaceActionSurface.SettingsMaintenance"
)) {
    Assert-Contains -Text $workspaceActionSurfaceTargets -Needle $surfaceTargetsSignal -Message "WorkspaceActionSurfaceTargets collection-entry contract missing: $surfaceTargetsSignal"
}
Assert-Contains -Text $sessionViewModelSource -Needle "new WorkspaceActionSurfaceTargets(collections)" -Message "SessionViewModel must create action surface targets from WorkspaceObservableCollections."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "new\s+WorkspaceActionSurfaceTargets\s*\(\s*SidebarSessionActions\s*,")) -Message "SessionViewModel must not hand-wire action surface target collection lists."

foreach ($surfaceLoaderSignal in @(
    "internal sealed class WorkspaceActionSurfaceLoader",
    "LoadInitialSurfaces(WorkspaceActionRenderContext renderContext)",
    "RefreshDynamicSurfaces(WorkspaceActionRenderContext renderContext)",
    "LoadSurface(",
    "_actionCatalogClient.BuildInitialSurfaces()",
    "_actionCatalogClient.BuildDynamicRefreshSurfaces()",
    "_actionCatalogClient.BuildResolvedSnapshot(",
    "_surfaceTargets.Resolve(surface)",
    "WorkspaceCollectionProjector.Replace(",
    "_commandRegistry.Resolve(action.CommandId)"
)) {
    Assert-Contains -Text $workspaceActionSurfaceLoader -Needle $surfaceLoaderSignal -Message "WorkspaceActionSurfaceLoader contract missing: $surfaceLoaderSignal"
}

foreach ($shellSurfaceLoaderSignal in @(
    "_actionSurfaceLoader.LoadInitialSurfaces(",
    "_actionSurfaceLoader.RefreshDynamicSurfaces(",
    "_renderContextBuilder.BuildContext(_buildActionRenderState())"
)) {
    Assert-Contains -Text $workspaceShellRefreshCoordinator -Needle $shellSurfaceLoaderSignal -Message "WorkspaceShellRefreshCoordinator action surface loader usage missing: $shellSurfaceLoaderSignal"
}
Assert-Contains -Text $topBarStatusUpdater -Needle "_actionSurfaceLoader.LoadSurface(" -Message "TopBarStatusUpdater must load the top-bar action surface."

Assert-True -Condition (-not $sessionViewModel.Contains("string actionKey")) -Message "SessionViewModel must resolve workspace actions by catalog role ids, not action-key strings."
Assert-True -Condition (-not $sessionViewModel.Contains("ResolveWorkspaceActionCommand(surface")) -Message "SessionViewModel must not pass surface/key pairs to action command resolution."
Assert-True -Condition (-not $sessionViewModelSource.Contains("ResolveWorkspaceActionCommand")) -Message "SessionViewModel must resolve workspace action commands through WorkspaceCommandRegistry."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "WorkspaceActionCommandId\s+commandId\)[\s\S]*?commandId switch")) -Message "SessionViewModel must not own a WorkspaceActionCommandId command switch."
Assert-True -Condition (-not $sessionViewModel.Contains("ResolveWorkspaceActionEnabled")) -Message "SessionViewModel must delegate workspace action gate resolution to WorkspaceActionCatalogClient."
Assert-True -Condition (-not $sessionViewModel.Contains("ResolveWorkspaceActionDetail")) -Message "SessionViewModel must delegate workspace action detail resolution to WorkspaceActionCatalogClient."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceActionCatalogClient.ResolveEnabled(")) -Message "SessionViewModel must use WorkspaceActionCatalogClient.BuildResolvedSnapshot instead of resolving action gates inline."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceActionCatalogClient.ResolveDetail(")) -Message "SessionViewModel must use WorkspaceActionCatalogClient.BuildResolvedSnapshot instead of resolving action details inline."
Assert-True -Condition (-not $sessionViewModelSource.Contains("GetWorkspaceActionSurfaceTarget")) -Message "SessionViewModel must resolve workspace action surface targets through WorkspaceActionSurfaceTargets."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "WorkspaceActionSurface\.[A-Za-z]+ =>")) -Message "SessionViewModel must not own a WorkspaceActionSurface target switch."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceActionSurfaceTargets.Resolve(surface)")) -Message "SessionViewModel must load action surface targets through WorkspaceActionSurfaceLoader."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceActionCatalogClient.BuildInitialSurfaces()")) -Message "SessionViewModel must load initial action surfaces through WorkspaceActionSurfaceLoader."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceActionCatalogClient.BuildDynamicRefreshSurfaces()")) -Message "SessionViewModel must refresh dynamic action surfaces through WorkspaceActionSurfaceLoader."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceActionCatalogClient.BuildResolvedSnapshot(")) -Message "SessionViewModel must resolve action surfaces through WorkspaceActionSurfaceLoader."
Assert-True -Condition (-not $sessionViewModel.Contains("LoadWorkspaceActionSurface(WorkspaceActionSurface.SidebarSession,")) -Message "SessionViewModel must source the initial workspace action surface plan from WorkspaceActionCatalogClient."
Assert-True -Condition (-not $sessionViewModel.Contains("LoadWorkspaceActionSurface(WorkspaceActionSurface.UsbManagementHeader,")) -Message "SessionViewModel must source the dynamic workspace action refresh plan from WorkspaceActionCatalogClient."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "BuildResolvedSnapshot\(\s*new WorkspaceActionCatalogRequest\(surface\),\s*BuildWorkspaceActionGateSnapshot\(")) -Message "SessionViewModel must build workspace action gates once in WorkspaceActionRenderContext, not per surface."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "BuildResolvedSnapshot\(\s*new WorkspaceActionCatalogRequest\(surface\),[\s\S]{0,250}_topBarStatusClient\.BuildStatusUpdate\(")) -Message "SessionViewModel must build top-bar action details once in WorkspaceActionRenderContext, not per surface."
Assert-True -Condition (-not $sessionViewModel.Contains("GetTopBarStatusValue")) -Message "SessionViewModel must delegate top-bar status lookup to TopBarStatusClient.BuildResolvedStatusSnapshot."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_topBarStatusClient.ResolveStatusValue(")) -Message "SessionViewModel must use TopBarStatusClient.BuildResolvedStatusSnapshot instead of resolving top-bar scalar values inline."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_topBarStatusClient.BuildDefaultStatusValue(")) -Message "SessionViewModel must use TopBarStatusClient.BuildResolvedStatusSnapshot instead of selecting top-bar defaults inline."
Assert-True -Condition (-not $sessionViewModelSource.Contains("new(TopBarNotificationsStatus, TopBarThemeStatus)")) -Message "SessionViewModel must ask TopBarStatusClient for top-bar workspace action details."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_topBarResolvedStatusSnapshot")) -Message "SessionViewModel must use TopBarStatusClient.BuildStatusUpdate instead of caching top-bar resolved status locally."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_topBarStatusClient.BuildWorkspaceActionDetailSnapshot(")) -Message "SessionViewModel must use TopBarStatusClient.BuildStatusUpdate for top-bar action details."

foreach ($topBarLabelLookup in @(
    'GetTopBarStatusValue(snapshot, "Connection"',
    'GetTopBarStatusValue(snapshot, "FPS / Diagnostics"',
    'GetTopBarStatusValue(snapshot, "Notifications"',
    'GetTopBarStatusValue(snapshot, "Theme"'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($topBarLabelLookup)) -Message "SessionViewModel must map top-bar scalar status by TopBarStatusSlot instead of display label: $topBarLabelLookup"
}

foreach ($viewModelTopBarDefaultLiteral in @(
    '_performanceStatus = "Nominal"',
    '_topBarConnectionStatus = "Disconnected"',
    '_topBarDiagnosticsStatus = "Nominal"',
    '_topBarNotificationsStatus = "Off"',
    '_topBarThemeStatus = "System"',
    'TopBarStatusSlot.Notifications, "Off"',
    'TopBarStatusSlot.Theme, "System"'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelTopBarDefaultLiteral)) -Message "SessionViewModel must source top-bar default status values from TopBarStatusClient instead of literal: $viewModelTopBarDefaultLiteral"
}

foreach ($connectionStateSignal in @(
    "public interface IConnectionWorkspaceStateClient",
    "public sealed class ConnectionWorkspaceStateClient : IConnectionWorkspaceStateClient",
    "BuildInitialStatusPatch",
    "DefaultReadyStatus",
    "BuildInputResetPatch",
    "BuildInputInvalidatedState",
    "BuildDiscoveryBrowserValidatedState",
    "BuildDiscoveryPeerValidatedState",
    "BuildPairingValidatedState",
    "BuildPairingInputResetState",
    "BuildDiscoveryBrowserResultPatch",
    "BuildManualTargetPreparedPatch",
    "BuildCrossNetworkPreparedPatch",
    "BuildDiscoveryPeerValidatedPatch",
    "BuildPairingValidatedPatch",
    "BuildPreflightReadiness",
    "BuildPreflightPreparedPatch",
    "ConnectionWorkspaceResetReason",
    "ConnectionWorkspaceStatusPatch",
    "WorkspaceStatusPatchApplier",
    "_statusPatchApplier.Apply(",
    "ConnectionWorkspaceInputCoordinator",
    "ConnectionWorkspaceResultProjector",
    "_connectionInputCoordinator.ValidatedState",
    "ApplyInputInvalidation",
    "ConnectionWorkspaceValidatedState",
    "ConnectionWorkspacePreflightReadiness",
    "DiscoveryInputChanged",
    "ManualTargetInputChanged",
    "CrossNetworkInputChanged",
    "PairingInputChanged",
    "PreflightCleared",
    "Parse a Core-validated discovery TXT record before connection preflight.",
    "Validate pairing material before connection preflight.",
    "_connectionWorkspaceStateClient.BuildInitialStatusPatch()",
    "ClearPairingAndPreflight",
    "_connectionWorkspaceStateClient.BuildDiscoveryBrowserValidatedState(snapshot)",
    "_connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedState(peer)",
    "_connectionWorkspaceStateClient.BuildPairingValidatedState(",
    "new ConnectionWorkspaceStateClient()"
)) {
    Assert-Contains -Text ($connectionWorkspaceState + $sessionViewModel + $mainWindow) -Needle $connectionStateSignal -Message "Connection workspace state signal missing: $connectionStateSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("_validatedDiscoveredPeer")) -Message "SessionViewModel must store validated connection material in ConnectionWorkspaceValidatedState."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_validatedPairingMaterial")) -Message "SessionViewModel must store validated connection material in ConnectionWorkspaceValidatedState."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("FfiEngineClient")) -Message "ConnectionWorkspaceStateClient must not call or reference FfiEngineClient."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("WebRTC")) -Message "ConnectionWorkspaceStateClient must not start or own WebRTC adapters."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("signaling")) -Message "ConnectionWorkspaceStateClient must not own signaling side effects."
$inputInvalidatedMatches = [regex]::Matches($connectionWorkspaceInputCoordinator, [regex]::Escape("_connectionWorkspaceStateClient.BuildInputInvalidatedState()"))
Assert-True -Condition ($inputInvalidatedMatches.Count -ge 1) -Message "ConnectionWorkspaceInputCoordinator must centralize input invalidation."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_connectionWorkspaceStateClient.BuildInputInvalidatedState()")) -Message "SessionViewModel must not call BuildInputInvalidatedState directly; use ConnectionWorkspaceInputCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("ConnectionWorkspaceResetReason.")) -Message "SessionViewModel must not own connection workspace reset reasons; use ConnectionWorkspaceInputCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("PairingFacts.Clear()")) -Message "SessionViewModel must not clear pairing facts directly; use ConnectionWorkspaceInputCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("ConnectionPreflightFacts.Clear()")) -Message "SessionViewModel must not clear preflight facts directly; use ConnectionWorkspaceInputCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("ManualConnectionFacts.Clear()")) -Message "SessionViewModel must not clear manual connection facts directly; use ConnectionWorkspaceInputCoordinator."

foreach ($inputCoordinatorSignal in @(
    "internal sealed class ConnectionWorkspaceInputCoordinator",
    "public ConnectionWorkspaceValidatedState ValidatedState { get; private set; }",
    "BuildInputInvalidatedState()",
    "ApplyInputInvalidation",
    "ClearPairingAndPreflight",
    "ResetManualConnectionInput",
    "ResetCrossNetworkInput",
    "ResetPairingInput",
    "ClearConnectionPreflight",
    "ConnectionWorkspaceResetReason.DiscoveryInputChanged",
    "ConnectionWorkspaceResetReason.ManualTargetInputChanged",
    "ConnectionWorkspaceResetReason.CrossNetworkInputChanged",
    "ConnectionWorkspaceResetReason.PairingInputChanged",
    "ConnectionWorkspaceResetReason.PreflightCleared",
    "_pairingFacts.Clear()",
    "_connectionPreflightFacts.Clear()",
    "_manualConnectionFacts.Clear()",
    "_countNotifier.PairingFactsChanged()",
    "_countNotifier.ConnectionPreflightFactsChanged()"
)) {
    Assert-Contains -Text $connectionWorkspaceInputCoordinator -Needle $inputCoordinatorSignal -Message "ConnectionWorkspaceInputCoordinator contract missing: $inputCoordinatorSignal"
}
foreach ($inputResetSignal in @(
    "_connectionInputCoordinator.ResetManualConnectionInput",
    "_connectionInputCoordinator.ResetCrossNetworkInput",
    "_connectionInputCoordinator.ResetPairingInput",
    "_connectionInputCoordinator.InvalidatePairingAndPreflight"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $inputResetSignal -Message "SessionViewModel setter reset path must call input coordinator: $inputResetSignal"
}
foreach ($resultProjectionSignal in @(
    "internal sealed class ConnectionWorkspaceResultProjector",
    "ApplyDiscoveryBrowserResult",
    "ApplyManualTargetPrepared",
    "ApplyCrossNetworkPrepared",
    "ApplyDiscoveryPeerValidated",
    "ApplyPairingValidated",
    "ApplyPreflightPrepared",
    "_connectionInputCoordinator.ApplyValidatedState",
    "_connectionInputCoordinator.ApplyInputInvalidation",
    "_connectionInputCoordinator.ClearPairingAndPreflight",
    "_connectionInputCoordinator.ClearConnectionPreflight",
    "_connectionWorkspaceStateClient.BuildDiscoveryBrowserValidatedState(snapshot)",
    "_connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedState(peer)",
    "_connectionWorkspaceStateClient.BuildPairingValidatedState(",
    "_connectionWorkspaceStateClient.BuildDiscoveryBrowserResultPatch(",
    "_connectionWorkspaceStateClient.BuildManualTargetPreparedPatch(snapshot)",
    "_connectionWorkspaceStateClient.BuildCrossNetworkPreparedPatch(snapshot)",
    "_connectionWorkspaceStateClient.BuildDiscoveryPeerValidatedPatch(peer)",
    "_connectionWorkspaceStateClient.BuildPairingValidatedPatch(material)",
    "_connectionWorkspaceStateClient.BuildPreflightPreparedPatch(snapshot)",
    "WorkspaceCollectionProjector.Replace(",
    "_countNotifier.DiscoveredPeersChanged()",
    "_countNotifier.DiscoveryBrowserFactsChanged()",
    "_countNotifier.ManualConnectionFactsChanged()",
    "_countNotifier.CrossNetworkConnectionFactsChanged()",
    "_countNotifier.PairingFactsChanged()",
    "_countNotifier.ConnectionPreflightFactsChanged()"
)) {
    Assert-Contains -Text $connectionWorkspaceResultProjector -Needle $resultProjectionSignal -Message "ConnectionWorkspaceResultProjector contract missing: $resultProjectionSignal"
}
foreach ($sessionViewModelResultProjectionSignal in @(
    "BuildDiscoveryBrowserValidatedState(snapshot)",
    "BuildDiscoveryPeerValidatedState(peer)",
    "BuildPairingValidatedState(",
    "BuildDiscoveryBrowserResultPatch(",
    "BuildManualTargetPreparedPatch(snapshot)",
    "BuildCrossNetworkPreparedPatch(snapshot)",
    "BuildDiscoveryPeerValidatedPatch(peer)",
    "BuildPairingValidatedPatch(material)",
    "BuildPreflightPreparedPatch(snapshot)",
    "DiscoveredPeers.Clear()",
    "DiscoveredPeers.Add(",
    "WorkspaceCollectionProjector.Replace(DiscoveryBrowserFacts",
    "WorkspaceCollectionProjector.Replace(ManualConnectionFacts",
    "WorkspaceCollectionProjector.Replace(CrossNetworkConnectionFacts",
    "WorkspaceCollectionProjector.Replace(PairingFacts",
    "WorkspaceCollectionProjector.Replace(ConnectionPreflightFacts"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelResultProjectionSignal)) -Message "SessionViewModel must route connection result projection through ConnectionWorkspaceResultProjector: $sessionViewModelResultProjectionSignal"
}
foreach ($inputResetReason in @(
    "ConnectionWorkspaceResetReason.ManualTargetInputChanged",
    "ConnectionWorkspaceResetReason.CrossNetworkInputChanged",
    "ConnectionWorkspaceResetReason.PairingInputChanged",
    "ConnectionWorkspaceResetReason.DiscoveryInputChanged",
    "ConnectionWorkspaceResetReason.PreflightCleared"
)) {
    $matches = [regex]::Matches($connectionWorkspaceInputCoordinator, [regex]::Escape($inputResetReason))
    Assert-True -Condition ($matches.Count -eq 1) -Message "ConnectionWorkspaceInputCoordinator must centralize $inputResetReason in one reset helper."
}

foreach ($workspaceErrorSignal in @(
    "public interface IWorkspaceErrorStatusClient",
    "public sealed class WorkspaceErrorStatusClient : IWorkspaceErrorStatusClient",
    "WorkspaceErrorScope",
    "WorkspaceErrorStatusPatch",
    "ConnectionWorkspacePatch",
    "WorkspaceErrorScope.DeviceDiscovery",
    "WorkspaceErrorScope.UsbManagement",
    "WorkspaceErrorScope.CoreDiagnostics",
    "WorkspaceErrorScope.FileTransfer",
    "WorkspaceErrorScope.RemoteDesktop",
    "WorkspaceErrorScope.SystemMonitor",
    "WorkspaceErrorScope.Settings",
    "new WorkspaceErrorStatusClient()",
    "WorkspaceBusyCoordinator",
    "ReadOnlyWorkspaceRefreshCoordinator",
    "RunAsync(",
    "RefreshReadOnlyWorkspaceAsync",
    "_busyCoordinator.RunAsync(WorkspaceErrorScope",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync",
    "DiscoveryBrowserActions",
    "CrossNetworkConnectionActions",
    "ConnectionWorkspaceActions",
    "_workspaceErrorStatusClient.BuildErrorPatch(errorScope, ex.Message)",
    "WorkspaceStatusPatchApplier",
    "_statusPatchApplier.Apply("
)) {
    Assert-Contains -Text ($workspaceErrorStatus + $sessionViewModel + $mainWindow) -Needle $workspaceErrorSignal -Message "Workspace error routing signal missing: $workspaceErrorSignal"
}

foreach ($workspaceBusyCoordinatorSignal in @(
    "internal sealed class WorkspaceBusyCoordinator",
    "Func<bool> isBusy",
    "Action<bool> setBusy",
    "IWorkspaceErrorStatusClient workspaceErrorStatusClient",
    "RunAsync(",
    "RefreshReadOnlyWorkspaceAsync<TSnapshot>",
    "if (_isBusy())",
    "_setBusy(true)",
    "_setBusy(false)",
    "_statusPatchApplier.Apply(",
    "_workspaceErrorStatusClient.BuildErrorPatch(errorScope, ex.Message)"
)) {
    Assert-Contains -Text $workspaceBusyCoordinator -Needle $workspaceBusyCoordinatorSignal -Message "WorkspaceBusyCoordinator contract missing: $workspaceBusyCoordinatorSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("RunWithBusyState")) -Message "SessionViewModel must route busy/error lifecycles through WorkspaceBusyCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceBusyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery")) -Message "SessionViewModel must route Device Discovery command lifecycles through dedicated action helpers."
foreach ($deviceDiscoveryActionHelperSignal in @(
    "_busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery"
)) {
    Assert-Contains -Text $discoveryBrowserActions -Needle $deviceDiscoveryActionHelperSignal -Message "DiscoveryBrowserActions must use the Device Discovery busy scope."
    Assert-Contains -Text $crossNetworkConnectionActions -Needle $deviceDiscoveryActionHelperSignal -Message "CrossNetworkConnectionActions must use the Device Discovery busy scope."
    Assert-Contains -Text $connectionWorkspaceActions -Needle $deviceDiscoveryActionHelperSignal -Message "ConnectionWorkspaceActions must use the Device Discovery busy scope."
}
foreach ($readOnlyWorkspaceRefreshCoordinatorSignal in @(
    "internal sealed class ReadOnlyWorkspaceRefreshCoordinator",
    "WorkspaceBusyCoordinator busyCoordinator",
    "ICoreDiagnosticsClient coreDiagnosticsClient",
    "IFileTransferWorkspaceClient fileTransferClient",
    "IUsbManagementWorkspaceClient usbManagementClient",
    "IRemoteDesktopWorkspaceClient remoteDesktopClient",
    "ISystemMonitorWorkspaceClient systemMonitorClient",
    "ISettingsWorkspaceClient settingsClient",
    "RunCoreDiagnosticsAsync",
    "RefreshFileTransferAsync",
    "RefreshUsbManagementAsync",
    "RefreshRemoteDesktopAsync",
    "RefreshSystemMonitorAsync",
    "RefreshSettingsAsync",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync<CoreDiagnosticsSnapshot>",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync<FileTransferWorkspaceSnapshot>",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync<UsbManagementWorkspaceSnapshot>",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync<RemoteDesktopWorkspaceSnapshot>",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync<SystemMonitorWorkspaceSnapshot>",
    "_busyCoordinator.RefreshReadOnlyWorkspaceAsync<SettingsWorkspaceSnapshot>"
)) {
    Assert-Contains -Text $readOnlyWorkspaceRefreshCoordinator -Needle $readOnlyWorkspaceRefreshCoordinatorSignal -Message "ReadOnlyWorkspaceRefreshCoordinator contract missing: $readOnlyWorkspaceRefreshCoordinatorSignal"
}
foreach ($readOnlyWorkspaceRefreshActionsSignal in @(
    "internal sealed class ReadOnlyWorkspaceRefreshActions",
    "ReadOnlyWorkspaceRefreshCoordinator refreshCoordinator",
    "ReadOnlyWorkspaceSnapshotHandlers snapshotHandlers",
    "Func<string> getSelectedBitrate",
    "Func<string> getSelectedFramerate",
    "Action<string> setStatusMessage",
    "Action<string> setCoreDiagnosticsStatus",
    "Action<string> setFileTransferStatus",
    "Action<string> setUsbManagementStatus",
    "Action<string> setRemoteDesktopStatus",
    "Action<string> setSystemMonitorStatus",
    "Action<string> setSettingsStatus",
    "RunCoreDiagnosticsAsync()",
    "_refreshCoordinator.RunCoreDiagnosticsAsync(",
    "_snapshotHandlers.ApplyCoreDiagnostics",
    "RefreshFileTransferAsync()",
    "_refreshCoordinator.RefreshFileTransferAsync(",
    "_snapshotHandlers.ApplyFileTransfer",
    "RefreshUsbManagementAsync()",
    "_snapshotHandlers.ApplyUsbManagement",
    "RefreshRemoteDesktopAsync()",
    "_getSelectedBitrate()",
    "_getSelectedFramerate()",
    "_snapshotHandlers.ApplyRemoteDesktop",
    "RefreshSystemMonitorAsync()",
    "_snapshotHandlers.ApplySystemMonitor",
    "RefreshSettingsAsync()",
    "_snapshotHandlers.ApplySettings"
)) {
    Assert-Contains -Text $readOnlyWorkspaceRefreshActions -Needle $readOnlyWorkspaceRefreshActionsSignal -Message "ReadOnlyWorkspaceRefreshActions contract missing: $readOnlyWorkspaceRefreshActionsSignal"
}
foreach ($sessionViewModelReadOnlyRefreshSignal in @(
    "new ReadOnlyWorkspaceRefreshCoordinator(",
    "new ReadOnlyWorkspaceRefreshActions(",
    "readOnlyWorkspaceRefreshCoordinator,",
    "_readOnlyWorkspaceSnapshotHandlers,",
    "() => SelectedBitrate",
    "() => SelectedFramerate",
    "_readOnlyWorkspaceRefreshActions.RunCoreDiagnosticsAsync()",
    "_readOnlyWorkspaceRefreshActions.RefreshFileTransferAsync()",
    "_readOnlyWorkspaceRefreshActions.RefreshUsbManagementAsync()",
    "_readOnlyWorkspaceRefreshActions.RefreshRemoteDesktopAsync()",
    "_readOnlyWorkspaceRefreshActions.RefreshSystemMonitorAsync()",
    "_readOnlyWorkspaceRefreshActions.RefreshSettingsAsync()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelReadOnlyRefreshSignal -Message "SessionViewModel must delegate read-only workspace refresh through ReadOnlyWorkspaceRefreshActions: $sessionViewModelReadOnlyRefreshSignal"
}
foreach ($sessionViewModelDirectReadOnlyRefreshSignal in @(
    "_readOnlyWorkspaceRefreshCoordinator.RunCoreDiagnosticsAsync(",
    "_readOnlyWorkspaceRefreshCoordinator.RefreshFileTransferAsync(",
    "_readOnlyWorkspaceRefreshCoordinator.RefreshUsbManagementAsync(",
    "_readOnlyWorkspaceRefreshCoordinator.RefreshRemoteDesktopAsync(",
    "_readOnlyWorkspaceRefreshCoordinator.RefreshSystemMonitorAsync(",
    "_readOnlyWorkspaceRefreshCoordinator.RefreshSettingsAsync(",
    "_readOnlyWorkspaceSnapshotHandlers.ApplyCoreDiagnostics",
    "_readOnlyWorkspaceSnapshotHandlers.ApplyFileTransfer",
    "_readOnlyWorkspaceSnapshotHandlers.ApplyUsbManagement",
    "_readOnlyWorkspaceSnapshotHandlers.ApplyRemoteDesktop",
    "_readOnlyWorkspaceSnapshotHandlers.ApplySystemMonitor",
    "_readOnlyWorkspaceSnapshotHandlers.ApplySettings"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectReadOnlyRefreshSignal)) -Message "SessionViewModel must not compose read-only refresh callbacks directly: $sessionViewModelDirectReadOnlyRefreshSignal"
}
Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceBusyCoordinator.RefreshReadOnlyWorkspaceAsync")) -Message "SessionViewModel must not compose read-only workspace refresh templates directly."
foreach ($workspaceStartupStateBuilderSignal in @(
    "internal sealed class WorkspaceStartupStateBuilder",
    "public WorkspaceStartupState Build()",
    "_discoveryBrowserClient.BuildInputPolicy()",
    "_sessionStatusClient.BuildInitialStatusMessage()",
    "_connectionWorkspaceStateClient.BuildInitialStatusPatch()",
    "_deviceDiscoveryInputDefaultsClient.BuildReadOnlySnapshot()",
    "_featureCatalogClient.BuildReadOnlySnapshot()",
    "_featureCatalogClient.ResolveDefaultSelection(featureEntries)",
    "_remoteDesktopProfileCatalogClient.BuildReadOnlySnapshot()",
    "_coreDiagnosticsClient.BuildInitialStatus()",
    "_fileTransferClient.BuildInitialStatus()",
    "_usbManagementClient.BuildInitialStatus()",
    "_remoteDesktopClient.BuildInitialStatus()",
    "_systemMonitorClient.BuildInitialStatus()",
    "_settingsClient.BuildInitialStatus()",
    "_engineClient.State",
    "internal sealed record WorkspaceStartupState"
)) {
    Assert-Contains -Text $workspaceStartupStateBuilder -Needle $workspaceStartupStateBuilderSignal -Message "WorkspaceStartupStateBuilder contract missing: $workspaceStartupStateBuilderSignal"
}
foreach ($sessionViewModelStartupStateSignal in @(
    "new WorkspaceStartupStateBuilder(",
    "var startupState = workspaceStartupStateBuilder.Build();",
    "_discoveryBrowserInputPolicy = startupState.DiscoveryBrowserInputPolicy;",
    "_statusMessage = startupState.StatusMessage;",
    "_selectedFeature = startupState.SelectedFeature;",
    "new WorkspaceObservableCollections(",
    "startupState.FeatureEntries,",
    "startupState.RemoteDesktopProfileCatalog);",
    "_selectedBitrate = startupState.RemoteDesktopProfileCatalog.DefaultBitrateProfile;",
    "_selectedFramerate = startupState.RemoteDesktopProfileCatalog.DefaultFramerateProfile;"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelStartupStateSignal -Message "SessionViewModel must consume startup defaults through WorkspaceStartupStateBuilder: $sessionViewModelStartupStateSignal"
}
foreach ($sessionViewModelDirectStartupStateSignal in @(
    "_discoveryBrowserClient.BuildInputPolicy()",
    "_sessionStatusClient.BuildInitialStatusMessage()",
    "_connectionWorkspaceStateClient.BuildInitialStatusPatch()",
    "_deviceDiscoveryInputDefaultsClient.BuildReadOnlySnapshot()",
    "_featureCatalogClient.BuildReadOnlySnapshot()",
    "_featureCatalogClient.ResolveDefaultSelection(featureEntries)",
    "_remoteDesktopProfileCatalogClient.BuildReadOnlySnapshot()",
    "_coreDiagnosticsClient.BuildInitialStatus()",
    "_fileTransferClient.BuildInitialStatus()",
    "_usbManagementClient.BuildInitialStatus()",
    "_remoteDesktopClient.BuildInitialStatus()",
    "_systemMonitorClient.BuildInitialStatus()",
    "_settingsClient.BuildInitialStatus()",
    "_engineClient.State"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectStartupStateSignal)) -Message "SessionViewModel must not compose startup/default state directly: $sessionViewModelDirectStartupStateSignal"
}
Assert-True -Condition (-not $sessionViewModel.Contains("_connectionWorkspaceStateClient.BuildErrorPatch(ex.Message)")) -Message "WorkspaceBusyCoordinator must route errors through WorkspaceErrorStatusClient, not the currently selected feature."
Assert-True -Condition (-not $connectionWorkspaceState.Contains("BuildErrorPatch")) -Message "ConnectionWorkspaceStateClient must not own busy-state error routing; use WorkspaceErrorStatusClient."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModel, "catch \(Exception ex\)[\s\S]*?if \(IsDeviceDiscoverySelected\)[\s\S]*?BuildErrorPatch\(ex\.Message\)")) -Message "WorkspaceBusyCoordinator catch must not route errors by currently selected feature."
Assert-True -Condition (-not $sessionViewModelSource.Contains("ApplyConnectionWorkspaceStatusPatch")) -Message "SessionViewModel must apply connection status patches through WorkspaceStatusPatchApplier."
Assert-True -Condition (-not $sessionViewModelSource.Contains("ApplyWorkspaceErrorStatusPatch")) -Message "SessionViewModel must apply workspace error status patches through WorkspaceStatusPatchApplier."
Assert-True -Condition (-not [regex]::IsMatch($sessionViewModelSource, "if \(patch\.(DiscoveryStatus|UsbManagementStatus|CoreDiagnosticsStatus) is not null\)")) -Message "SessionViewModel must not own per-field workspace status patch application."

foreach ($unavailableSignal in @(
    "internal sealed class UnavailableDiscoveryClient",
    "internal sealed class UnavailableDiscoveryBrowserClient",
    "internal sealed class UnavailableManualConnectionClient",
    "internal sealed class UnavailableCrossNetworkConnectionClient",
    "internal sealed class UnavailablePairingMaterialClient",
    "internal sealed class UnavailableConnectionPreflightClient",
    "internal sealed class UnavailableCoreDiagnosticsClient",
    "internal sealed class UnavailableFileTransferWorkspaceClient",
    "internal sealed class UnavailableRemoteDesktopWorkspaceClient",
    "internal sealed class UnavailableSystemMonitorWorkspaceClient",
    "internal sealed class UnavailableUsbManagementWorkspaceClient",
    "internal sealed class UnavailableSettingsWorkspaceClient",
    "Discovery client is not configured.",
    "Settings workspace client is not configured."
)) {
    Assert-Contains -Text $unavailableClientStubs -Needle $unavailableSignal -Message "Unavailable client stub signal missing: $unavailableSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("internal sealed class Unavailable")) -Message "SessionViewModel must not define unavailable service clients; keep fallback clients in Services/UnavailableClientStubs.cs."

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

foreach ($discoveryBrowserInputPolicySignal in @(
    "internal sealed class DiscoveryBrowserActions",
    "BuildInputPolicy",
    "DiscoveryBrowserInputPolicy",
    "DefaultInputPolicy",
    "ExtendedSearchDurationSeconds",
    "ExtendedSearchSeconds",
    "BuildPendingStatus",
    "BuildDefaultPendingStatus",
    "_discoveryBrowserInputPolicy",
    "_inputPolicy.ExtendedSearchSeconds"
)) {
    Assert-Contains -Text ($discoveryBrowser + $sessionViewModel) -Needle $discoveryBrowserInputPolicySignal -Message "Discovery browser input policy signal missing: $discoveryBrowserInputPolicySignal"
}

foreach ($discoveryBrowserActionsSignal in @(
    "internal sealed class DiscoveryBrowserActions",
    "DiscoveryBrowserInputPolicy inputPolicy",
    "WorkspaceBusyCoordinator busyCoordinator",
    "IDiscoveryBrowserClient discoveryBrowserClient",
    "WorkspaceViewStateBuilder viewStateBuilder",
    "ConnectionWorkspaceResultProjector connectionResultProjector",
    "StartAsync()",
    "RunAsync(DiscoveryBrowserAction.Start)",
    "StopAsync()",
    "RunAsync(DiscoveryBrowserAction.Stop)",
    "RefreshAsync()",
    "RunAsync(DiscoveryBrowserAction.Refresh)",
    "RunExtendedSearchAsync()",
    "_setExtendedSearchCountdown(_inputPolicy.ExtendedSearchSeconds)",
    "_busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery",
    "_setDiscoveryBrowserStatus(_discoveryBrowserClient.BuildPendingStatus(action))",
    "_discoveryBrowserClient.BuildReadOnlySnapshotAsync(",
    "_viewStateBuilder.BuildDiscoveryBrowserRequest(",
    "_connectionResultProjector.ApplyDiscoveryBrowserResult("
)) {
    Assert-Contains -Text $discoveryBrowserActions -Needle $discoveryBrowserActionsSignal -Message "DiscoveryBrowserActions contract missing: $discoveryBrowserActionsSignal"
}
foreach ($sessionViewModelDiscoveryBrowserActionSignal in @(
    "new DiscoveryBrowserActions(",
    "_discoveryBrowserActions.StartAsync()",
    "_discoveryBrowserActions.StopAsync()",
    "_discoveryBrowserActions.RefreshAsync()",
    "_discoveryBrowserActions.RunExtendedSearchAsync()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelDiscoveryBrowserActionSignal -Message "SessionViewModel must delegate discovery browser actions through DiscoveryBrowserActions: $sessionViewModelDiscoveryBrowserActionSignal"
}
foreach ($sessionViewModelDirectDiscoveryBrowserActionSignal in @(
    "RunDiscoveryBrowserAsync",
    "_discoveryBrowserClient.BuildPendingStatus(action)",
    "_discoveryBrowserClient.BuildReadOnlySnapshotAsync(",
    "ApplyDiscoveryBrowserResult("
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectDiscoveryBrowserActionSignal)) -Message "SessionViewModel must not compose discovery browser actions directly: $sessionViewModelDirectDiscoveryBrowserActionSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("ExtendedSearchCountdown = 15")) -Message "SessionViewModel must source the Extended Search countdown from DiscoveryBrowserInputPolicy."
Assert-True -Condition (-not $sessionViewModel.Contains("DiscoveryBrowserStatus = action ==")) -Message "SessionViewModel must source Discovery Browser pending status from IDiscoveryBrowserClient."

foreach ($discoveryBrowserPeerCandidateSignal in @(
    "BuildPeerCandidate",
    "BuildDefaultPeerCandidate",
    "DiscoveryBrowserPeerCandidate",
    "CapabilitiesSummary",
    "TrustSummary",
    "DiscoveredPeerView.FromCandidate",
    "pubKeyFP fingerprint only; pairing must provide the peer public key."
)) {
    Assert-Contains -Text ($discoveryBrowser + $sessionViewModel + $mainWindow) -Needle $discoveryBrowserPeerCandidateSignal -Message "Discovery browser peer candidate signal missing: $discoveryBrowserPeerCandidateSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("FormatCapabilities")) -Message "SessionViewModel must not format discovered-peer capabilities inline."
Assert-True -Condition (-not $sessionViewModel.Contains("pubKeyFP fingerprint only; pairing must provide the peer public key.")) -Message "SessionViewModel must source discovered-peer trust summary from DiscoveryBrowserPeerCandidate."

foreach ($deviceDiscoveryPendingStatusSignal in @(
    "_discoveryClient.BuildPendingStatus()",
    "_manualConnectionClient.BuildPendingStatus()",
    "_pairingMaterialClient.BuildPendingStatus()",
    "_connectionPreflightClient.BuildPendingStatus()",
    "_discoveryClient.CanParseAdvertisement(",
    "_manualConnectionClient.CanPrepareTarget(",
    "_pairingMaterialClient.CanValidate(state.PairingConnectionCode)",
    "_connectionWorkspaceStateClient.CanPreparePreflight(",
    "CoreDiscoveryClient.HasParseInputs",
    "ManualConnectionClient.HasManualTargetInputs",
    "PairingMaterialClient.HasConnectionCode",
    "CanPreparePreflight",
    "CoreDiscoveryClient.DefaultPendingStatus",
    "ManualConnectionClient.DefaultPendingStatus",
    "PairingMaterialClient.DefaultPendingStatus",
    "ConnectionPreflightClient.DefaultPendingStatus"
)) {
    Assert-Contains -Text ($discoveryClient + $manualConnection + $pairing + $connectionPreflight + $unavailableClientStubs + $sessionViewModel + $workspaceCommandGateCoordinator) -Needle $deviceDiscoveryPendingStatusSignal -Message "Device Discovery pending status signal missing: $deviceDiscoveryPendingStatusSignal"
}

foreach ($connectionWorkspaceActionsSignal in @(
    "internal sealed class ConnectionWorkspaceActions",
    "WorkspaceBusyCoordinator busyCoordinator",
    "IManualConnectionClient manualConnectionClient",
    "IDiscoveryClient discoveryClient",
    "IDiscoveryBrowserClient discoveryBrowserClient",
    "IPairingMaterialClient pairingMaterialClient",
    "IConnectionPreflightClient connectionPreflightClient",
    "IConnectionWorkspaceStateClient connectionWorkspaceStateClient",
    "WorkspaceViewStateBuilder viewStateBuilder",
    "ConnectionWorkspaceInputCoordinator connectionInputCoordinator",
    "ConnectionWorkspaceResultProjector connectionResultProjector",
    "IList<DiscoveredPeerView> discoveredPeers",
    "PrepareManualConnectionAsync()",
    "_manualConnectionClient.BuildPendingStatus()",
    "_manualConnectionClient.BuildReadOnlySnapshotAsync(",
    "_viewStateBuilder.BuildManualConnectionRequest(",
    "_connectionResultProjector.ApplyManualTargetPrepared(",
    "ParseAdvertisementAsync()",
    "_discoveryClient.BuildPendingStatus()",
    "_discoveryClient.ParseAdvertisementAsync(",
    "_discoveryBrowserClient.BuildPeerCandidate(peer)",
    "_connectionResultProjector.ApplyDiscoveryPeerValidated(",
    "ValidatePairingCodeAsync()",
    "_pairingMaterialClient.BuildPendingStatus()",
    "_discoveredPeers.Count == 1",
    "_pairingMaterialClient.BuildReadOnlySnapshotAsync(",
    "_connectionResultProjector.ApplyPairingValidated(snapshot)",
    "PrepareConnectionAsync()",
    "_connectionInputCoordinator.ValidatedState.DiscoveredPeer",
    "_connectionInputCoordinator.ValidatedState.PairingMaterial",
    "_connectionWorkspaceStateClient.BuildPreflightReadiness(",
    "throw new InvalidOperationException(readiness.ErrorMessage)",
    "_connectionPreflightClient.BuildPendingStatus()",
    "_connectionPreflightClient.BuildReadOnlySnapshotAsync(",
    "_connectionResultProjector.ApplyPreflightPrepared(snapshot)",
    "_busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery"
)) {
    Assert-Contains -Text $connectionWorkspaceActions -Needle $connectionWorkspaceActionsSignal -Message "ConnectionWorkspaceActions contract missing: $connectionWorkspaceActionsSignal"
}
foreach ($sessionViewModelConnectionWorkspaceActionSignal in @(
    "new ConnectionWorkspaceActions(",
    "_connectionWorkspaceActions.PrepareManualConnectionAsync()",
    "_connectionWorkspaceActions.ParseAdvertisementAsync()",
    "_connectionWorkspaceActions.ValidatePairingCodeAsync()",
    "_connectionWorkspaceActions.PrepareConnectionAsync()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelConnectionWorkspaceActionSignal -Message "SessionViewModel must delegate connection workspace actions through ConnectionWorkspaceActions: $sessionViewModelConnectionWorkspaceActionSignal"
}
foreach ($sessionViewModelDirectConnectionWorkspaceActionSignal in @(
    "RunDeviceDiscoveryActionAsync",
    "_manualConnectionClient.BuildPendingStatus()",
    "_manualConnectionClient.BuildReadOnlySnapshotAsync(",
    "_discoveryClient.BuildPendingStatus()",
    "_discoveryClient.ParseAdvertisementAsync(",
    "_pairingMaterialClient.BuildPendingStatus()",
    "_pairingMaterialClient.BuildReadOnlySnapshotAsync(",
    "_connectionPreflightClient.BuildPendingStatus()",
    "_connectionPreflightClient.BuildReadOnlySnapshotAsync(",
    "_connectionWorkspaceStateClient.BuildPreflightReadiness(",
    "ApplyManualTargetPrepared(",
    "ApplyDiscoveryPeerValidated(",
    "ApplyPairingValidated(",
    "ApplyPreflightPrepared("
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectConnectionWorkspaceActionSignal)) -Message "SessionViewModel must not compose connection workspace actions directly: $sessionViewModelDirectConnectionWorkspaceActionSignal"
}

foreach ($viewModelPendingStatusLiteral in @(
    'ManualConnectionStatus = "Preparing..."',
    'DiscoveryStatus = "Parsing..."',
    'PairingStatus = "Validating..."',
    'ConnectionPreflightStatus = "Preparing..."'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelPendingStatusLiteral)) -Message "SessionViewModel must source pending status from service boundary instead of literal: $viewModelPendingStatusLiteral"
}

foreach ($viewModelInputGateLiteral in @(
    "&& !string.IsNullOrWhiteSpace(ManualConnectionHost)",
    "&& !string.IsNullOrWhiteSpace(ManualConnectionPort)",
    "&& !string.IsNullOrWhiteSpace(DiscoveryService)",
    "&& !string.IsNullOrWhiteSpace(DiscoveryTxtRecord)",
    "&& !string.IsNullOrWhiteSpace(PairingConnectionCode)"
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelInputGateLiteral)) -Message "SessionViewModel must source Device Discovery input readiness from service boundary instead of literal: $viewModelInputGateLiteral"
}

Assert-True -Condition (-not $sessionViewModel.Contains("&& _validatedDiscoveredPeer is not null")) -Message "SessionViewModel must source Prepare Connection readiness from ConnectionWorkspaceStateClient."
Assert-True -Condition (-not $sessionViewModel.Contains("&& _validatedPairingMaterial is not null")) -Message "SessionViewModel must source Prepare Connection readiness from ConnectionWorkspaceStateClient."

foreach ($workspaceRefreshPendingStatusSignal in @(
    "_coreDiagnosticsClient.BuildPendingStatus,",
    "_fileTransferClient.BuildPendingStatus,",
    "_usbManagementClient.BuildPendingStatus,",
    "_remoteDesktopClient.BuildPendingStatus,",
    "_systemMonitorClient.BuildPendingStatus,",
    "_settingsClient.BuildPendingStatus,",
    "CoreDiagnosticsClient.DefaultPendingStatus",
    "FileTransferWorkspaceClient.DefaultPendingStatus",
    "UsbManagementWorkspaceClient.DefaultPendingStatus",
    "RemoteDesktopWorkspaceClient.DefaultPendingStatus",
    "SystemMonitorWorkspaceClient.DefaultPendingStatus",
    "SettingsWorkspaceClient.DefaultPendingStatus"
)) {
    Assert-Contains -Text ($coreDiagnostics + $fileTransfer + $usbManagement + $remoteDesktop + $systemMonitor + $settings + $unavailableClientStubs + $sessionViewModel) -Needle $workspaceRefreshPendingStatusSignal -Message "Workspace refresh pending status signal missing: $workspaceRefreshPendingStatusSignal"
}

foreach ($workspaceInitialStatusSignal in @(
    "_coreDiagnosticsClient.BuildInitialStatus()",
    "_fileTransferClient.BuildInitialStatus()",
    "_usbManagementClient.BuildInitialStatus()",
    "_remoteDesktopClient.BuildInitialStatus()",
    "_systemMonitorClient.BuildInitialStatus()",
    "_settingsClient.BuildInitialStatus()",
    "CoreDiagnosticsClient.DefaultInitialStatus",
    "FileTransferWorkspaceClient.DefaultInitialStatus",
    "UsbManagementWorkspaceClient.DefaultInitialStatus",
    "RemoteDesktopWorkspaceClient.DefaultInitialStatus",
    "SystemMonitorWorkspaceClient.DefaultInitialStatus",
    "SettingsWorkspaceClient.DefaultInitialStatus"
)) {
    Assert-Contains -Text ($coreDiagnostics + $fileTransfer + $usbManagement + $remoteDesktop + $systemMonitor + $settings + $unavailableClientStubs + $sessionViewModel) -Needle $workspaceInitialStatusSignal -Message "Workspace initial status signal missing: $workspaceInitialStatusSignal"
}

foreach ($workspaceRefreshCompletedStatusSignal in @(
    "RefreshReadOnlyWorkspaceAsync",
    "_coreDiagnosticsClient.BuildCompletedStatus,",
    "_coreDiagnosticsClient.BuildCompletedStatusMessage,",
    "_fileTransferClient.BuildCompletedStatus,",
    "_fileTransferClient.BuildCompletedStatusMessage,",
    "_usbManagementClient.BuildCompletedStatus,",
    "_usbManagementClient.BuildCompletedStatusMessage,",
    "_remoteDesktopClient.BuildCompletedStatus,",
    "_remoteDesktopClient.BuildCompletedStatusMessage,",
    "_systemMonitorClient.BuildCompletedStatus,",
    "_systemMonitorClient.BuildCompletedStatusMessage,",
    "_settingsClient.BuildCompletedStatus,",
    "_settingsClient.BuildCompletedStatusMessage,",
    "BuildDefaultCompletedStatus",
    "DefaultCompletedStatusMessage"
)) {
    Assert-Contains -Text ($coreDiagnostics + $fileTransfer + $usbManagement + $remoteDesktop + $systemMonitor + $settings + $unavailableClientStubs + $sessionViewModel) -Needle $workspaceRefreshCompletedStatusSignal -Message "Workspace refresh completed status signal missing: $workspaceRefreshCompletedStatusSignal"
}

foreach ($readOnlyRefreshScope in @(
    "CoreDiagnostics",
    "FileTransfer",
    "UsbManagement",
    "RemoteDesktop",
    "SystemMonitor",
    "Settings"
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains("_workspaceBusyCoordinator.RunAsync(WorkspaceErrorScope.$readOnlyRefreshScope")) -Message "SessionViewModel must use WorkspaceBusyCoordinator.RefreshReadOnlyWorkspaceAsync for $readOnlyRefreshScope refresh lifecycle."
}

foreach ($viewModelWorkspacePendingStatusLiteral in @(
    'CoreDiagnosticsStatus = "Running..."',
    'FileTransferStatus = "Refreshing..."',
    'UsbManagementStatus = "Refreshing..."',
    'RemoteDesktopStatus = "Refreshing..."',
    'SystemMonitorStatus = "Refreshing..."',
    'SettingsStatus = "Refreshing..."'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelWorkspacePendingStatusLiteral)) -Message "SessionViewModel must source workspace pending status from service boundary instead of literal: $viewModelWorkspacePendingStatusLiteral"
}

foreach ($viewModelWorkspaceInitialStatusLiteral in @(
    '_discoveryStatus = "Ready"',
    '_discoveryBrowserStatus = "Ready"',
    '_manualConnectionStatus = "Ready"',
    '_crossNetworkStatus = "Ready"',
    '_pairingStatus = "Ready"',
    '_connectionPreflightStatus = "Ready"',
    '_coreDiagnosticsStatus = "Ready"',
    '_fileTransferStatus = "Ready"',
    '_remoteDesktopStatus = "Ready"',
    '_systemMonitorStatus = "Ready"',
    '_usbManagementStatus = "Ready"',
    '_settingsStatus = "Ready"'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelWorkspaceInitialStatusLiteral)) -Message "SessionViewModel must source workspace initial status from service boundary instead of literal: $viewModelWorkspaceInitialStatusLiteral"
}

foreach ($viewModelWorkspaceCompletedStatusLiteral in @(
    'Snapshot {snapshot.CapturedAt',
    'Last scan {snapshot.CapturedAt',
    'Core diagnostics updated',
    'workspace updated'
)) {
    Assert-True -Condition (-not $sessionViewModel.Contains($viewModelWorkspaceCompletedStatusLiteral)) -Message "SessionViewModel must source workspace completed status from service boundary instead of literal: $viewModelWorkspaceCompletedStatusLiteral"
}

foreach ($crossNetworkInputPolicySignal in @(
    "internal sealed class CrossNetworkConnectionActions",
    "internal sealed class CrossNetworkCodeInputCoordinator",
    "internal sealed record CrossNetworkCodeInputUpdate",
    "BuildCodeInputPolicy",
    "CrossNetworkCodeInputPolicy",
    "DefaultCodeInputPolicy",
    "NormalizeCodeInput",
    "CodeLength",
    "Alphabet",
    "CanConnectWithCode",
    "CanScanQrCode",
    "CanCopyCode",
    "CanConnectWithDefaultCodePolicy",
    "HasQrInput",
    "HasGeneratedCode",
    "TryNormalizeConnectionCode",
    "BuildPendingStatus",
    "BuildDefaultPendingStatus",
    "_crossNetworkConnectionClient.NormalizeCodeInput(proposedValue)",
    "_crossNetworkCodeInputCoordinator.BuildInputUpdate("
)) {
    Assert-Contains -Text ($crossNetwork + $sessionViewModel) -Needle $crossNetworkInputPolicySignal -Message "Cross-network input policy signal missing: $crossNetworkInputPolicySignal"
}

foreach ($crossNetworkCodeInputCoordinatorSignal in @(
    "internal sealed class CrossNetworkCodeInputCoordinator",
    "ICrossNetworkConnectionClient crossNetworkConnectionClient",
    "BuildInputUpdate(",
    "string currentValue",
    "string? proposedValue",
    "_crossNetworkConnectionClient.NormalizeCodeInput(proposedValue)",
    "CrossNetworkCodeInputUpdate(",
    "string NormalizedValue",
    "bool ShouldUpdateValue",
    "bool ShouldNotifyNormalizedValue"
)) {
    Assert-Contains -Text $crossNetworkCodeInputCoordinator -Needle $crossNetworkCodeInputCoordinatorSignal -Message "CrossNetworkCodeInputCoordinator contract missing: $crossNetworkCodeInputCoordinatorSignal"
}

foreach ($crossNetworkConnectionActionsSignal in @(
    "internal sealed class CrossNetworkConnectionActions",
    "WorkspaceBusyCoordinator busyCoordinator",
    "ICrossNetworkConnectionClient crossNetworkConnectionClient",
    "WorkspaceViewStateBuilder viewStateBuilder",
    "ConnectionWorkspaceResultProjector connectionResultProjector",
    "GenerateQrCodeAsync()",
    "RunAsync(CrossNetworkConnectionAction.GenerateQrCode)",
    "ScanQrCodeAsync()",
    "RunAsync(CrossNetworkConnectionAction.ScanQrCode)",
    "GenerateCodeAsync()",
    "RunAsync(CrossNetworkConnectionAction.GenerateCode)",
    "RegenerateCodeAsync()",
    "RunAsync(CrossNetworkConnectionAction.RegenerateCode)",
    "CopyCodeAsync()",
    "RunAsync(CrossNetworkConnectionAction.CopyCode)",
    "ConnectWithCodeAsync()",
    "RunAsync(CrossNetworkConnectionAction.ConnectWithCode)",
    "_busyCoordinator.RunAsync(WorkspaceErrorScope.DeviceDiscovery",
    "_setCrossNetworkStatus(_crossNetworkConnectionClient.BuildPendingStatus(action))",
    "_crossNetworkConnectionClient.BuildReadOnlySnapshotAsync(",
    "_viewStateBuilder.BuildCrossNetworkConnectionRequest(",
    "_connectionResultProjector.ApplyCrossNetworkPrepared("
)) {
    Assert-Contains -Text $crossNetworkConnectionActions -Needle $crossNetworkConnectionActionsSignal -Message "CrossNetworkConnectionActions contract missing: $crossNetworkConnectionActionsSignal"
}
foreach ($sessionViewModelCrossNetworkActionSignal in @(
    "new CrossNetworkConnectionActions(",
    "_crossNetworkConnectionActions.GenerateQrCodeAsync()",
    "_crossNetworkConnectionActions.ScanQrCodeAsync()",
    "_crossNetworkConnectionActions.GenerateCodeAsync()",
    "_crossNetworkConnectionActions.RegenerateCodeAsync()",
    "_crossNetworkConnectionActions.CopyCodeAsync()",
    "_crossNetworkConnectionActions.ConnectWithCodeAsync()"
)) {
    Assert-Contains -Text $sessionViewModelSource -Needle $sessionViewModelCrossNetworkActionSignal -Message "SessionViewModel must delegate cross-network actions through CrossNetworkConnectionActions: $sessionViewModelCrossNetworkActionSignal"
}
foreach ($sessionViewModelDirectCrossNetworkActionSignal in @(
    "RunCrossNetworkConnectionAsync",
    "_crossNetworkConnectionClient.BuildPendingStatus(action)",
    "_crossNetworkConnectionClient.BuildReadOnlySnapshotAsync(",
    "ApplyCrossNetworkPrepared("
)) {
    Assert-True -Condition (-not $sessionViewModelSource.Contains($sessionViewModelDirectCrossNetworkActionSignal)) -Message "SessionViewModel must not compose cross-network actions directly: $sessionViewModelDirectCrossNetworkActionSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("CrossNetworkCodeAlphabet")) -Message "SessionViewModel must not duplicate the Smart Connection Code alphabet."
Assert-True -Condition (-not $sessionViewModel.Contains("NormalizeCrossNetworkCodeInput")) -Message "SessionViewModel must source Smart Connection Code input normalization from ICrossNetworkConnectionClient."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_crossNetworkConnectionClient.NormalizeCodeInput(value)")) -Message "SessionViewModel must normalize Smart Connection Code input through CrossNetworkCodeInputCoordinator."
Assert-True -Condition (-not $sessionViewModel.Contains("ToUpperInvariant()")) -Message "SessionViewModel must not own Smart Connection Code casing policy."
Assert-True -Condition (-not $sessionViewModel.Contains("inputPolicy.Alphabet.Contains")) -Message "SessionViewModel must not own Smart Connection Code alphabet filtering."
Assert-True -Condition (-not $sessionViewModel.Contains("CrossNetworkStatus = action switch")) -Message "SessionViewModel must source Cross-network pending status from ICrossNetworkConnectionClient."
Assert-True -Condition (-not $sessionViewModel.Contains("CrossNetworkCodeInput.Length == 6")) -Message "SessionViewModel must source Smart Connection Code readiness from ICrossNetworkConnectionClient."
Assert-True -Condition (-not $sessionViewModel.Contains("!string.IsNullOrWhiteSpace(CrossNetworkQrInput)")) -Message "SessionViewModel must source QR scan readiness from ICrossNetworkConnectionClient."
Assert-True -Condition (-not $sessionViewModel.Contains("!string.IsNullOrWhiteSpace(CrossNetworkGeneratedCode)")) -Message "SessionViewModel must source generated-code copy readiness from ICrossNetworkConnectionClient."

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
    "internal sealed class RemoteDesktopProfileSelectionCoordinator",
    "RemoteDesktopProfileCatalogSnapshot",
    "BuildReadOnlySnapshot",
    "DefaultBitrateProfile",
    "DefaultFramerateProfile",
    "BuildBitrateSelectionStatus",
    "BuildFramerateSelectionStatus",
    "_profileCatalogClient.BuildBitrateSelectionStatus(value)",
    "_profileCatalogClient.BuildFramerateSelectionStatus(value)",
    "_remoteDesktopProfileSelectionCoordinator.ApplyBitrateSelection(value)",
    "_remoteDesktopProfileSelectionCoordinator.ApplyFramerateSelection(value)",
    "new RemoteDesktopProfileCatalogClient()"
)) {
    Assert-Contains -Text ($remoteDesktopProfileCatalog + $sessionViewModel + $mainWindow) -Needle $profileCatalogSignal -Message "Remote Desktop profile catalog signal missing: $profileCatalogSignal"
}
foreach ($profileSelectionCoordinatorSignal in @(
    "internal sealed class RemoteDesktopProfileSelectionCoordinator",
    "IRemoteDesktopProfileCatalogClient profileCatalogClient",
    "Action<string> setStatusMessage",
    "ApplyBitrateSelection(string value)",
    "_setStatusMessage(_profileCatalogClient.BuildBitrateSelectionStatus(value))",
    "ApplyFramerateSelection(string value)",
    "_setStatusMessage(_profileCatalogClient.BuildFramerateSelectionStatus(value))"
)) {
    Assert-Contains -Text $remoteDesktopProfileSelectionCoordinator -Needle $profileSelectionCoordinatorSignal -Message "RemoteDesktopProfileSelectionCoordinator contract missing: $profileSelectionCoordinatorSignal"
}

Assert-True -Condition (-not $sessionViewModel.Contains("Enum.GetValues")) -Message "SessionViewModel must not build Remote Desktop profile lists from local enum reflection."
Assert-True -Condition (-not $sessionViewModel.Contains('_selectedBitrate = "Medium"')) -Message "SessionViewModel must source default bitrate profile from RemoteDesktopProfileCatalogClient."
Assert-True -Condition (-not $sessionViewModel.Contains('_selectedFramerate = "Fps60"')) -Message "SessionViewModel must source default framerate profile from RemoteDesktopProfileCatalogClient."
Assert-True -Condition (-not $sessionViewModel.Contains('StatusMessage = $"Bitrate set to {value}"')) -Message "SessionViewModel must source bitrate selection status from RemoteDesktopProfileCatalogClient."
Assert-True -Condition (-not $sessionViewModel.Contains('StatusMessage = $"Framerate set to {value}"')) -Message "SessionViewModel must source framerate selection status from RemoteDesktopProfileCatalogClient."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_remoteDesktopProfileCatalogClient.BuildBitrateSelectionStatus(value)")) -Message "SessionViewModel must update bitrate selection status through RemoteDesktopProfileSelectionCoordinator."
Assert-True -Condition (-not $sessionViewModelSource.Contains("_remoteDesktopProfileCatalogClient.BuildFramerateSelectionStatus(value)")) -Message "SessionViewModel must update framerate selection status through RemoteDesktopProfileSelectionCoordinator."

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
    "DashboardMetricsUpdater",
    "WorkspaceShellRefreshCoordinator",
    "WorkspaceShellNotificationCatalog",
    "WorkspaceCommandGateCoordinator",
    "WorkspaceCommandAvailability",
    "WorkspaceViewStateBuilder",
    "WorkspaceStartupStateBuilder",
    "ConnectionPreflightClient",
    "ConnectionWorkspaceStateClient",
    "ConnectionWorkspaceInputCoordinator",
    "ConnectionWorkspaceResultProjector",
    "ApplyInputInvalidation",
    "ClearPairingAndPreflight",
    "WorkspaceBusyCoordinator",
    "ReadOnlyWorkspaceRefreshCoordinator",
    "ReadOnlyWorkspaceRefreshActions",
    "ReadOnlyWorkspaceSnapshotHandlers",
    "RemoteDesktopProfileSelectionCoordinator",
    "WorkspaceCollectionProjector.Replace",
    "RefreshReadOnlyWorkspaceAsync",
    "Prepare Connection",
    "WindowsDiscoveryBrowserClient",
    "DeviceDiscoveryInputDefaultsClient",
    "Start Scan",
    "Manual Connect",
    "FPS / Diagnostics",
    "Notifications",
    "Theme",
    "TopBarStatusClient",
    "TopBarStatusUpdater",
    "BuildStatusUpdate",
    "TopBarStatusUpdateSnapshot",
    "TopBarStatusSlot",
    "SessionStatusClient",
    "SessionEngineActions",
    "SessionEngineStateProjector",
    "DiscoveryBrowserActions",
    "CrossNetworkConnectionActions",
    "ConnectionWorkspaceActions",
    "ApplyWorkspaceInputChange",
    "RefreshSelectedFeatureState",
    "RefreshConnectionState",
    "RefreshShellRuntimeState",
    "IsFeatureSelected",
    "CanUseDeviceDiscoveryAction",
    "CanUseCrossNetworkConnectionAction",
    "CanUseSelectedWorkspaceFeature",
    "WorkspaceCommandBindings",
    "WorkspaceActionCommandId",
    "WorkspaceActionGateId",
    "WorkspaceActionDetailSlot",
    "WorkspaceActionCatalogClient",
    "WorkspaceActionButtonTemplate",
    "WorkspaceActionButtonWithDetailTemplate",
    "SidebarWorkspaceActionButtonTemplate",
    "ItemsPanelTemplate",
    "WorkspaceActionRenderContext",
    "WorkspaceActionRenderContextBuilder",
    "BuildDiscoveryBrowserRequest",
    "WorkspaceActionSurfaceTargets",
    "WorkspaceActionSurfaceLoader",
    "WorkspaceStatusPatchApplier",
    "WorkspaceCountNotifier",
    "WorkspaceObservableCollections",
    "WorkspaceCollectionProjector",
    "WorkspaceSnapshotApplier",
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
