using System.Collections.Generic;

namespace Skybridge.WinClient.ViewModels;

internal static class WorkspaceShellNotificationCatalog
{
    public static IReadOnlyList<string> SelectedFeaturePropertyNames { get; } = new[]
    {
        nameof(SessionViewModel.IsDeviceDiscoverySelected),
        nameof(SessionViewModel.IsUsbManagementSelected),
        nameof(SessionViewModel.IsFileTransferSelected),
        nameof(SessionViewModel.IsRemoteDesktopSelected),
        nameof(SessionViewModel.IsQuantumSelected),
        nameof(SessionViewModel.IsSystemMonitorSelected),
        nameof(SessionViewModel.IsSettingsSelected)
    };

    public static string ConnectionStatusPropertyName { get; } =
        nameof(SessionViewModel.ConnectionStatus);
}
