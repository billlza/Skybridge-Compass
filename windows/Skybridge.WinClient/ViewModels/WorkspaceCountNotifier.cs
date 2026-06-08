using System;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceCountNotifier
{
    private readonly Action<string> _notify;

    public WorkspaceCountNotifier(Action<string> notify)
    {
        _notify = notify;
    }

    public void DashboardMetricsChanged() => Notify(nameof(SessionViewModel.DashboardMetricCount));

    public void DiscoveredPeersChanged() => Notify(nameof(SessionViewModel.DiscoveredPeerCount));

    public void DiscoveryBrowserFactsChanged() => Notify(nameof(SessionViewModel.DiscoveryBrowserFactCount));

    public void ManualConnectionFactsChanged() => Notify(nameof(SessionViewModel.ManualConnectionFactCount));

    public void CrossNetworkConnectionFactsChanged() => Notify(nameof(SessionViewModel.CrossNetworkConnectionFactCount));

    public void PairingFactsChanged() => Notify(nameof(SessionViewModel.PairingFactCount));

    public void ConnectionPreflightFactsChanged() => Notify(nameof(SessionViewModel.ConnectionPreflightFactCount));

    public void CoreDiagnosticFactsChanged() => Notify(nameof(SessionViewModel.CoreDiagnosticFactCount));

    public void FileTransferHistoryChanged() => Notify(nameof(SessionViewModel.FileTransferHistoryCount));

    public void UsbDevicesChanged() => Notify(nameof(SessionViewModel.UsbDeviceCount));

    public void RemoteDesktopSessionsChanged() => Notify(nameof(SessionViewModel.RemoteDesktopSessionCount));

    public void SystemMonitorMetricsChanged() => Notify(nameof(SessionViewModel.SystemMonitorMetricCount));

    public void SettingsActionsChanged() => Notify(nameof(SessionViewModel.SettingsActionCount));

    private void Notify(string propertyName) => _notify(propertyName);
}
