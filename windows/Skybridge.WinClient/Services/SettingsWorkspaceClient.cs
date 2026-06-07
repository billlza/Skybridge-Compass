using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface ISettingsWorkspaceClient
{
    Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync();
}

public sealed class SettingsWorkspaceClient : ISettingsWorkspaceClient
{
    public Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        return Task.FromResult(new SettingsWorkspaceSnapshot(
            DateTimeOffset.UtcNow,
            BuildTabs(),
            BuildActions(),
            BuildDetails()));
    }

    private static IReadOnlyList<SettingsTabItem> BuildTabs() =>
        new List<SettingsTabItem>
        {
            new("General", "Language, theme, notifications, scan interval"),
            new("Network", "Discovery, relay, bandwidth, transport policy"),
            new("Devices", "USB, nearby devices, trust display"),
            new("File Transfer", "defaultTransferPath, scanning, retry, history, encryption"),
            new("Remote Desktop", "videoQuality, interaction, clipboard, audio, network"),
            new("System Monitor", "refreshInterval, history, alerts, thresholds"),
            new("Permissions", "Device, notification, and system integration access"),
            new("Advanced", "PQC, diagnostics, logs, custom services")
        };

    private static IReadOnlyList<SettingsActionItem> BuildActions() =>
        new List<SettingsActionItem>
        {
            new("ExportSettings", "Export settings", "Disabled", "Only write a user-selected or temporary export file after persistence is wired."),
            new("ImportSettings", "Import settings", "Disabled", "Validate file format before writing preferences."),
            new("ResetSettings", "Reset settings", "Disabled", "Destructive reset requires confirmation and scoped defaults."),
            new("RefreshSettingsStatus", "Refresh Status", "Ready", "Read-only snapshot can be refreshed safely."),
            new("RequestPermission", "Request Permission", "Disabled", "Permission prompts are high-risk platform writes."),
            new("OpenSystemPreferences", "Open System Preferences", "Disabled", "Windows Settings deep link requires explicit user click."),
            new("ApplyFileTransferSettings", "Apply file transfer settings", "Disabled", "Separate saved preferences from runtime updateReceiveDirectory/apply bridge."),
            new("ApplyRemoteDesktopSettings", "Apply remote desktop settings", "Disabled", "Runtime session settings must be applied explicitly."),
            new("RestoreDefaults", "Restore Defaults", "Disabled", "Default restore is a destructive preference write."),
            new("ResetMonitorData", "Reset Monitor Data", "Disabled", "Monitor retention store deletion requires explicit confirmation."),
            new("ClearHistoryData", "Clear History Data", "Disabled", "History deletion must never run from toggle or refresh paths.")
        };

    private static IReadOnlyList<SettingsDetailItem> BuildDetails() =>
        new List<SettingsDetailItem>
        {
            new("General", "Theme", "System", "Theme color and compact mode are visible but not persisted."),
            new("General", "Notifications", "Pending", "Notification permission request remains disabled."),
            new("Network", "Transport policy", "Core-owned", "Transport selection remains in Rust Core contracts."),
            new("Network", "Relay policy", "Pending", "TURN/signaling credentials must not be hardcoded."),
            new("Devices", "USB provider", "Read-only", "USB Management currently scans removable storage only."),
            new("File Transfer", "defaultTransferPath", "Pending", "Select receive directory is visible; saving path is pending."),
            new("File Transfer", "maxConcurrentConnections", "Pending", "Runtime concurrency must be applied through the file-transfer settings bridge."),
            new("File Transfer", "transferBufferSize", "Pending", "Buffer size is a saved preference until runtime apply is wired."),
            new("File Transfer", "autoRetryFailedTransfers", "Pending", "Retry policy is visible but not persisted."),
            new("File Transfer", "keepTransferHistory", "Pending", "History retention needs a store before mutation."),
            new("File Transfer", "keepSystemAwakeDuringTransfer", "Pending", "Power requests require explicit runtime ownership."),
            new("File Transfer", "scanTransferFilesForVirus", "Pending", "Malware scanning provider is not wired."),
            new("File Transfer", "scanLevel", "Pending", "Scan level must be validated before persistence."),
            new("File Transfer", "encryptionAlgorithm", "Core-owned", "HMAC/signature and crypto policy remain Core/provider-owned."),
            new("Video Transfer", "currentConfig", "Read-only", "Optimization summary only; no encoder settings are changed."),
            new("Video Transfer", "optimized / needsAdjust", "Read-only", "Validation warnings remain display-only."),
            new("Video Transfer", "estimatedRate", "Read-only", "Estimated bitrate is not pushed to runtime."),
            new("Video Transfer", "load.high/medium/low", "Visible", "Load labels mirror mac settings status."),
            new("Video Transfer", "resolution 1080p/2k/4k/5k", "Visible", "Resolution choices are not persisted yet."),
            new("Video Transfer", "framerate 30/60/120 fps", "Visible", "Framerate choices are not persisted yet."),
            new("Video Transfer", "preset balanced/highPerformance/highQuality/lowLatency", "Visible", "Preset choices are not persisted yet."),
            new("Video Transfer", "compression none/fast/balanced/maximum", "Visible", "Compression choices are not persisted yet."),
            new("Remote Desktop", "videoQuality", "Visible", "Quality controls are visible; live application is pending."),
            new("Remote Desktop", "compressionLevel", "Pending", "Compression is not applied to live sessions yet."),
            new("Remote Desktop", "refreshRate", "Pending", "Refresh rate is not applied to live sessions yet."),
            new("Remote Desktop", "enableAdaptiveQuality", "Pending", "Adaptive quality needs transport metrics."),
            new("Remote Desktop", "fullScreenMode", "Visible", "Fullscreen button remains disabled until live session windowing is wired."),
            new("Remote Desktop", "clipboardSync", "Pending", "Clipboard channel requires pairing/trust verification."),
            new("Remote Desktop", "audioRedirection", "Pending", "Audio redirection provider is not wired."),
            new("Remote Desktop", "fileTransfer", "Pending", "File-transfer bridge remains separate from remote desktop settings."),
            new("Remote Desktop", "trackpadGestures", "Pending", "Input forwarding is disabled."),
            new("Remote Desktop", "mouseSensitivity", "Pending", "Input scaling is not applied to runtime."),
            new("Remote Desktop", "doubleClickInterval", "Pending", "Input timing is not applied to runtime."),
            new("Remote Desktop", "enableUDP", "Core-owned", "Transport policy remains Core-owned."),
            new("Remote Desktop", "bandwidthLimit", "Pending", "Bandwidth governor is not wired."),
            new("Remote Desktop", "bufferSize", "Pending", "Network buffers are not applied to runtime."),
            new("System Monitor", "Runtime", RuntimeInformation.FrameworkDescription, RuntimeInformation.OSDescription),
            new("System Monitor", "refreshInterval", "Visible", "ETW/EventSource sampling is pending."),
            new("System Monitor", "enableAutoRefresh", "Disabled", "Auto refresh does not start background polling."),
            new("System Monitor", "showTrendIndicators/history", "Pending", "History retention store is not wired."),
            new("System Monitor", "enablePerformanceAlerts", "Disabled", "Alerts require notification permissions and thresholds."),
            new("System Monitor", "retentionDays/maxHistoryPoints", "Pending", "Retention changes are destructive and gated."),
            new("System Monitor", "CPU/Memory/Disk/Network/Temperature/FanSpeed", "Visible", "Unsupported temperature/fan values are provider pending."),
            new("System Monitor", "cpu/memory/disk/temperature/fanSpeed thresholds", "Pending", "Thresholds are not persisted yet."),
            new("System Monitor", "enableSoundAlerts/enableNotifications", "Disabled", "Notification writes require explicit permission flow."),
            new("Permissions", "System access", "Disabled", "No permission prompt is issued by this workspace."),
            new("Advanced", "PQC policy", "Strict/Core-owned", "Suite IDs and fallback policy remain in Rust Core."),
            new("Advanced", "Diagnostics", "Text gates", "UI parity and service boundary scripts are the current acceptance checks.")
        };
}

public sealed record SettingsWorkspaceSnapshot(
    DateTimeOffset CapturedAt,
    IReadOnlyList<SettingsTabItem> Tabs,
    IReadOnlyList<SettingsActionItem> Actions,
    IReadOnlyList<SettingsDetailItem> Details);

public sealed record SettingsTabItem(
    string Title,
    string Detail);

public sealed record SettingsActionItem(
    string Key,
    string Title,
    string State,
    string Detail);

public sealed record SettingsDetailItem(
    string Section,
    string Label,
    string Value,
    string Detail);
