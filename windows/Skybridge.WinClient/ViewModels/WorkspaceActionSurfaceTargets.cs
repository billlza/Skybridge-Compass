using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceActionSurfaceTargets
{
    private readonly IReadOnlyDictionary<WorkspaceActionSurface, ObservableCollection<WorkspaceActionItemView>> _targets;

    public WorkspaceActionSurfaceTargets(
        ObservableCollection<WorkspaceActionItemView> sidebarSessionActions,
        ObservableCollection<WorkspaceActionItemView> topBarActions,
        ObservableCollection<WorkspaceActionItemView> sessionControlActions,
        ObservableCollection<WorkspaceActionItemView> deviceDiscoveryPrimaryActions,
        ObservableCollection<WorkspaceActionItemView> deviceDiscoveryScanActions,
        ObservableCollection<WorkspaceActionItemView> crossNetworkQrActions,
        ObservableCollection<WorkspaceActionItemView> crossNetworkCodePrimaryActions,
        ObservableCollection<WorkspaceActionItemView> crossNetworkCodeConnectActions,
        ObservableCollection<WorkspaceActionItemView> usbManagementHeaderActions,
        ObservableCollection<WorkspaceActionItemView> fileTransferHeaderActions,
        ObservableCollection<WorkspaceActionItemView> fileTransferActions,
        ObservableCollection<WorkspaceActionItemView> remoteDesktopHeaderActions,
        ObservableCollection<WorkspaceActionItemView> remoteDesktopActions,
        ObservableCollection<WorkspaceActionItemView> quantumDiagnosticsHeaderActions,
        ObservableCollection<WorkspaceActionItemView> systemMonitorHeaderActions,
        ObservableCollection<WorkspaceActionItemView> systemMonitorActions,
        ObservableCollection<WorkspaceActionItemView> settingsHeaderActions,
        ObservableCollection<WorkspaceActionItemView> settingsToolbarActions,
        ObservableCollection<WorkspaceActionItemView> settingsMaintenanceActions)
    {
        _targets = new Dictionary<WorkspaceActionSurface, ObservableCollection<WorkspaceActionItemView>>
        {
            [WorkspaceActionSurface.SidebarSession] = sidebarSessionActions,
            [WorkspaceActionSurface.TopBarActions] = topBarActions,
            [WorkspaceActionSurface.SessionControls] = sessionControlActions,
            [WorkspaceActionSurface.DeviceDiscoveryPrimary] = deviceDiscoveryPrimaryActions,
            [WorkspaceActionSurface.DeviceDiscoveryScan] = deviceDiscoveryScanActions,
            [WorkspaceActionSurface.CrossNetworkQr] = crossNetworkQrActions,
            [WorkspaceActionSurface.CrossNetworkCodePrimary] = crossNetworkCodePrimaryActions,
            [WorkspaceActionSurface.CrossNetworkCodeConnect] = crossNetworkCodeConnectActions,
            [WorkspaceActionSurface.UsbManagementHeader] = usbManagementHeaderActions,
            [WorkspaceActionSurface.FileTransferHeader] = fileTransferHeaderActions,
            [WorkspaceActionSurface.FileTransfer] = fileTransferActions,
            [WorkspaceActionSurface.RemoteDesktopHeader] = remoteDesktopHeaderActions,
            [WorkspaceActionSurface.RemoteDesktop] = remoteDesktopActions,
            [WorkspaceActionSurface.QuantumDiagnosticsHeader] = quantumDiagnosticsHeaderActions,
            [WorkspaceActionSurface.SystemMonitorHeader] = systemMonitorHeaderActions,
            [WorkspaceActionSurface.SystemMonitorControls] = systemMonitorActions,
            [WorkspaceActionSurface.SettingsHeader] = settingsHeaderActions,
            [WorkspaceActionSurface.SettingsToolbar] = settingsToolbarActions,
            [WorkspaceActionSurface.SettingsMaintenance] = settingsMaintenanceActions
        };
    }

    public ObservableCollection<WorkspaceActionItemView> Resolve(WorkspaceActionSurface surface) =>
        _targets.TryGetValue(surface, out var target)
            ? target
            : throw new InvalidOperationException($"Workspace action surface target is not registered: {surface}.");
}
