using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceActionSurfaceTargets
{
    private readonly IReadOnlyDictionary<WorkspaceActionSurface, ObservableCollection<WorkspaceActionItemView>> _targets;

    public WorkspaceActionSurfaceTargets(WorkspaceObservableCollections collections)
        : this(
            collections.SidebarSessionActions,
            collections.TopBarActions,
            collections.SessionControlActions,
            collections.DashboardQuickActions,
            collections.DeviceDiscoveryPrimaryActions,
            collections.DeviceDiscoveryScanActions,
            collections.DeviceDiscoveryManualConnectFinalActions,
            collections.CrossNetworkQrActions,
            collections.CrossNetworkCodePrimaryActions,
            collections.CrossNetworkCodeConnectActions,
            collections.UsbManagementHeaderActions,
            collections.FileTransferHeaderActions,
            collections.FileTransferActions,
            collections.RemoteDesktopHeaderActions,
            collections.RemoteDesktopActions,
            collections.QuantumDiagnosticsHeaderActions,
            collections.SystemMonitorHeaderActions,
            collections.SystemMonitorActions,
            collections.SettingsHeaderActions,
            collections.SettingsToolbarActions,
            collections.SettingsMaintenanceActions)
    {
    }

    private WorkspaceActionSurfaceTargets(
        ObservableCollection<WorkspaceActionItemView> sidebarSessionActions,
        ObservableCollection<WorkspaceActionItemView> topBarActions,
        ObservableCollection<WorkspaceActionItemView> sessionControlActions,
        ObservableCollection<WorkspaceActionItemView> dashboardQuickActions,
        ObservableCollection<WorkspaceActionItemView> deviceDiscoveryPrimaryActions,
        ObservableCollection<WorkspaceActionItemView> deviceDiscoveryScanActions,
        ObservableCollection<WorkspaceActionItemView> deviceDiscoveryManualConnectFinalActions,
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
            [WorkspaceActionSurface.DashboardQuickActions] = dashboardQuickActions,
            [WorkspaceActionSurface.DeviceDiscoveryPrimary] = deviceDiscoveryPrimaryActions,
            [WorkspaceActionSurface.DeviceDiscoveryScan] = deviceDiscoveryScanActions,
            [WorkspaceActionSurface.DeviceDiscoveryManualConnectFinal] = deviceDiscoveryManualConnectFinalActions,
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
