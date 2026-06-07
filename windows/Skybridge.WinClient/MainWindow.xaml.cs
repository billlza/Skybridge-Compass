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
        ViewModel = new SessionViewModel(
            new DummyEngineClient(),
            new CoreDiscoveryClient(coreBridge),
            new CoreDiagnosticsClient(coreBridge),
            new FileTransferWorkspaceClient(coreBridge),
            new RemoteDesktopWorkspaceClient(coreBridge),
            new SystemMonitorWorkspaceClient(),
            new UsbManagementWorkspaceClient(),
            new SettingsWorkspaceClient());
        DataContext = ViewModel;
    }
}
