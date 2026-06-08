using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient;

internal static class SessionViewModelDependencyFactory
{
    public static SessionViewModelDependencies CreateConfigured() =>
        WindowsNativeRuntimeDependencyFactory.IsNativeRuntimeRequested()
            ? WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment()
            : CreateDefault();

    public static SessionViewModelDependencies CreateDefault()
    {
        var coreBridge = new CoreBridge();
        var discoveryClient = new CoreDiscoveryClient(coreBridge);

        return new SessionViewModelDependencies(
            new DummyEngineClient(),
            discoveryClient,
            new WindowsDiscoveryBrowserClient(discoveryClient),
            new DeviceDiscoveryInputDefaultsClient(),
            new ManualConnectionClient(),
            new CrossNetworkConnectionClient(),
            new PairingMaterialClient(),
            new ConnectionPreflightClient(coreBridge),
            new CoreDiagnosticsClient(coreBridge),
            new FileTransferWorkspaceClient(coreBridge),
            new RemoteDesktopWorkspaceClient(coreBridge),
            new RemoteDesktopProfileCatalogClient(),
            new SystemMonitorWorkspaceClient(),
            new UsbManagementWorkspaceClient(),
            WindowsNativeRuntimeDependencyFactory.CreateSettingsWorkspaceClientFromEnvironment(),
            new DashboardMetricsClient(),
            new TopBarStatusClient(),
            new ConnectionWorkspaceStateClient(),
            new WorkspaceActionCatalogClient(),
            new WorkspaceErrorStatusClient(),
            new SessionStatusClient(),
            new FeatureCatalogClient(),
            new SessionCommandStateClient(),
            new WorkspaceCommandStateClient());
    }
}
