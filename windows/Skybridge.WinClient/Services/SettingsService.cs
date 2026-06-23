using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  SkyBridgeSettings — the persisted Settings model. EVERY key from the build-plan model
//  table (General / Network / Devices / File Transfer / Remote Desktop / System Monitor /
//  Advanced), with the EXACT Mac-faithful defaults. Serialized verbatim by SettingsStore as
//  plaintext JSON. Keys are Windows-local JSON keys (Mac UserDefaults key names do not apply
//  cross-platform; see /tmp/sb-settings/contract.md for the wiring provenance).
//
//  This is a mutable class (not a record) because SettingsService writes individual fields
//  through on every property set. Property names below ARE the JSON keys (System.Text.Json
//  camelCase via [JsonPropertyName] would be redundant — we keep the C# names which serialize
//  as-is, and the model is only ever round-tripped by this app).
// =====================================================================================

public sealed class SkyBridgeSettings
{
    // Schema version stamped into every saved file; SettingsStore rejects mismatches.
    public int SchemaVersion { get; set; } = SettingsStore.CurrentSchemaVersion;

    // ---- General ---------------------------------------------------------------------
    public string Language { get; set; } = "system";
    public bool AutoScanOnStartup { get; set; } = true;
    public bool ShowSystemNotifications { get; set; } = true;
    public bool UseDarkMode { get; set; } = true; // Windows ships dark-locked; deliberate divergence from Mac (false)
    public int ScanInterval { get; set; } = 30;
    public bool ShowDeviceDetails { get; set; } = true;
    public bool ShowConnectionStats { get; set; } = true;
    public bool CompactMode { get; set; } = false;
    public string ThemeColorHex { get; set; } = "#3072EF";

    // ---- Network ---------------------------------------------------------------------
    public bool AutoConnectKnownNetworks { get; set; } = true;
    public bool ShowHiddenNetworks { get; set; } = false;
    public bool Prefer5GHz { get; set; } = true;
    public int WifiScanTimeout { get; set; } = 10;
    public bool EnableBonjourDiscovery { get; set; } = true;
    public bool EnableMDNSResolution { get; set; } = true;
    public bool ScanCustomPorts { get; set; } = false;
    public int DiscoveryTimeout { get; set; } = 30;
    public string[] CustomServiceTypes { get; set; } = Array.Empty<string>();
    public bool ShowTopBarIPLocation { get; set; } = true;
    public bool ShowTopBarNetworkSpeed { get; set; } = true;
    public bool ShowTopBarNetworkLatency { get; set; } = true;
    public int ConnectionTimeout { get; set; } = 10;
    public int RetryCount { get; set; } = 3; // single source of truth; shared w/ File Transfer + Advanced

    // ---- Devices ---------------------------------------------------------------------
    public bool AutoConnectPairedDevices { get; set; } = true;
    public bool ShowDeviceRSSI { get; set; } = true;
    public bool ShowConnectableDevicesOnly { get; set; } = false;
    public bool HideOfflineDevices { get; set; } = false;
    public bool SortBySignalStrength { get; set; } = true;
    public bool ShowDeviceIcons { get; set; } = true;
    public double MinimumSignalStrength { get; set; } = -80.0;

    // ---- File Transfer ---------------------------------------------------------------
    public string DefaultTransferPath { get; set; } = "%USERPROFILE%\\Downloads";
    public int MaxConcurrentConnections { get; set; } = 10; // single source of truth; shared w/ Advanced
    public int TransferBufferSize { get; set; } = 131072;
    public double TransferSpeedLimitMBps { get; set; } = 0;
    public bool ShowFileTransferNotifications { get; set; } = true;
    public bool AutoRetryFailedTransfers { get; set; } = true;
    public bool KeepTransferHistory { get; set; } = true;
    public bool KeepSystemAwakeDuringTransfer { get; set; } = false;
    public bool ScanTransferFilesForVirus { get; set; } = false;
    public string ScanLevel { get; set; } = "standard";

    // ---- Remote Desktop --------------------------------------------------------------
    public string VideoResolution { get; set; } = "hd1080p";
    public string VideoFrameRate { get; set; } = "fps30";
    public string VideoCompressionQuality { get; set; } = "balanced";
    public bool EnableHardwareAcceleration { get; set; } = true;
    public bool EnableAdaptiveBitrate { get; set; } = true;
    public double RdCompressionLevelDisplay { get; set; } = 50.0;
    public bool RdFullScreenMode { get; set; } = false;
    public bool EnableClipboardSync { get; set; } = true;
    public bool EnableRemoteFileTransfer { get; set; } = true;
    public double MouseSensitivity { get; set; } = 1.0;
    public int DoubleClickInterval { get; set; } = 500;
    public bool RdEnableAdaptiveQuality { get; set; } = true;
    public bool RdEnableUDPTransport { get; set; } = true;
    public int RdNetworkCompressionLevel { get; set; } = 6;
    public double RdBandwidthLimit { get; set; } = 0;
    public int RdBufferSize { get; set; } = 1024;

    // ---- System Monitor --------------------------------------------------------------
    public double SystemMonitorRefreshInterval { get; set; } = 1.0;
    public bool EnableAutoRefresh { get; set; } = true;
    public bool ShowTrendIndicators { get; set; } = true;
    public bool EnablePerformanceAlerts { get; set; } = true;
    public int SystemMonitorRetentionDays { get; set; } = 7;
    public double MaxHistoryPoints { get; set; } = 300.0;
    public bool ShowMonitorCPU { get; set; } = true;
    public bool ShowMonitorMemory { get; set; } = true;
    public bool ShowMonitorDisk { get; set; } = true;
    public bool ShowMonitorNetwork { get; set; } = true;
    public bool ShowMonitorTemperature { get; set; } = true;
    public bool ShowMonitorFanSpeed { get; set; } = true;
    public string SystemMonitorChartType { get; set; } = "line";
    public double CpuThreshold { get; set; } = 80.0;
    public double MemoryThreshold { get; set; } = 80.0;
    public bool EnableTemperatureMonitoring { get; set; } = true;
    public double TemperatureThreshold { get; set; } = 80.0;
    public bool EnableFanSpeedMonitoring { get; set; } = true;
    public double FanSpeedThreshold { get; set; } = 4000.0;
    public double DiskThreshold { get; set; } = 90.0;
    public bool EnableSoundAlerts { get; set; } = false;
    public bool EnableSystemNotifications { get; set; } = true;
    public bool EnableThermalThrottlingAlert { get; set; } = true;
    public bool EnableRemoteMonitoring { get; set; } = false;
    public string SystemMonitorSamplingPrecision { get; set; } = "normal";

    // ---- Advanced --------------------------------------------------------------------
    public bool EnableVerboseLogging { get; set; } = false;
    public bool ShowDebugInfo { get; set; } = false;
    public bool SaveNetworkLogs { get; set; } = false;
    public string LogLevel { get; set; } = "Info";
    public string PerformanceMode { get; set; } = "balanced";
    public bool EnableRealTimeWeather { get; set; } = false;
    public bool ShowRealtimeFPS { get; set; } = false;
    public bool EnableHardwareAccelerationGlobal { get; set; } = true;
    public bool OptimizeMemoryUsage { get; set; } = true;
    public bool EnableBackgroundScanning { get; set; } = false;
    public bool EnableIPv6Support { get; set; } = false;
    public bool UseNewDiscoveryAlgorithm { get; set; } = false;
    public bool EnableP2PDirectConnection { get; set; } = false;
    public string PqcSignatureAlgorithm { get; set; } = "ML-DSA-65";
    public bool PreferXWingHybrid { get; set; } = false;
    public double SignalStrengthAlpha { get; set; } = 0.6;

    /// <summary>Produce a deep-ish copy (CustomServiceTypes is cloned) so callers can swap models atomically.</summary>
    public SkyBridgeSettings Clone()
    {
        var copy = (SkyBridgeSettings)MemberwiseClone();
        copy.CustomServiceTypes = (string[])CustomServiceTypes.Clone();
        return copy;
    }
}

// =====================================================================================
//  SettingsService — the typed, change-notifying facade over SettingsStore. It owns the live
//  SkyBridgeSettings model, hydrated from disk at construction. EVERY typed property is a
//  write-through: the setter mutates the model, raises PropertyChanged (so any direct
//  INotifyPropertyChanged binding updates), fires the single SettingsChanged event (so live-
//  effect subscribers — theme, discovery, top-bar pills — react), and schedules a debounced
//  (~300 ms) Save so a slider drag coalesces into ONE disk write.
//
//  This class self-provisions its SettingsStore (it is constructed inside SettingsCoordinator,
//  which is itself self-provisioned in the SessionViewModel ctor — the sanctioned escape hatch,
//  never the DI root).
// =====================================================================================

public sealed class SettingsService : INotifyPropertyChanged, IDisposable
{
    private static readonly TimeSpan SaveDebounce = TimeSpan.FromMilliseconds(300);

    private readonly SettingsStore _store;
    private readonly object _sync = new();
    private SkyBridgeSettings _model;
    private Timer? _saveTimer;
    private bool _disposed;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised on ANY settings mutation (the property name is in the args). Live-effect
    /// subscribers (theme/discovery/top-bar) bind to this instead of N individual handlers.</summary>
    public event EventHandler<SettingsChangedEventArgs>? SettingsChanged;

    public SettingsService(SettingsStore? store = null)
    {
        _store = store ?? new SettingsStore();
        _model = _store.Load();
    }

    /// <summary>Read-only snapshot of the current model (for Export and bulk reads).</summary>
    public SkyBridgeSettings Snapshot => _model.Clone();

    // ---- Write-through plumbing ------------------------------------------------------

    // Generic value setter: compares, mutates the field via the supplied assign action, then
    // notifies + debounces a save. The propertyName is the public property name (== JSON key).
    private bool Set<T>(T current, T value, Action<T> assign, [CallerMemberName] string? propertyName = null)
    {
        if (Equals(current, value))
        {
            return false;
        }

        assign(value);
        RaiseChanged(propertyName);
        return true;
    }

    private void RaiseChanged(string? propertyName)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        SettingsChanged?.Invoke(this, new SettingsChangedEventArgs(propertyName ?? string.Empty));
        ScheduleSave();
    }

    private void ScheduleSave()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            // Coalesce rapid changes (slider drags, multi-toggle) into a single write ~300 ms
            // after the last mutation. A one-shot Timer re-armed on each change.
            if (_saveTimer is null)
            {
                _saveTimer = new Timer(_ => FlushSave(), null, SaveDebounce, Timeout.InfiniteTimeSpan);
            }
            else
            {
                _saveTimer.Change(SaveDebounce, Timeout.InfiniteTimeSpan);
            }
        }
    }

    private void FlushSave()
    {
        SkyBridgeSettings toSave;
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            toSave = _model.Clone();
        }

        _store.Save(toSave);
    }

    // ---- General ---------------------------------------------------------------------
    public string Language { get => _model.Language; set => Set(_model.Language, value, v => _model.Language = v); }
    public bool AutoScanOnStartup { get => _model.AutoScanOnStartup; set => Set(_model.AutoScanOnStartup, value, v => _model.AutoScanOnStartup = v); }
    public bool ShowSystemNotifications { get => _model.ShowSystemNotifications; set => Set(_model.ShowSystemNotifications, value, v => _model.ShowSystemNotifications = v); }
    public bool UseDarkMode { get => _model.UseDarkMode; set => Set(_model.UseDarkMode, value, v => _model.UseDarkMode = v); }
    public int ScanInterval { get => _model.ScanInterval; set => Set(_model.ScanInterval, value, v => _model.ScanInterval = v); }
    public bool ShowDeviceDetails { get => _model.ShowDeviceDetails; set => Set(_model.ShowDeviceDetails, value, v => _model.ShowDeviceDetails = v); }
    public bool ShowConnectionStats { get => _model.ShowConnectionStats; set => Set(_model.ShowConnectionStats, value, v => _model.ShowConnectionStats = v); }
    public bool CompactMode { get => _model.CompactMode; set => Set(_model.CompactMode, value, v => _model.CompactMode = v); }
    public string ThemeColorHex { get => _model.ThemeColorHex; set => Set(_model.ThemeColorHex, value, v => _model.ThemeColorHex = v); }

    // ---- Network ---------------------------------------------------------------------
    public bool AutoConnectKnownNetworks { get => _model.AutoConnectKnownNetworks; set => Set(_model.AutoConnectKnownNetworks, value, v => _model.AutoConnectKnownNetworks = v); }
    public bool ShowHiddenNetworks { get => _model.ShowHiddenNetworks; set => Set(_model.ShowHiddenNetworks, value, v => _model.ShowHiddenNetworks = v); }
    public bool Prefer5GHz { get => _model.Prefer5GHz; set => Set(_model.Prefer5GHz, value, v => _model.Prefer5GHz = v); }
    public int WifiScanTimeout { get => _model.WifiScanTimeout; set => Set(_model.WifiScanTimeout, value, v => _model.WifiScanTimeout = v); }
    public bool EnableBonjourDiscovery { get => _model.EnableBonjourDiscovery; set => Set(_model.EnableBonjourDiscovery, value, v => _model.EnableBonjourDiscovery = v); }
    public bool EnableMDNSResolution { get => _model.EnableMDNSResolution; set => Set(_model.EnableMDNSResolution, value, v => _model.EnableMDNSResolution = v); }
    public bool ScanCustomPorts { get => _model.ScanCustomPorts; set => Set(_model.ScanCustomPorts, value, v => _model.ScanCustomPorts = v); }
    public int DiscoveryTimeout { get => _model.DiscoveryTimeout; set => Set(_model.DiscoveryTimeout, value, v => _model.DiscoveryTimeout = v); }
    public string[] CustomServiceTypes
    {
        get => _model.CustomServiceTypes;
        set
        {
            var next = value ?? Array.Empty<string>();
            if (!ArrayEquals(_model.CustomServiceTypes, next))
            {
                _model.CustomServiceTypes = next;
                RaiseChanged(nameof(CustomServiceTypes));
            }
        }
    }
    public bool ShowTopBarIPLocation { get => _model.ShowTopBarIPLocation; set => Set(_model.ShowTopBarIPLocation, value, v => _model.ShowTopBarIPLocation = v); }
    public bool ShowTopBarNetworkSpeed { get => _model.ShowTopBarNetworkSpeed; set => Set(_model.ShowTopBarNetworkSpeed, value, v => _model.ShowTopBarNetworkSpeed = v); }
    public bool ShowTopBarNetworkLatency { get => _model.ShowTopBarNetworkLatency; set => Set(_model.ShowTopBarNetworkLatency, value, v => _model.ShowTopBarNetworkLatency = v); }
    public int ConnectionTimeout { get => _model.ConnectionTimeout; set => Set(_model.ConnectionTimeout, value, v => _model.ConnectionTimeout = v); }
    public int RetryCount { get => _model.RetryCount; set => Set(_model.RetryCount, value, v => _model.RetryCount = v); }

    // ---- Devices ---------------------------------------------------------------------
    public bool AutoConnectPairedDevices { get => _model.AutoConnectPairedDevices; set => Set(_model.AutoConnectPairedDevices, value, v => _model.AutoConnectPairedDevices = v); }
    public bool ShowDeviceRSSI { get => _model.ShowDeviceRSSI; set => Set(_model.ShowDeviceRSSI, value, v => _model.ShowDeviceRSSI = v); }
    public bool ShowConnectableDevicesOnly { get => _model.ShowConnectableDevicesOnly; set => Set(_model.ShowConnectableDevicesOnly, value, v => _model.ShowConnectableDevicesOnly = v); }
    public bool HideOfflineDevices { get => _model.HideOfflineDevices; set => Set(_model.HideOfflineDevices, value, v => _model.HideOfflineDevices = v); }
    public bool SortBySignalStrength { get => _model.SortBySignalStrength; set => Set(_model.SortBySignalStrength, value, v => _model.SortBySignalStrength = v); }
    public bool ShowDeviceIcons { get => _model.ShowDeviceIcons; set => Set(_model.ShowDeviceIcons, value, v => _model.ShowDeviceIcons = v); }
    public double MinimumSignalStrength { get => _model.MinimumSignalStrength; set => Set(_model.MinimumSignalStrength, value, v => _model.MinimumSignalStrength = v); }

    // ---- File Transfer ---------------------------------------------------------------
    public string DefaultTransferPath { get => _model.DefaultTransferPath; set => Set(_model.DefaultTransferPath, value, v => _model.DefaultTransferPath = v); }
    public int MaxConcurrentConnections { get => _model.MaxConcurrentConnections; set => Set(_model.MaxConcurrentConnections, value, v => _model.MaxConcurrentConnections = v); }
    public int TransferBufferSize { get => _model.TransferBufferSize; set => Set(_model.TransferBufferSize, value, v => _model.TransferBufferSize = v); }
    public double TransferSpeedLimitMBps { get => _model.TransferSpeedLimitMBps; set => Set(_model.TransferSpeedLimitMBps, value, v => _model.TransferSpeedLimitMBps = v); }
    public bool ShowFileTransferNotifications { get => _model.ShowFileTransferNotifications; set => Set(_model.ShowFileTransferNotifications, value, v => _model.ShowFileTransferNotifications = v); }
    public bool AutoRetryFailedTransfers { get => _model.AutoRetryFailedTransfers; set => Set(_model.AutoRetryFailedTransfers, value, v => _model.AutoRetryFailedTransfers = v); }
    public bool KeepTransferHistory { get => _model.KeepTransferHistory; set => Set(_model.KeepTransferHistory, value, v => _model.KeepTransferHistory = v); }
    public bool KeepSystemAwakeDuringTransfer { get => _model.KeepSystemAwakeDuringTransfer; set => Set(_model.KeepSystemAwakeDuringTransfer, value, v => _model.KeepSystemAwakeDuringTransfer = v); }
    public bool ScanTransferFilesForVirus { get => _model.ScanTransferFilesForVirus; set => Set(_model.ScanTransferFilesForVirus, value, v => _model.ScanTransferFilesForVirus = v); }
    public string ScanLevel { get => _model.ScanLevel; set => Set(_model.ScanLevel, value, v => _model.ScanLevel = v); }

    // ---- Remote Desktop --------------------------------------------------------------
    public string VideoResolution { get => _model.VideoResolution; set => Set(_model.VideoResolution, value, v => _model.VideoResolution = v); }
    public string VideoFrameRate { get => _model.VideoFrameRate; set => Set(_model.VideoFrameRate, value, v => _model.VideoFrameRate = v); }
    public string VideoCompressionQuality { get => _model.VideoCompressionQuality; set => Set(_model.VideoCompressionQuality, value, v => _model.VideoCompressionQuality = v); }
    public bool EnableHardwareAcceleration { get => _model.EnableHardwareAcceleration; set => Set(_model.EnableHardwareAcceleration, value, v => _model.EnableHardwareAcceleration = v); }
    public bool EnableAdaptiveBitrate { get => _model.EnableAdaptiveBitrate; set => Set(_model.EnableAdaptiveBitrate, value, v => _model.EnableAdaptiveBitrate = v); }
    public double RdCompressionLevelDisplay { get => _model.RdCompressionLevelDisplay; set => Set(_model.RdCompressionLevelDisplay, value, v => _model.RdCompressionLevelDisplay = v); }
    public bool RdFullScreenMode { get => _model.RdFullScreenMode; set => Set(_model.RdFullScreenMode, value, v => _model.RdFullScreenMode = v); }
    public bool EnableClipboardSync { get => _model.EnableClipboardSync; set => Set(_model.EnableClipboardSync, value, v => _model.EnableClipboardSync = v); }
    public bool EnableRemoteFileTransfer { get => _model.EnableRemoteFileTransfer; set => Set(_model.EnableRemoteFileTransfer, value, v => _model.EnableRemoteFileTransfer = v); }
    public double MouseSensitivity { get => _model.MouseSensitivity; set => Set(_model.MouseSensitivity, value, v => _model.MouseSensitivity = v); }
    public int DoubleClickInterval { get => _model.DoubleClickInterval; set => Set(_model.DoubleClickInterval, value, v => _model.DoubleClickInterval = v); }
    public bool RdEnableAdaptiveQuality { get => _model.RdEnableAdaptiveQuality; set => Set(_model.RdEnableAdaptiveQuality, value, v => _model.RdEnableAdaptiveQuality = v); }
    public bool RdEnableUDPTransport { get => _model.RdEnableUDPTransport; set => Set(_model.RdEnableUDPTransport, value, v => _model.RdEnableUDPTransport = v); }
    public int RdNetworkCompressionLevel { get => _model.RdNetworkCompressionLevel; set => Set(_model.RdNetworkCompressionLevel, value, v => _model.RdNetworkCompressionLevel = v); }
    public double RdBandwidthLimit { get => _model.RdBandwidthLimit; set => Set(_model.RdBandwidthLimit, value, v => _model.RdBandwidthLimit = v); }
    public int RdBufferSize { get => _model.RdBufferSize; set => Set(_model.RdBufferSize, value, v => _model.RdBufferSize = v); }

    // ---- System Monitor --------------------------------------------------------------
    public double SystemMonitorRefreshInterval { get => _model.SystemMonitorRefreshInterval; set => Set(_model.SystemMonitorRefreshInterval, value, v => _model.SystemMonitorRefreshInterval = v); }
    public bool EnableAutoRefresh { get => _model.EnableAutoRefresh; set => Set(_model.EnableAutoRefresh, value, v => _model.EnableAutoRefresh = v); }
    public bool ShowTrendIndicators { get => _model.ShowTrendIndicators; set => Set(_model.ShowTrendIndicators, value, v => _model.ShowTrendIndicators = v); }
    public bool EnablePerformanceAlerts { get => _model.EnablePerformanceAlerts; set => Set(_model.EnablePerformanceAlerts, value, v => _model.EnablePerformanceAlerts = v); }
    public int SystemMonitorRetentionDays { get => _model.SystemMonitorRetentionDays; set => Set(_model.SystemMonitorRetentionDays, value, v => _model.SystemMonitorRetentionDays = v); }
    public double MaxHistoryPoints { get => _model.MaxHistoryPoints; set => Set(_model.MaxHistoryPoints, value, v => _model.MaxHistoryPoints = v); }
    public bool ShowMonitorCPU { get => _model.ShowMonitorCPU; set => Set(_model.ShowMonitorCPU, value, v => _model.ShowMonitorCPU = v); }
    public bool ShowMonitorMemory { get => _model.ShowMonitorMemory; set => Set(_model.ShowMonitorMemory, value, v => _model.ShowMonitorMemory = v); }
    public bool ShowMonitorDisk { get => _model.ShowMonitorDisk; set => Set(_model.ShowMonitorDisk, value, v => _model.ShowMonitorDisk = v); }
    public bool ShowMonitorNetwork { get => _model.ShowMonitorNetwork; set => Set(_model.ShowMonitorNetwork, value, v => _model.ShowMonitorNetwork = v); }
    public bool ShowMonitorTemperature { get => _model.ShowMonitorTemperature; set => Set(_model.ShowMonitorTemperature, value, v => _model.ShowMonitorTemperature = v); }
    public bool ShowMonitorFanSpeed { get => _model.ShowMonitorFanSpeed; set => Set(_model.ShowMonitorFanSpeed, value, v => _model.ShowMonitorFanSpeed = v); }
    public string SystemMonitorChartType { get => _model.SystemMonitorChartType; set => Set(_model.SystemMonitorChartType, value, v => _model.SystemMonitorChartType = v); }
    public double CpuThreshold { get => _model.CpuThreshold; set => Set(_model.CpuThreshold, value, v => _model.CpuThreshold = v); }
    public double MemoryThreshold { get => _model.MemoryThreshold; set => Set(_model.MemoryThreshold, value, v => _model.MemoryThreshold = v); }
    public bool EnableTemperatureMonitoring { get => _model.EnableTemperatureMonitoring; set => Set(_model.EnableTemperatureMonitoring, value, v => _model.EnableTemperatureMonitoring = v); }
    public double TemperatureThreshold { get => _model.TemperatureThreshold; set => Set(_model.TemperatureThreshold, value, v => _model.TemperatureThreshold = v); }
    public bool EnableFanSpeedMonitoring { get => _model.EnableFanSpeedMonitoring; set => Set(_model.EnableFanSpeedMonitoring, value, v => _model.EnableFanSpeedMonitoring = v); }
    public double FanSpeedThreshold { get => _model.FanSpeedThreshold; set => Set(_model.FanSpeedThreshold, value, v => _model.FanSpeedThreshold = v); }
    public double DiskThreshold { get => _model.DiskThreshold; set => Set(_model.DiskThreshold, value, v => _model.DiskThreshold = v); }
    public bool EnableSoundAlerts { get => _model.EnableSoundAlerts; set => Set(_model.EnableSoundAlerts, value, v => _model.EnableSoundAlerts = v); }
    public bool EnableSystemNotifications { get => _model.EnableSystemNotifications; set => Set(_model.EnableSystemNotifications, value, v => _model.EnableSystemNotifications = v); }
    public bool EnableThermalThrottlingAlert { get => _model.EnableThermalThrottlingAlert; set => Set(_model.EnableThermalThrottlingAlert, value, v => _model.EnableThermalThrottlingAlert = v); }
    public bool EnableRemoteMonitoring { get => _model.EnableRemoteMonitoring; set => Set(_model.EnableRemoteMonitoring, value, v => _model.EnableRemoteMonitoring = v); }
    public string SystemMonitorSamplingPrecision { get => _model.SystemMonitorSamplingPrecision; set => Set(_model.SystemMonitorSamplingPrecision, value, v => _model.SystemMonitorSamplingPrecision = v); }

    // ---- Advanced --------------------------------------------------------------------
    public bool EnableVerboseLogging { get => _model.EnableVerboseLogging; set => Set(_model.EnableVerboseLogging, value, v => _model.EnableVerboseLogging = v); }
    public bool ShowDebugInfo { get => _model.ShowDebugInfo; set => Set(_model.ShowDebugInfo, value, v => _model.ShowDebugInfo = v); }
    public bool SaveNetworkLogs { get => _model.SaveNetworkLogs; set => Set(_model.SaveNetworkLogs, value, v => _model.SaveNetworkLogs = v); }
    public string LogLevel { get => _model.LogLevel; set => Set(_model.LogLevel, value, v => _model.LogLevel = v); }
    public string PerformanceMode { get => _model.PerformanceMode; set => Set(_model.PerformanceMode, value, v => _model.PerformanceMode = v); }
    public bool EnableRealTimeWeather { get => _model.EnableRealTimeWeather; set => Set(_model.EnableRealTimeWeather, value, v => _model.EnableRealTimeWeather = v); }
    public bool ShowRealtimeFPS { get => _model.ShowRealtimeFPS; set => Set(_model.ShowRealtimeFPS, value, v => _model.ShowRealtimeFPS = v); }
    public bool EnableHardwareAccelerationGlobal { get => _model.EnableHardwareAccelerationGlobal; set => Set(_model.EnableHardwareAccelerationGlobal, value, v => _model.EnableHardwareAccelerationGlobal = v); }
    public bool OptimizeMemoryUsage { get => _model.OptimizeMemoryUsage; set => Set(_model.OptimizeMemoryUsage, value, v => _model.OptimizeMemoryUsage = v); }
    public bool EnableBackgroundScanning { get => _model.EnableBackgroundScanning; set => Set(_model.EnableBackgroundScanning, value, v => _model.EnableBackgroundScanning = v); }
    public bool EnableIPv6Support { get => _model.EnableIPv6Support; set => Set(_model.EnableIPv6Support, value, v => _model.EnableIPv6Support = v); }
    public bool UseNewDiscoveryAlgorithm { get => _model.UseNewDiscoveryAlgorithm; set => Set(_model.UseNewDiscoveryAlgorithm, value, v => _model.UseNewDiscoveryAlgorithm = v); }
    public bool EnableP2PDirectConnection { get => _model.EnableP2PDirectConnection; set => Set(_model.EnableP2PDirectConnection, value, v => _model.EnableP2PDirectConnection = v); }
    public string PqcSignatureAlgorithm { get => _model.PqcSignatureAlgorithm; set => Set(_model.PqcSignatureAlgorithm, value, v => _model.PqcSignatureAlgorithm = v); }
    public bool PreferXWingHybrid { get => _model.PreferXWingHybrid; set => Set(_model.PreferXWingHybrid, value, v => _model.PreferXWingHybrid = v); }
    public double SignalStrengthAlpha { get => _model.SignalStrengthAlpha; set => Set(_model.SignalStrengthAlpha, value, v => _model.SignalStrengthAlpha = v); }

    // ---- Bulk operations -------------------------------------------------------------

    /// <summary>
    /// Export the current settings to a user-chosen path. Returns true on success. Forces a
    /// pending debounced save to flush first so the export reflects the latest in-memory state.
    /// </summary>
    public bool ExportTo(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        try
        {
            FlushSave();
            _store.ExportTo(path, _model.Clone());
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Import settings from a user-chosen path, replacing the live model. Returns true on a
    /// successful, schema-valid import (and persists + raises a bulk change). On any failure the
    /// current settings are left untouched and false is returned.
    /// </summary>
    public bool ImportFrom(string path)
    {
        var imported = _store.ImportFrom(path);
        if (imported is null)
        {
            return false;
        }

        ReplaceModel(imported);
        return true;
    }

    /// <summary>
    /// Reset all settings to their defaults: delete the on-disk file and swap in a fresh-default
    /// model, then notify (a single bulk PropertyChanged with a null name = "everything changed").
    /// </summary>
    public void Reset()
    {
        _store.Reset();
        ReplaceModel(new SkyBridgeSettings());
    }

    private void ReplaceModel(SkyBridgeSettings next)
    {
        lock (_sync)
        {
            _model = next;
        }

        // null property name = "all properties changed" — every binding re-reads.
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        SettingsChanged?.Invoke(this, new SettingsChangedEventArgs(string.Empty));
        ScheduleSave();
    }

    private static bool ArrayEquals(string[] a, string[] b)
    {
        if (ReferenceEquals(a, b))
        {
            return true;
        }

        if (a.Length != b.Length)
        {
            return false;
        }

        for (var i = 0; i < a.Length; i++)
        {
            if (!string.Equals(a[i], b[i], StringComparison.Ordinal))
            {
                return false;
            }
        }

        return true;
    }

    public void Dispose()
    {
        Timer? timer;
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            timer = _saveTimer;
            _saveTimer = null;
        }

        // Flush any pending debounced write so a change made in the last 300 ms before close is
        // not lost, then release the timer.
        timer?.Dispose();
        _store.Save(_model.Clone());
    }
}

/// <summary>Carries the name of the settings property that changed (empty == bulk/all).</summary>
public sealed class SettingsChangedEventArgs : EventArgs
{
    public SettingsChangedEventArgs(string propertyName)
    {
        PropertyName = propertyName;
    }

    public string PropertyName { get; }
}
