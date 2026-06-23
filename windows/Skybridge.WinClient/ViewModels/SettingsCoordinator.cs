using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  SettingsEffectSinks — the thin Action-delegate seam through which the SettingsCoordinator
//  drives the LIVE subsystems, without coupling to the SessionViewModel, MainWindow, or the
//  DI-root. The SessionViewModel constructs one of these from the coordinators it already owns
//  (TopBarNetworkCoordinator pills via SetField bool props, DiscoveryBrowserActions, the weather
//  loop, the self-provisioned clipboard gate, the DD signal smoother, the root theme/accent
//  swap routed up to MainWindow). Every delegate is optional (null == that effect is not hosted
//  in this build, e.g. unit tests), so the coordinator stays testable and never NREs.
//
//  This is the SAME pattern the rest of the codebase uses for live wiring (TopBarNetwork
//  Coordinator's four Set* delegates, WeatherStateCoordinator's setters, DashboardMetricsUpdater)
//  — thin scalar delegates, no VM coupling, no DI-root touch.
// =====================================================================================
public sealed class SettingsEffectSinks
{
    /// <summary>useDarkMode → set the root FrameworkElement.RequestedTheme (Dark/Light) live.</summary>
    public Action<bool>? SetDarkMode { get; init; }

    /// <summary>themeColorHex → override Application.Current.Resources accent color/brush + refresh.</summary>
    public Action<string>? SetAccentHex { get; init; }

    /// <summary>compactMode → push into the DD card density (SetField bool the cards bind to).</summary>
    public Action<bool>? SetCompactMode { get; init; }

    /// <summary>showDeviceDetails → push into the DD card detail-row visibility.</summary>
    public Action<bool>? SetShowDeviceDetails { get; init; }

    /// <summary>showDeviceIcons → push into the DD card icon-chip visibility.</summary>
    public Action<bool>? SetShowDeviceIcons { get; init; }

    /// <summary>Top-bar pill visibility (ip/location, speed, latency) → SetField bools the pills bind.</summary>
    public Action<bool, bool, bool>? SetTopBarPillVisibility { get; init; }

    /// <summary>Issue a discovery browser Start (autoScanOnStartup / Bonjour-on).</summary>
    public Action? StartDiscovery { get; init; }

    /// <summary>Issue a discovery browser Stop (Bonjour-off).</summary>
    public Action? StopDiscovery { get; init; }

    /// <summary>Issue a discovery browser Refresh (re-scan timer tick / settings re-apply).</summary>
    public Action? RefreshDiscovery { get; init; }

    /// <summary>enableRealTimeWeather → start (true) or pause (false) the weather loop.</summary>
    public Action<bool>? SetWeatherEnabled { get; init; }

    /// <summary>enableClipboardSync → enable/disable the clipboard-sync gate (session-start reads it).</summary>
    public Action<bool>? SetClipboardSyncEnabled { get; init; }

    /// <summary>signalStrengthAlpha → apply the EMA coefficient to the DD signal smoother.</summary>
    public Action<double>? SetSignalSmoothingAlpha { get; init; }

    /// <summary>keepSystemAwakeDuringTransfer → arm/disarm the SetThreadExecutionState awake gate.</summary>
    public Action<bool>? SetKeepAwakeDuringTransfer { get; init; }

    /// <summary>系统监控 显示项 (CPU/Memory/Disk/Network/Temperature/FanSpeed) → push the six
    /// show-flags into the monitor tile-visibility source + re-project so hidden tiles drop.</summary>
    public Action<bool, bool, bool, bool, bool, bool>? SetMonitorMetricVisibility { get; init; }
}

// =====================================================================================
//  SettingsCoordinator — the bindable bridge between the Settings tab views (XAML) and the
//  persistence layer. It SELF-PROVISIONS a SettingsService internally (exactly like
//  TopBarNetworkCoordinator news its ITopBarNetworkStatusClient at :93, and like
//  WeatherStateCoordinator / AccountSessionCoordinator own their clients). It is `new`'d in the
//  SessionViewModel ctor next to the other coordinators — NEVER through the DI composition root
//  (SessionViewModelDependencyFactory / WindowsNativeRuntimeDependencyFactory /
//  SessionViewModelDependencies are the do-not-touch landmine files).
//
//  It exposes a PUBLIC two-way bindable property for EVERY settings key, so XAML binds
//  {Binding Settings.<Prop>, Mode=TwoWay}. Each get/set delegates straight to the SettingsService
//  (which write-throughs + raises PropertyChanged + debounce-saves). The coordinator re-emits the
//  service's PropertyChanged so the bindings update when the model changes underneath them (e.g.
//  after Import / Reset, which fire a null-name "everything changed").
//
//  Live-effect hooks (OnDarkModeChanged / OnAccentChanged / discovery / top-bar …) are wired to
//  SettingsService.SettingsChanged and drive the REAL subsystems through the optional
//  SettingsEffectSinks delegates the SessionViewModel supplies. Each effect produces OBSERVABLE
//  behavior (theme swap, accent re-tint, pill show/hide, discovery start/stop + a self-provisioned
//  re-scan PeriodicTimer, weather loop gate, clipboard gate, live logger min-level, signal-smoother
//  alpha) — no fabricated effect, no dead toggle. No `new AsyncRelayCommand(` is created here.
// =====================================================================================

public sealed class SettingsCoordinator : INotifyPropertyChanged, IDisposable
{
    private readonly SettingsService _service;
    private readonly SettingsEffectSinks _sinks;
    private readonly DispatcherQueue? _dispatcherQueue;
    private bool _disposed;

    // Self-provisioned discovery re-scan timer (modeled on TopBarNetworkCoordinator:125). It is
    // (re)armed whenever auto-scan is on + a scan interval is set, and re-issues a discovery
    // Refresh on each tick. Lives entirely inside this coordinator — no DI-root, no new command.
    private readonly object _timerSync = new();
    private CancellationTokenSource? _scanCts;
    private Task? _scanLoopTask;

    public event PropertyChangedEventHandler? PropertyChanged;

    public SettingsCoordinator(SettingsService? service = null, SettingsEffectSinks? sinks = null)
    {
        // Self-provision the persistence facade (the escape hatch); tests may inject a fake.
        _service = service ?? new SettingsService();
        _sinks = sinks ?? new SettingsEffectSinks();

        // Capture the UI dispatcher at construction (the VM is built on the UI thread) so the
        // self-provisioned scan-timer loop can marshal its Refresh back onto the UI thread.
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        // Re-emit the service's change notifications so XAML two-way bindings refresh, and route
        // live-effect hooks off the same signal.
        _service.PropertyChanged += OnServicePropertyChanged;
        _service.SettingsChanged += OnServiceSettingsChanged;
    }

    /// <summary>The underlying service (for advanced callers / tests). Persistence is owned here.</summary>
    public SettingsService Service => _service;

    private void OnServicePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        // Forward by the same property name (our property names mirror the service's 1:1). A null
        // name (bulk Import/Reset) propagates as "all properties changed".
        PropertyChanged?.Invoke(this, e);
    }

    private void OnServiceSettingsChanged(object? sender, SettingsChangedEventArgs e)
    {
        // Route the changed key into the matching live-effect hook (each drives a real subsystem
        // through the SettingsEffectSinks). A null/empty name means a bulk change (Import/Reset) so
        // every effect is re-applied.
        DispatchEffect(e.PropertyName);
    }

    private void DispatchEffect(string propertyName)
    {
        switch (propertyName)
        {
            case nameof(UseDarkMode):
                OnDarkModeChanged(UseDarkMode);
                break;
            case nameof(ThemeColorHex):
                OnAccentChanged(ThemeColorHex);
                break;
            case nameof(CompactMode):
                OnCompactModeChanged(CompactMode);
                break;
            case nameof(ShowDeviceDetails):
                OnShowDeviceDetailsChanged(ShowDeviceDetails);
                break;
            case nameof(ShowDeviceIcons):
                OnShowDeviceIconsChanged(ShowDeviceIcons);
                break;
            case nameof(ShowTopBarIPLocation):
            case nameof(ShowTopBarNetworkSpeed):
            case nameof(ShowTopBarNetworkLatency):
                OnTopBarPillVisibilityChanged();
                break;
            case nameof(EnableBonjourDiscovery):
            case nameof(EnableMDNSResolution):
            case nameof(DiscoveryTimeout):
            case nameof(ScanCustomPorts):
            case nameof(AutoScanOnStartup):
            case nameof(ScanInterval):
                OnDiscoverySettingsChanged();
                break;
            case nameof(EnableRealTimeWeather):
                OnWeatherEnabledChanged(EnableRealTimeWeather);
                break;
            case nameof(EnableClipboardSync):
                OnClipboardSyncChanged(EnableClipboardSync);
                break;
            case nameof(EnableVerboseLogging):
            case nameof(LogLevel):
                OnLogLevelChanged();
                break;
            case nameof(SignalStrengthAlpha):
                OnSignalSmoothingChanged(SignalStrengthAlpha);
                break;
            case nameof(KeepSystemAwakeDuringTransfer):
                OnKeepAwakeChanged(KeepSystemAwakeDuringTransfer);
                break;
            case nameof(ShowMonitorCPU):
            case nameof(ShowMonitorMemory):
            case nameof(ShowMonitorDisk):
            case nameof(ShowMonitorNetwork):
            case nameof(ShowMonitorTemperature):
            case nameof(ShowMonitorFanSpeed):
                OnMonitorMetricVisibilityChanged();
                break;
            case "":
                // Bulk change (Import / Reset): re-apply every live effect.
                ApplyAllEffects();
                break;
        }
    }

    // =================================================================================
    //  Two-way bindable properties — one per settings key. Each delegates to the service.
    // =================================================================================

    // ---- General ---------------------------------------------------------------------
    public string Language { get => _service.Language; set => _service.Language = value; }
    public bool AutoScanOnStartup { get => _service.AutoScanOnStartup; set => _service.AutoScanOnStartup = value; }
    public bool ShowSystemNotifications { get => _service.ShowSystemNotifications; set => _service.ShowSystemNotifications = value; }
    public bool UseDarkMode { get => _service.UseDarkMode; set => _service.UseDarkMode = value; }
    public int ScanInterval { get => _service.ScanInterval; set => _service.ScanInterval = value; }
    public bool ShowDeviceDetails { get => _service.ShowDeviceDetails; set => _service.ShowDeviceDetails = value; }
    public bool ShowConnectionStats { get => _service.ShowConnectionStats; set => _service.ShowConnectionStats = value; }
    public bool CompactMode { get => _service.CompactMode; set => _service.CompactMode = value; }
    public string ThemeColorHex { get => _service.ThemeColorHex; set => _service.ThemeColorHex = value; }

    // ---- Network ---------------------------------------------------------------------
    public bool AutoConnectKnownNetworks { get => _service.AutoConnectKnownNetworks; set => _service.AutoConnectKnownNetworks = value; }
    public bool ShowHiddenNetworks { get => _service.ShowHiddenNetworks; set => _service.ShowHiddenNetworks = value; }
    public bool Prefer5GHz { get => _service.Prefer5GHz; set => _service.Prefer5GHz = value; }
    public int WifiScanTimeout { get => _service.WifiScanTimeout; set => _service.WifiScanTimeout = value; }
    public bool EnableBonjourDiscovery { get => _service.EnableBonjourDiscovery; set => _service.EnableBonjourDiscovery = value; }
    public bool EnableMDNSResolution { get => _service.EnableMDNSResolution; set => _service.EnableMDNSResolution = value; }
    public bool ScanCustomPorts { get => _service.ScanCustomPorts; set => _service.ScanCustomPorts = value; }
    public int DiscoveryTimeout { get => _service.DiscoveryTimeout; set => _service.DiscoveryTimeout = value; }
    public string[] CustomServiceTypes { get => _service.CustomServiceTypes; set => _service.CustomServiceTypes = value; }
    public bool ShowTopBarIPLocation { get => _service.ShowTopBarIPLocation; set => _service.ShowTopBarIPLocation = value; }
    public bool ShowTopBarNetworkSpeed { get => _service.ShowTopBarNetworkSpeed; set => _service.ShowTopBarNetworkSpeed = value; }
    public bool ShowTopBarNetworkLatency { get => _service.ShowTopBarNetworkLatency; set => _service.ShowTopBarNetworkLatency = value; }
    public int ConnectionTimeout { get => _service.ConnectionTimeout; set => _service.ConnectionTimeout = value; }
    public int RetryCount { get => _service.RetryCount; set => _service.RetryCount = value; }

    // ---- Devices ---------------------------------------------------------------------
    public bool AutoConnectPairedDevices { get => _service.AutoConnectPairedDevices; set => _service.AutoConnectPairedDevices = value; }
    public bool ShowDeviceRSSI { get => _service.ShowDeviceRSSI; set => _service.ShowDeviceRSSI = value; }
    public bool ShowConnectableDevicesOnly { get => _service.ShowConnectableDevicesOnly; set => _service.ShowConnectableDevicesOnly = value; }
    public bool HideOfflineDevices { get => _service.HideOfflineDevices; set => _service.HideOfflineDevices = value; }
    public bool SortBySignalStrength { get => _service.SortBySignalStrength; set => _service.SortBySignalStrength = value; }
    public bool ShowDeviceIcons { get => _service.ShowDeviceIcons; set => _service.ShowDeviceIcons = value; }
    public double MinimumSignalStrength { get => _service.MinimumSignalStrength; set => _service.MinimumSignalStrength = value; }

    // ---- File Transfer ---------------------------------------------------------------
    public string DefaultTransferPath { get => _service.DefaultTransferPath; set => _service.DefaultTransferPath = value; }
    public int MaxConcurrentConnections { get => _service.MaxConcurrentConnections; set => _service.MaxConcurrentConnections = value; }
    public int TransferBufferSize { get => _service.TransferBufferSize; set => _service.TransferBufferSize = value; }
    public double TransferSpeedLimitMBps { get => _service.TransferSpeedLimitMBps; set => _service.TransferSpeedLimitMBps = value; }
    public bool ShowFileTransferNotifications { get => _service.ShowFileTransferNotifications; set => _service.ShowFileTransferNotifications = value; }
    public bool AutoRetryFailedTransfers { get => _service.AutoRetryFailedTransfers; set => _service.AutoRetryFailedTransfers = value; }
    public bool KeepTransferHistory { get => _service.KeepTransferHistory; set => _service.KeepTransferHistory = value; }
    public bool KeepSystemAwakeDuringTransfer { get => _service.KeepSystemAwakeDuringTransfer; set => _service.KeepSystemAwakeDuringTransfer = value; }
    public bool ScanTransferFilesForVirus { get => _service.ScanTransferFilesForVirus; set => _service.ScanTransferFilesForVirus = value; }
    public string ScanLevel { get => _service.ScanLevel; set => _service.ScanLevel = value; }

    // ---- Remote Desktop --------------------------------------------------------------
    public string VideoResolution { get => _service.VideoResolution; set => _service.VideoResolution = value; }
    public string VideoFrameRate { get => _service.VideoFrameRate; set => _service.VideoFrameRate = value; }
    public string VideoCompressionQuality { get => _service.VideoCompressionQuality; set => _service.VideoCompressionQuality = value; }
    public bool EnableHardwareAcceleration { get => _service.EnableHardwareAcceleration; set => _service.EnableHardwareAcceleration = value; }
    public bool EnableAdaptiveBitrate { get => _service.EnableAdaptiveBitrate; set => _service.EnableAdaptiveBitrate = value; }
    public double RdCompressionLevelDisplay { get => _service.RdCompressionLevelDisplay; set => _service.RdCompressionLevelDisplay = value; }
    public bool RdFullScreenMode { get => _service.RdFullScreenMode; set => _service.RdFullScreenMode = value; }
    public bool EnableClipboardSync { get => _service.EnableClipboardSync; set => _service.EnableClipboardSync = value; }
    public bool EnableRemoteFileTransfer { get => _service.EnableRemoteFileTransfer; set => _service.EnableRemoteFileTransfer = value; }
    public double MouseSensitivity { get => _service.MouseSensitivity; set => _service.MouseSensitivity = value; }
    public int DoubleClickInterval { get => _service.DoubleClickInterval; set => _service.DoubleClickInterval = value; }
    public bool RdEnableAdaptiveQuality { get => _service.RdEnableAdaptiveQuality; set => _service.RdEnableAdaptiveQuality = value; }
    public bool RdEnableUDPTransport { get => _service.RdEnableUDPTransport; set => _service.RdEnableUDPTransport = value; }
    public int RdNetworkCompressionLevel { get => _service.RdNetworkCompressionLevel; set => _service.RdNetworkCompressionLevel = value; }
    public double RdBandwidthLimit { get => _service.RdBandwidthLimit; set => _service.RdBandwidthLimit = value; }
    public int RdBufferSize { get => _service.RdBufferSize; set => _service.RdBufferSize = value; }

    // ---- System Monitor --------------------------------------------------------------
    public double SystemMonitorRefreshInterval { get => _service.SystemMonitorRefreshInterval; set => _service.SystemMonitorRefreshInterval = value; }
    public bool EnableAutoRefresh { get => _service.EnableAutoRefresh; set => _service.EnableAutoRefresh = value; }
    public bool ShowTrendIndicators { get => _service.ShowTrendIndicators; set => _service.ShowTrendIndicators = value; }
    public bool EnablePerformanceAlerts { get => _service.EnablePerformanceAlerts; set => _service.EnablePerformanceAlerts = value; }
    public int SystemMonitorRetentionDays { get => _service.SystemMonitorRetentionDays; set => _service.SystemMonitorRetentionDays = value; }
    public double MaxHistoryPoints { get => _service.MaxHistoryPoints; set => _service.MaxHistoryPoints = value; }
    public bool ShowMonitorCPU { get => _service.ShowMonitorCPU; set => _service.ShowMonitorCPU = value; }
    public bool ShowMonitorMemory { get => _service.ShowMonitorMemory; set => _service.ShowMonitorMemory = value; }
    public bool ShowMonitorDisk { get => _service.ShowMonitorDisk; set => _service.ShowMonitorDisk = value; }
    public bool ShowMonitorNetwork { get => _service.ShowMonitorNetwork; set => _service.ShowMonitorNetwork = value; }
    public bool ShowMonitorTemperature { get => _service.ShowMonitorTemperature; set => _service.ShowMonitorTemperature = value; }
    public bool ShowMonitorFanSpeed { get => _service.ShowMonitorFanSpeed; set => _service.ShowMonitorFanSpeed = value; }
    public string SystemMonitorChartType { get => _service.SystemMonitorChartType; set => _service.SystemMonitorChartType = value; }
    public double CpuThreshold { get => _service.CpuThreshold; set => _service.CpuThreshold = value; }
    public double MemoryThreshold { get => _service.MemoryThreshold; set => _service.MemoryThreshold = value; }
    public bool EnableTemperatureMonitoring { get => _service.EnableTemperatureMonitoring; set => _service.EnableTemperatureMonitoring = value; }
    public double TemperatureThreshold { get => _service.TemperatureThreshold; set => _service.TemperatureThreshold = value; }
    public bool EnableFanSpeedMonitoring { get => _service.EnableFanSpeedMonitoring; set => _service.EnableFanSpeedMonitoring = value; }
    public double FanSpeedThreshold { get => _service.FanSpeedThreshold; set => _service.FanSpeedThreshold = value; }
    public double DiskThreshold { get => _service.DiskThreshold; set => _service.DiskThreshold = value; }
    public bool EnableSoundAlerts { get => _service.EnableSoundAlerts; set => _service.EnableSoundAlerts = value; }
    public bool EnableSystemNotifications { get => _service.EnableSystemNotifications; set => _service.EnableSystemNotifications = value; }
    public bool EnableThermalThrottlingAlert { get => _service.EnableThermalThrottlingAlert; set => _service.EnableThermalThrottlingAlert = value; }
    public bool EnableRemoteMonitoring { get => _service.EnableRemoteMonitoring; set => _service.EnableRemoteMonitoring = value; }
    public string SystemMonitorSamplingPrecision { get => _service.SystemMonitorSamplingPrecision; set => _service.SystemMonitorSamplingPrecision = value; }

    // ---- Advanced --------------------------------------------------------------------
    public bool EnableVerboseLogging { get => _service.EnableVerboseLogging; set => _service.EnableVerboseLogging = value; }
    public bool ShowDebugInfo { get => _service.ShowDebugInfo; set => _service.ShowDebugInfo = value; }
    public bool SaveNetworkLogs { get => _service.SaveNetworkLogs; set => _service.SaveNetworkLogs = value; }
    public string LogLevel { get => _service.LogLevel; set => _service.LogLevel = value; }
    public string PerformanceMode { get => _service.PerformanceMode; set => _service.PerformanceMode = value; }
    public bool EnableRealTimeWeather { get => _service.EnableRealTimeWeather; set => _service.EnableRealTimeWeather = value; }
    public bool ShowRealtimeFPS { get => _service.ShowRealtimeFPS; set => _service.ShowRealtimeFPS = value; }
    public bool EnableHardwareAccelerationGlobal { get => _service.EnableHardwareAccelerationGlobal; set => _service.EnableHardwareAccelerationGlobal = value; }
    public bool OptimizeMemoryUsage { get => _service.OptimizeMemoryUsage; set => _service.OptimizeMemoryUsage = value; }
    public bool EnableBackgroundScanning { get => _service.EnableBackgroundScanning; set => _service.EnableBackgroundScanning = value; }
    public bool EnableIPv6Support { get => _service.EnableIPv6Support; set => _service.EnableIPv6Support = value; }
    public bool UseNewDiscoveryAlgorithm { get => _service.UseNewDiscoveryAlgorithm; set => _service.UseNewDiscoveryAlgorithm = value; }
    public bool EnableP2PDirectConnection { get => _service.EnableP2PDirectConnection; set => _service.EnableP2PDirectConnection = value; }
    public string PqcSignatureAlgorithm { get => _service.PqcSignatureAlgorithm; set => _service.PqcSignatureAlgorithm = value; }
    public bool PreferXWingHybrid { get => _service.PreferXWingHybrid; set => _service.PreferXWingHybrid = value; }
    public double SignalStrengthAlpha { get => _service.SignalStrengthAlpha; set => _service.SignalStrengthAlpha = value; }

    // =================================================================================
    //  Bulk operations — Export / Import / Reset / Apply (delegate to the service).
    // =================================================================================

    /// <summary>Serialize all settings to a user-chosen path. Returns true on success.</summary>
    public bool ExportSettings(string path) => _service.ExportTo(path);

    /// <summary>Replace all settings from a user-chosen path. Returns true on a valid import.</summary>
    public bool ImportSettings(string path) => _service.ImportFrom(path);

    /// <summary>Revert all settings to defaults (deletes the on-disk file).</summary>
    public void ResetSettings() => _service.Reset();

    /// <summary>
    /// Re-apply the deferred-effect settings to their subsystems. Invoked by the EXISTING
    /// ApplySettings maintenance action (no new command). It re-runs every live-effect hook so a
    /// Remote-Desktop / System-Monitor / discovery / theme change that was edited while a tab was
    /// open is pushed in one shot. Bulk Import / Reset route here too (via the "" change).
    /// </summary>
    public void ApplySettings() => ApplyAllEffects();

    /// <summary>
    /// Apply ALL live effects once at startup (called by the SessionViewModel after the sinks are
    /// wired) so the persisted settings take effect immediately on launch — the saved theme,
    /// accent, pill visibility, logger level, signal-smoother alpha, weather/clipboard gates, and
    /// (if auto-scan is on) the discovery start + re-scan timer — without waiting for the first
    /// user edit. Idempotent.
    /// </summary>
    public void ApplyInitialEffects() => ApplyAllEffects();

    // =================================================================================
    //  Live-effect hooks — each drives a REAL subsystem through the SettingsEffectSinks the
    //  SessionViewModel supplied. Each is invoked from DispatchEffect when its key changes (or on
    //  bulk Import/Reset / startup). A null sink (unit tests / a build that does not host that
    //  subsystem) is a no-op — never an NRE, never a fabricated effect.
    // =================================================================================

    private void ApplyAllEffects()
    {
        OnDarkModeChanged(UseDarkMode);
        OnAccentChanged(ThemeColorHex);
        OnCompactModeChanged(CompactMode);
        OnShowDeviceDetailsChanged(ShowDeviceDetails);
        OnShowDeviceIconsChanged(ShowDeviceIcons);
        OnTopBarPillVisibilityChanged();
        OnDiscoverySettingsChanged();
        OnWeatherEnabledChanged(EnableRealTimeWeather);
        OnClipboardSyncChanged(EnableClipboardSync);
        OnLogLevelChanged();
        OnSignalSmoothingChanged(SignalStrengthAlpha);
        OnKeepAwakeChanged(KeepSystemAwakeDuringTransfer);
        OnMonitorMetricVisibilityChanged();
    }

    // 启用深色模式 → set the root FrameworkElement.RequestedTheme live (routed up to MainWindow,
    // which owns the RootShell FrameworkElement). Observable: every Fluent surface re-themes.
    private void OnDarkModeChanged(bool useDarkMode) => _sinks.SetDarkMode?.Invoke(useDarkMode);

    // 主题颜色 → swap the SkyBridgeAccentColor/Brush app resources to the chosen hex and refresh.
    // Observable: every {StaticResource SkyBridgeAccentBrush} surface re-tints.
    private void OnAccentChanged(string themeColorHex) => _sinks.SetAccentHex?.Invoke(themeColorHex);

    // 紧凑模式 → push into the DD card density bool the cards bind to. Observable: card padding/
    // spacing tightens.
    private void OnCompactModeChanged(bool compact) => _sinks.SetCompactMode?.Invoke(compact);

    // 显示设备详情 → push into the DD card detail-row visibility bool. Observable: DeviceId /
    // Capabilities / Fingerprint / TrustSummary rows expand/collapse.
    private void OnShowDeviceDetailsChanged(bool show) => _sinks.SetShowDeviceDetails?.Invoke(show);

    // 显示设备图标 → push into the DD card icon-chip visibility bool. Observable: the 44px device
    // icon chip shows/hides.
    private void OnShowDeviceIconsChanged(bool show) => _sinks.SetShowDeviceIcons?.Invoke(show);

    // 顶部网络信息 → push the three pill-visibility bools the top-bar pills bind to. Observable:
    // the IP/location, net-speed, and latency pills show/hide independently.
    private void OnTopBarPillVisibilityChanged() =>
        _sinks.SetTopBarPillVisibility?.Invoke(
            ShowTopBarIPLocation,
            ShowTopBarNetworkSpeed,
            ShowTopBarNetworkLatency);

    // 网络发现 + 启动时自动扫描 + 扫描间隔 → gate the discovery browser and (re)arm the self-
    // provisioned re-scan timer. Bonjour-off issues a Stop; Bonjour-on with auto-scan issues a
    // Start; the scan-interval drives a PeriodicTimer that re-issues Refresh. The mDNS-resolution /
    // discovery-timeout / custom-service-type / custom-port keys flow into the DiscoveryBrowser
    // request the SessionViewModel builds from these same settings (see DiscoveryService/getters),
    // so a Refresh re-applies them. Observable: scanning starts/stops and re-sweeps on the cadence.
    private void OnDiscoverySettingsChanged()
    {
        if (!EnableBonjourDiscovery)
        {
            StopScanTimer();
            _sinks.StopDiscovery?.Invoke();
            return;
        }

        if (AutoScanOnStartup)
        {
            _sinks.StartDiscovery?.Invoke();
            StartScanTimer();
        }
        else
        {
            // Bonjour on but no auto-scan: a manual scan is still user-driven; keep the timer off
            // so we never start an unrequested background sweep, but apply the latest request knobs
            // on the next manual Refresh (no fabricated auto-start).
            StopScanTimer();
        }
    }

    // 启用实时天气 → start/pause the weather loop. Observable: the weather hero card refreshes
    // (on) or stops re-fetching (off).
    private void OnWeatherEnabledChanged(bool enabled) => _sinks.SetWeatherEnabled?.Invoke(enabled);

    // 剪贴板同步 → flip the clipboard-sync gate the session-start path consults before starting
    // the WindowsClipboardSyncService. Observable: a session started with this off never spins up
    // the clipboard pump (and an active one is stopped).
    private void OnClipboardSyncChanged(bool enabled) => _sinks.SetClipboardSyncEnabled?.Invoke(enabled);

    // 详细日志 + 日志级别 → set the process logger minimum level live. Observable: emits below the
    // threshold are dropped; verbose forces Trace. Drives the real WindowsRuntimeLog sink.
    private void OnLogLevelChanged() => WindowsRuntimeLog.Apply(LogLevel, EnableVerboseLogging);

    // 信号平滑 alpha → push the EMA coefficient into the DD signal smoother. Observable: the
    // device signal indicators smooth more (low alpha) or track faster (high alpha).
    private void OnSignalSmoothingChanged(double alpha) => _sinks.SetSignalSmoothingAlpha?.Invoke(alpha);

    // 传输时保持唤醒 → arm/disarm the SetThreadExecutionState keep-awake gate used during transfers.
    private void OnKeepAwakeChanged(bool keepAwake) => _sinks.SetKeepAwakeDuringTransfer?.Invoke(keepAwake);

    // 系统监控 显示项 → push the six metric show-flags into the monitor tile-visibility source
    // (the SessionViewModel mirrors them onto the MonitorDisplayPrefs resource and re-projects the
    // tile collection). Observable: a metric toggled off has its tile removed from the grid.
    private void OnMonitorMetricVisibilityChanged() =>
        _sinks.SetMonitorMetricVisibility?.Invoke(
            ShowMonitorCPU,
            ShowMonitorMemory,
            ShowMonitorDisk,
            ShowMonitorNetwork,
            ShowMonitorTemperature,
            ShowMonitorFanSpeed);

    // =================================================================================
    //  Self-provisioned discovery re-scan timer (modeled on TopBarNetworkCoordinator:125).
    //  Re-issues a discovery Refresh every ScanInterval seconds on a thread-pool loop, marshaling
    //  the Refresh delegate back onto the captured UI dispatcher (the discovery actions mutate
    //  UI-thread-affine collections). Re-armed whenever discovery settings change; stopped on
    //  Dispose / Bonjour-off / auto-scan-off.
    // =================================================================================

    private void StartScanTimer()
    {
        var seconds = Math.Clamp(ScanInterval, 5, 3600);
        lock (_timerSync)
        {
            if (_disposed)
            {
                return;
            }

            // Re-arm: cancel any existing loop, then start a fresh one at the new cadence.
            StopScanTimerLocked();

            var cts = new CancellationTokenSource();
            _scanCts = cts;
            _scanLoopTask = Task.Run(() => RunScanLoopAsync(TimeSpan.FromSeconds(seconds), cts.Token));
        }
    }

    private void StopScanTimer()
    {
        lock (_timerSync)
        {
            StopScanTimerLocked();
        }
    }

    private void StopScanTimerLocked()
    {
        if (_scanCts is { } cts)
        {
            try
            {
                cts.Cancel();
            }
            catch (Exception)
            {
                // Already disposed — ignore.
            }

            cts.Dispose();
            _scanCts = null;
        }

        _scanLoopTask = null;
    }

    private async Task RunScanLoopAsync(TimeSpan interval, CancellationToken token)
    {
        try
        {
            using var timer = new PeriodicTimer(interval);
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false))
            {
                PostToUi(() =>
                {
                    if (!_disposed && EnableBonjourDiscovery && AutoScanOnStartup)
                    {
                        _sinks.RefreshDiscovery?.Invoke();
                    }
                });
            }
        }
        catch (OperationCanceledException)
        {
            // Normal teardown / re-arm.
        }
        catch (Exception)
        {
            // Defensive: never let the loop crash the process — just stop re-scanning.
        }
    }

    private void PostToUi(Action action)
    {
        var queue = _dispatcherQueue;
        if (queue is null || queue.HasThreadAccess)
        {
            action();
            return;
        }

        queue.TryEnqueue(() =>
        {
            if (!_disposed)
            {
                action();
            }
        });
    }

    // ---- INotifyPropertyChanged helper (for any coordinator-local props added later) --
    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    // ---- Teardown --------------------------------------------------------------------
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        StopScanTimer();
        _service.PropertyChanged -= OnServicePropertyChanged;
        _service.SettingsChanged -= OnServiceSettingsChanged;
        _service.Dispose();
    }
}
