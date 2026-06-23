using System.Collections.Generic;
using System.Collections.ObjectModel;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class WorkspaceObservableCollections
{
    public WorkspaceObservableCollections(
        IEnumerable<FeatureEntry> featureEntries,
        RemoteDesktopProfileCatalogSnapshot profileCatalog)
    {
        NavigationItems = new ObservableCollection<FeatureEntry>(featureEntries);
        DashboardMetrics = new ObservableCollection<DashboardMetricView>();
        WeatherMetrics = new ObservableCollection<WeatherMetricView>();
        DashboardQuickActions = new ObservableCollection<WorkspaceActionItemView>();
        BitrateProfiles = new ObservableCollection<string>(profileCatalog.BitrateProfiles);
        FramerateProfiles = new ObservableCollection<string>(profileCatalog.FramerateProfiles);
        TopBarActions = new ObservableCollection<WorkspaceActionItemView>();
        SessionControlActions = new ObservableCollection<WorkspaceActionItemView>();
        DiscoveredPeers = new ObservableCollection<DiscoveredPeerView>();
        DiscoveryBrowserFacts = new ObservableCollection<DiscoveryBrowserFactView>();
        ManualConnectionFacts = new ObservableCollection<ManualConnectionFactView>();
        CrossNetworkConnectionFacts = new ObservableCollection<CrossNetworkConnectionFactView>();
        PairingFacts = new ObservableCollection<PairingFactView>();
        ConnectionPreflightFacts = new ObservableCollection<ConnectionPreflightFactView>();
        CoreDiagnosticFacts = new ObservableCollection<CoreDiagnosticFactView>();
        DeviceDiscoveryPrimaryActions = new ObservableCollection<WorkspaceActionItemView>();
        DeviceDiscoveryScanActions = new ObservableCollection<WorkspaceActionItemView>();
        DeviceDiscoveryManualConnectFinalActions = new ObservableCollection<WorkspaceActionItemView>();
        CrossNetworkQrActions = new ObservableCollection<WorkspaceActionItemView>();
        CrossNetworkCodePrimaryActions = new ObservableCollection<WorkspaceActionItemView>();
        CrossNetworkCodeConnectActions = new ObservableCollection<WorkspaceActionItemView>();
        UsbManagementHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        FileTransferHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        FileTransferActions = new ObservableCollection<WorkspaceActionItemView>();
        RemoteDesktopHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        RemoteDesktopActions = new ObservableCollection<WorkspaceActionItemView>();
        SystemMonitorHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        SystemMonitorActions = new ObservableCollection<WorkspaceActionItemView>();
        SettingsHeaderActions = new ObservableCollection<WorkspaceActionItemView>();
        SettingsToolbarActions = new ObservableCollection<WorkspaceActionItemView>();
        SettingsMaintenanceActions = new ObservableCollection<WorkspaceActionItemView>();
        FileTransferQueue = new ObservableCollection<FileTransferQueueItemView>();
        FileTransferHistory = new ObservableCollection<FileTransferHistoryItemView>();
        FileTransferSecurityFacts = new ObservableCollection<FileTransferSecurityFactView>();
        RemoteDesktopSessions = new ObservableCollection<RemoteDesktopSessionItemView>();
        RemoteDesktopControlFacts = new ObservableCollection<RemoteDesktopControlFactView>();
        SystemMonitorOverview = new ObservableCollection<SystemMonitorMetricView>();
        SystemMonitorDetails = new ObservableCollection<SystemMonitorMetricView>();
        SystemMonitorIndicators = new ObservableCollection<SystemMonitorIndicatorView>();
        UsbDeviceStats = new ObservableCollection<UsbDeviceStatView>();
        UsbDevices = new ObservableCollection<UsbDeviceItemView>();
        SettingsTabs = new ObservableCollection<SettingsTabItemView>();
        SettingsActions = new ObservableCollection<SettingsActionItemView>();
        SettingsDetails = new ObservableCollection<SettingsDetailItemView>();
    }

    public ObservableCollection<FeatureEntry> NavigationItems { get; }

    public ObservableCollection<DashboardMetricView> DashboardMetrics { get; }

    public ObservableCollection<WeatherMetricView> WeatherMetrics { get; }

    public ObservableCollection<WorkspaceActionItemView> DashboardQuickActions { get; }

    public ObservableCollection<string> BitrateProfiles { get; }

    public ObservableCollection<string> FramerateProfiles { get; }

    public ObservableCollection<WorkspaceActionItemView> TopBarActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SessionControlActions { get; }

    public ObservableCollection<DiscoveredPeerView> DiscoveredPeers { get; }

    public ObservableCollection<DiscoveryBrowserFactView> DiscoveryBrowserFacts { get; }

    public ObservableCollection<ManualConnectionFactView> ManualConnectionFacts { get; }

    public ObservableCollection<CrossNetworkConnectionFactView> CrossNetworkConnectionFacts { get; }

    public ObservableCollection<PairingFactView> PairingFacts { get; }

    public ObservableCollection<ConnectionPreflightFactView> ConnectionPreflightFacts { get; }

    public ObservableCollection<CoreDiagnosticFactView> CoreDiagnosticFacts { get; }

    public ObservableCollection<WorkspaceActionItemView> DeviceDiscoveryPrimaryActions { get; }

    public ObservableCollection<WorkspaceActionItemView> DeviceDiscoveryScanActions { get; }

    public ObservableCollection<WorkspaceActionItemView> DeviceDiscoveryManualConnectFinalActions { get; }

    public ObservableCollection<WorkspaceActionItemView> CrossNetworkQrActions { get; }

    public ObservableCollection<WorkspaceActionItemView> CrossNetworkCodePrimaryActions { get; }

    public ObservableCollection<WorkspaceActionItemView> CrossNetworkCodeConnectActions { get; }

    public ObservableCollection<WorkspaceActionItemView> UsbManagementHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> FileTransferHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> FileTransferActions { get; }

    public ObservableCollection<WorkspaceActionItemView> RemoteDesktopHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> RemoteDesktopActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SystemMonitorHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SystemMonitorActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SettingsHeaderActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SettingsToolbarActions { get; }

    public ObservableCollection<WorkspaceActionItemView> SettingsMaintenanceActions { get; }

    public ObservableCollection<FileTransferQueueItemView> FileTransferQueue { get; }

    public ObservableCollection<FileTransferHistoryItemView> FileTransferHistory { get; }

    public ObservableCollection<FileTransferSecurityFactView> FileTransferSecurityFacts { get; }

    public ObservableCollection<RemoteDesktopSessionItemView> RemoteDesktopSessions { get; }

    public ObservableCollection<RemoteDesktopControlFactView> RemoteDesktopControlFacts { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorOverview { get; }

    public ObservableCollection<SystemMonitorMetricView> SystemMonitorDetails { get; }

    public ObservableCollection<SystemMonitorIndicatorView> SystemMonitorIndicators { get; }

    public ObservableCollection<UsbDeviceStatView> UsbDeviceStats { get; }

    public ObservableCollection<UsbDeviceItemView> UsbDevices { get; }

    public ObservableCollection<SettingsTabItemView> SettingsTabs { get; }

    public ObservableCollection<SettingsActionItemView> SettingsActions { get; }

    public ObservableCollection<SettingsDetailItemView> SettingsDetails { get; }
}
