using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

public sealed class SessionViewModelDependencies
{
    public SessionViewModelDependencies(
        IEngineClient engineClient,
        IDiscoveryClient? discoveryClient = null,
        IDiscoveryBrowserClient? discoveryBrowserClient = null,
        IDeviceDiscoveryInputDefaultsClient? deviceDiscoveryInputDefaultsClient = null,
        IManualConnectionClient? manualConnectionClient = null,
        ICrossNetworkConnectionClient? crossNetworkConnectionClient = null,
        IPairingMaterialClient? pairingMaterialClient = null,
        IConnectionPreflightClient? connectionPreflightClient = null,
        ICoreDiagnosticsClient? coreDiagnosticsClient = null,
        IFileTransferWorkspaceClient? fileTransferClient = null,
        IRemoteDesktopWorkspaceClient? remoteDesktopClient = null,
        IRemoteDesktopProfileCatalogClient? remoteDesktopProfileCatalogClient = null,
        ISystemMonitorWorkspaceClient? systemMonitorClient = null,
        IUsbManagementWorkspaceClient? usbManagementClient = null,
        ISettingsWorkspaceClient? settingsClient = null,
        IDashboardMetricsClient? dashboardMetricsClient = null,
        ITopBarStatusClient? topBarStatusClient = null,
        IConnectionWorkspaceStateClient? connectionWorkspaceStateClient = null,
        IWorkspaceActionCatalogClient? workspaceActionCatalogClient = null,
        IWorkspaceErrorStatusClient? workspaceErrorStatusClient = null,
        ISessionStatusClient? sessionStatusClient = null,
        IFeatureCatalogClient? featureCatalogClient = null,
        ISessionCommandStateClient? sessionCommandStateClient = null,
        IWorkspaceCommandStateClient? workspaceCommandStateClient = null)
    {
        ArgumentNullException.ThrowIfNull(engineClient);

        EngineClient = engineClient;
        DiscoveryClient = discoveryClient ?? new UnavailableDiscoveryClient();
        DiscoveryBrowserClient = discoveryBrowserClient ?? new UnavailableDiscoveryBrowserClient();
        DeviceDiscoveryInputDefaultsClient = deviceDiscoveryInputDefaultsClient ?? new DeviceDiscoveryInputDefaultsClient();
        ManualConnectionClient = manualConnectionClient ?? new UnavailableManualConnectionClient();
        CrossNetworkConnectionClient = crossNetworkConnectionClient ?? new UnavailableCrossNetworkConnectionClient();
        PairingMaterialClient = pairingMaterialClient ?? new UnavailablePairingMaterialClient();
        ConnectionPreflightClient = connectionPreflightClient ?? new UnavailableConnectionPreflightClient();
        CoreDiagnosticsClient = coreDiagnosticsClient ?? new UnavailableCoreDiagnosticsClient();
        FileTransferClient = fileTransferClient ?? new UnavailableFileTransferWorkspaceClient();
        RemoteDesktopClient = remoteDesktopClient ?? new UnavailableRemoteDesktopWorkspaceClient();
        RemoteDesktopProfileCatalogClient = remoteDesktopProfileCatalogClient ?? new RemoteDesktopProfileCatalogClient();
        SystemMonitorClient = systemMonitorClient ?? new UnavailableSystemMonitorWorkspaceClient();
        UsbManagementClient = usbManagementClient ?? new UnavailableUsbManagementWorkspaceClient();
        SettingsClient = settingsClient ?? new UnavailableSettingsWorkspaceClient();
        DashboardMetricsClient = dashboardMetricsClient ?? new DashboardMetricsClient();
        TopBarStatusClient = topBarStatusClient ?? new TopBarStatusClient();
        ConnectionWorkspaceStateClient = connectionWorkspaceStateClient ?? new ConnectionWorkspaceStateClient();
        WorkspaceActionCatalogClient = workspaceActionCatalogClient ?? new WorkspaceActionCatalogClient();
        WorkspaceErrorStatusClient = workspaceErrorStatusClient ?? new WorkspaceErrorStatusClient();
        SessionStatusClient = sessionStatusClient ?? new SessionStatusClient();
        FeatureCatalogClient = featureCatalogClient ?? new FeatureCatalogClient();
        SessionCommandStateClient = sessionCommandStateClient ?? new SessionCommandStateClient();
        WorkspaceCommandStateClient = workspaceCommandStateClient ?? new WorkspaceCommandStateClient();
    }

    public IEngineClient EngineClient { get; }

    public IDiscoveryClient DiscoveryClient { get; }

    public IDiscoveryBrowserClient DiscoveryBrowserClient { get; }

    public IDeviceDiscoveryInputDefaultsClient DeviceDiscoveryInputDefaultsClient { get; }

    public IManualConnectionClient ManualConnectionClient { get; }

    public ICrossNetworkConnectionClient CrossNetworkConnectionClient { get; }

    public IPairingMaterialClient PairingMaterialClient { get; }

    public IConnectionPreflightClient ConnectionPreflightClient { get; }

    public ICoreDiagnosticsClient CoreDiagnosticsClient { get; }

    public IFileTransferWorkspaceClient FileTransferClient { get; }

    public IRemoteDesktopWorkspaceClient RemoteDesktopClient { get; }

    public IRemoteDesktopProfileCatalogClient RemoteDesktopProfileCatalogClient { get; }

    public ISystemMonitorWorkspaceClient SystemMonitorClient { get; }

    public IUsbManagementWorkspaceClient UsbManagementClient { get; }

    public ISettingsWorkspaceClient SettingsClient { get; }

    public IDashboardMetricsClient DashboardMetricsClient { get; }

    public ITopBarStatusClient TopBarStatusClient { get; }

    public IConnectionWorkspaceStateClient ConnectionWorkspaceStateClient { get; }

    public IWorkspaceActionCatalogClient WorkspaceActionCatalogClient { get; }

    public IWorkspaceErrorStatusClient WorkspaceErrorStatusClient { get; }

    public ISessionStatusClient SessionStatusClient { get; }

    public IFeatureCatalogClient FeatureCatalogClient { get; }

    public ISessionCommandStateClient SessionCommandStateClient { get; }

    public IWorkspaceCommandStateClient WorkspaceCommandStateClient { get; }
}
