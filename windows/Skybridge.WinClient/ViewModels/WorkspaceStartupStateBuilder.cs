using System;
using System.Collections.Generic;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceStartupStateBuilder
{
    private readonly IEngineClient _engineClient;
    private readonly IDiscoveryBrowserClient _discoveryBrowserClient;
    private readonly IDeviceDiscoveryInputDefaultsClient _deviceDiscoveryInputDefaultsClient;
    private readonly IConnectionWorkspaceStateClient _connectionWorkspaceStateClient;
    private readonly ISessionStatusClient _sessionStatusClient;
    private readonly IFeatureCatalogClient _featureCatalogClient;
    private readonly ICoreDiagnosticsClient _coreDiagnosticsClient;
    private readonly IFileTransferWorkspaceClient _fileTransferClient;
    private readonly IRemoteDesktopWorkspaceClient _remoteDesktopClient;
    private readonly IRemoteDesktopProfileCatalogClient _remoteDesktopProfileCatalogClient;
    private readonly ISystemMonitorWorkspaceClient _systemMonitorClient;
    private readonly IUsbManagementWorkspaceClient _usbManagementClient;
    private readonly ISettingsWorkspaceClient _settingsClient;

    public WorkspaceStartupStateBuilder(
        IEngineClient engineClient,
        IDiscoveryBrowserClient discoveryBrowserClient,
        IDeviceDiscoveryInputDefaultsClient deviceDiscoveryInputDefaultsClient,
        IConnectionWorkspaceStateClient connectionWorkspaceStateClient,
        ISessionStatusClient sessionStatusClient,
        IFeatureCatalogClient featureCatalogClient,
        ICoreDiagnosticsClient coreDiagnosticsClient,
        IFileTransferWorkspaceClient fileTransferClient,
        IRemoteDesktopWorkspaceClient remoteDesktopClient,
        IRemoteDesktopProfileCatalogClient remoteDesktopProfileCatalogClient,
        ISystemMonitorWorkspaceClient systemMonitorClient,
        IUsbManagementWorkspaceClient usbManagementClient,
        ISettingsWorkspaceClient settingsClient)
    {
        _engineClient = engineClient ?? throw new ArgumentNullException(nameof(engineClient));
        _discoveryBrowserClient = discoveryBrowserClient ?? throw new ArgumentNullException(nameof(discoveryBrowserClient));
        _deviceDiscoveryInputDefaultsClient = deviceDiscoveryInputDefaultsClient ?? throw new ArgumentNullException(nameof(deviceDiscoveryInputDefaultsClient));
        _connectionWorkspaceStateClient = connectionWorkspaceStateClient ?? throw new ArgumentNullException(nameof(connectionWorkspaceStateClient));
        _sessionStatusClient = sessionStatusClient ?? throw new ArgumentNullException(nameof(sessionStatusClient));
        _featureCatalogClient = featureCatalogClient ?? throw new ArgumentNullException(nameof(featureCatalogClient));
        _coreDiagnosticsClient = coreDiagnosticsClient ?? throw new ArgumentNullException(nameof(coreDiagnosticsClient));
        _fileTransferClient = fileTransferClient ?? throw new ArgumentNullException(nameof(fileTransferClient));
        _remoteDesktopClient = remoteDesktopClient ?? throw new ArgumentNullException(nameof(remoteDesktopClient));
        _remoteDesktopProfileCatalogClient = remoteDesktopProfileCatalogClient ?? throw new ArgumentNullException(nameof(remoteDesktopProfileCatalogClient));
        _systemMonitorClient = systemMonitorClient ?? throw new ArgumentNullException(nameof(systemMonitorClient));
        _usbManagementClient = usbManagementClient ?? throw new ArgumentNullException(nameof(usbManagementClient));
        _settingsClient = settingsClient ?? throw new ArgumentNullException(nameof(settingsClient));
    }

    public WorkspaceStartupState Build()
    {
        var discoveryBrowserInputPolicy = _discoveryBrowserClient.BuildInputPolicy();
        var connectionStatusPatch = _connectionWorkspaceStateClient.BuildInitialStatusPatch();
        var deviceDiscoveryInputDefaults = _deviceDiscoveryInputDefaultsClient.BuildReadOnlySnapshot();
        var featureEntries = _featureCatalogClient.BuildReadOnlySnapshot();
        var profileCatalog = _remoteDesktopProfileCatalogClient.BuildReadOnlySnapshot();

        return new WorkspaceStartupState(
            _sessionStatusClient.BuildInitialStatusMessage(),
            discoveryBrowserInputPolicy,
            connectionStatusPatch.DiscoveryStatus ?? "",
            connectionStatusPatch.DiscoveryBrowserStatus ?? "",
            connectionStatusPatch.ManualConnectionStatus ?? "",
            connectionStatusPatch.CrossNetworkStatus ?? "",
            connectionStatusPatch.PairingStatus ?? "",
            connectionStatusPatch.ConnectionPreflightStatus ?? "",
            connectionStatusPatch.IsDiscoveryScanning ?? false,
            _coreDiagnosticsClient.BuildInitialStatus(),
            _fileTransferClient.BuildInitialStatus(),
            _remoteDesktopClient.BuildInitialStatus(),
            _systemMonitorClient.BuildInitialStatus(),
            _usbManagementClient.BuildInitialStatus(),
            _settingsClient.BuildInitialStatus(),
            deviceDiscoveryInputDefaults.DiscoveryService,
            deviceDiscoveryInputDefaults.ManualConnectionPort,
            deviceDiscoveryInputDefaults.DiscoveryTxtRecord,
            deviceDiscoveryInputDefaults.PairingConnectionCode,
            deviceDiscoveryInputDefaults.ConnectionCodeLeaseMode,
            discoveryBrowserInputPolicy.ExtendedSearchSeconds,
            _engineClient.State,
            featureEntries,
            _featureCatalogClient.ResolveDefaultSelection(featureEntries),
            profileCatalog);
    }
}

internal sealed record WorkspaceStartupState(
    string StatusMessage,
    DiscoveryBrowserInputPolicy DiscoveryBrowserInputPolicy,
    string DiscoveryStatus,
    string DiscoveryBrowserStatus,
    string ManualConnectionStatus,
    string CrossNetworkStatus,
    string PairingStatus,
    string ConnectionPreflightStatus,
    bool IsDiscoveryScanning,
    string CoreDiagnosticsStatus,
    string FileTransferStatus,
    string RemoteDesktopStatus,
    string SystemMonitorStatus,
    string UsbManagementStatus,
    string SettingsStatus,
    string DiscoveryService,
    string ManualConnectionPort,
    string DiscoveryTxtRecord,
    string PairingConnectionCode,
    string ConnectionCodeLeaseMode,
    int ExtendedSearchCountdown,
    EngineConnectionState ConnectionState,
    IReadOnlyList<FeatureEntry> FeatureEntries,
    FeatureEntry SelectedFeature,
    RemoteDesktopProfileCatalogSnapshot RemoteDesktopProfileCatalog);
