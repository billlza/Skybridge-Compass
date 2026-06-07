using Microsoft.UI.Xaml;
using Skybridge.WinClient.Services;
using Skybridge.WinClient.ViewModels;

namespace Skybridge.WinClient;

public sealed partial class MainWindow : Window
{
    public SessionViewModel ViewModel { get; }

    public MainWindow()
    {
        InitializeComponent();
        var coreBridge = new CoreBridge();
        var discoveryClient = new CoreDiscoveryClient(coreBridge);
        ViewModel = new SessionViewModel(
            new DummyEngineClient(),
            discoveryClient,
            new WindowsDiscoveryBrowserClient(discoveryClient),
            new ManualConnectionClient(),
            new CrossNetworkConnectionClient(),
            new PairingMaterialClient(),
            new ConnectionPreflightClient(coreBridge),
            new CoreDiagnosticsClient(coreBridge),
            new FileTransferWorkspaceClient(coreBridge),
            new RemoteDesktopWorkspaceClient(coreBridge),
            new SystemMonitorWorkspaceClient(),
            new UsbManagementWorkspaceClient(),
            new SettingsWorkspaceClient(),
            new DashboardMetricsClient(),
            new TopBarStatusClient(),
            new ConnectionWorkspaceStateClient(),
            new WorkspaceActionCatalogClient());
        DataContext = ViewModel;
    }
}
