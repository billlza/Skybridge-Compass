using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceShellStateSource
{
    private readonly SessionViewModel _viewModel;

    public WorkspaceShellStateSource(SessionViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);

        _viewModel = viewModel;
    }

    public EngineConnectionState ConnectionState => _viewModel.ConnectionState;

    public int TransferTaskCount => _viewModel.FileTransferQueue.Count;

    public bool IsBusy => _viewModel.IsBusy;

    public FeatureEntry SelectedFeature => _viewModel.SelectedFeature;

    public string ManualConnectionHost => _viewModel.ManualConnectionHost;

    public string ManualConnectionPort => _viewModel.ManualConnectionPort;

    public string CrossNetworkQrInput => _viewModel.CrossNetworkQrInput;

    public string CrossNetworkCodeInput => _viewModel.CrossNetworkCodeInput;

    public string CrossNetworkGeneratedCode => _viewModel.CrossNetworkGeneratedCode;

    public string DiscoveryService => _viewModel.DiscoveryService;

    public string DiscoveryTxtRecord => _viewModel.DiscoveryTxtRecord;

    public string PairingConnectionCode => _viewModel.PairingConnectionCode;

    public ConnectionWorkspaceValidatedState ValidatedState => _viewModel.ValidatedConnectionState;

    public bool IsUsbManagementSelected => _viewModel.IsUsbManagementSelected;

    public bool IsFileTransferSelected => _viewModel.IsFileTransferSelected;

    public bool IsRemoteDesktopSelected => _viewModel.IsRemoteDesktopSelected;

    public bool IsSystemMonitorSelected => _viewModel.IsSystemMonitorSelected;

    public bool IsSettingsSelected => _viewModel.IsSettingsSelected;

    public string ConnectionStatus => _viewModel.ConnectionStatus;

    public string PerformanceStatus => _viewModel.PerformanceStatus;
}
