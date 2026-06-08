using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface ISettingsWorkspaceClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(SettingsWorkspaceSnapshot snapshot);

    string BuildCompletedStatusMessage();

    bool CanExportSettings();

    bool CanImportSettings();

    bool CanResetSettings();

    bool CanRequestPermission();

    bool CanOpenSystemPreferences();

    bool CanApplySettings();

    bool CanRestoreDefaults();

    bool CanResetMonitorData();

    string BuildExportSettingsPendingStatus();

    string BuildImportSettingsPendingStatus();

    string BuildResetSettingsPendingStatus();

    string BuildPermissionRequestPendingStatus();

    string BuildSystemPreferencesPendingStatus();

    string BuildApplySettingsPendingStatus();

    string BuildRestoreDefaultsPendingStatus();

    string BuildResetMonitorDataPendingStatus();

    Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync();

    Task<SettingsWorkspaceActionResult> BuildExportSettingsActionAsync();

    Task<SettingsWorkspaceActionResult> BuildImportSettingsActionAsync();

    Task<SettingsWorkspaceActionResult> BuildResetSettingsActionAsync();

    Task<SettingsWorkspaceActionResult> BuildPermissionRequestActionAsync();

    Task<SettingsWorkspaceActionResult> BuildSystemPreferencesActionAsync();

    Task<SettingsWorkspaceActionResult> BuildApplySettingsActionAsync();

    Task<SettingsWorkspaceActionResult> BuildRestoreDefaultsActionAsync();

    Task<SettingsWorkspaceActionResult> BuildResetMonitorDataActionAsync();
}

public interface ISettingsExportPreviewClient
{
    bool CanExportSettings();

    SettingsExportPreviewSnapshot CaptureSnapshot();

    SettingsWorkspaceActionResult BuildExportPreview();
}

public sealed class InMemorySettingsExportPreviewClient : ISettingsExportPreviewClient
{
    private readonly object _sync = new();
    private int _nextPreviewId;
    private string? _latestPreviewId;
    private DateTimeOffset? _latestPreviewAt;

    public bool CanExportSettings() => true;

    public SettingsExportPreviewSnapshot CaptureSnapshot()
    {
        lock (_sync)
        {
            return new SettingsExportPreviewSnapshot(
                _latestPreviewId is not null,
                _latestPreviewId,
                _latestPreviewAt,
                _nextPreviewId);
        }
    }

    public SettingsWorkspaceActionResult BuildExportPreview()
    {
        string previewId;
        lock (_sync)
        {
            _nextPreviewId++;
            previewId = $"SET-{_nextPreviewId:0000}";
            _latestPreviewId = previewId;
            _latestPreviewAt = DateTimeOffset.UtcNow;
        }

        return SettingsWorkspaceClient.BuildExportPreviewReadyActionResult(previewId);
    }
}

public sealed class SettingsWorkspaceClient : ISettingsWorkspaceClient
{
    private readonly ISettingsExportPreviewClient _exportPreviewClient;
    private readonly ISystemPreferencesLauncher _systemPreferencesLauncher;

    public SettingsWorkspaceClient()
        : this(new DisabledSystemPreferencesLauncher(), new InMemorySettingsExportPreviewClient())
    {
    }

    public SettingsWorkspaceClient(ISystemPreferencesLauncher systemPreferencesLauncher)
        : this(systemPreferencesLauncher, new InMemorySettingsExportPreviewClient())
    {
    }

    public SettingsWorkspaceClient(
        ISystemPreferencesLauncher systemPreferencesLauncher,
        ISettingsExportPreviewClient exportPreviewClient)
    {
        _systemPreferencesLauncher = systemPreferencesLauncher ?? throw new ArgumentNullException(nameof(systemPreferencesLauncher));
        _exportPreviewClient = exportPreviewClient ?? throw new ArgumentNullException(nameof(exportPreviewClient));
    }

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(SettingsWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanExportSettings() => _exportPreviewClient.CanExportSettings();

    public bool CanImportSettings() => false;

    public bool CanResetSettings() => false;

    public bool CanRequestPermission() => false;

    public bool CanOpenSystemPreferences() => _systemPreferencesLauncher.CanOpenSystemPreferences();

    public bool CanApplySettings() => false;

    public bool CanRestoreDefaults() => false;

    public bool CanResetMonitorData() => false;

    public string BuildExportSettingsPendingStatus() => DefaultExportSettingsPendingStatus;

    public string BuildImportSettingsPendingStatus() => DefaultImportSettingsPendingStatus;

    public string BuildResetSettingsPendingStatus() => DefaultResetSettingsPendingStatus;

    public string BuildPermissionRequestPendingStatus() => DefaultPermissionRequestPendingStatus;

    public string BuildSystemPreferencesPendingStatus() => DefaultSystemPreferencesPendingStatus;

    public string BuildApplySettingsPendingStatus() => DefaultApplySettingsPendingStatus;

    public string BuildRestoreDefaultsPendingStatus() => DefaultRestoreDefaultsPendingStatus;

    public string BuildResetMonitorDataPendingStatus() => DefaultResetMonitorDataPendingStatus;

    public static string DefaultInitialStatus { get; } = "Ready";

    public static string DefaultPendingStatus { get; } = "Refreshing...";

    public static string DefaultCompletedStatusMessage { get; } = "Settings workspace updated";

    public static string DefaultExportSettingsPendingStatus { get; } = "Preparing settings export...";

    public static string DefaultImportSettingsPendingStatus { get; } = "Preparing settings import...";

    public static string DefaultResetSettingsPendingStatus { get; } = "Preparing settings reset...";

    public static string DefaultPermissionRequestPendingStatus { get; } = "Preparing permission request...";

    public static string DefaultSystemPreferencesPendingStatus { get; } = "Preparing system preferences...";

    public static string DefaultApplySettingsPendingStatus { get; } = "Preparing settings apply...";

    public static string DefaultRestoreDefaultsPendingStatus { get; } = "Preparing default restore...";

    public static string DefaultResetMonitorDataPendingStatus { get; } = "Preparing monitor data reset...";

    public static string DefaultExportSettingsBlockedStatus { get; } = "Settings export unavailable";

    public static string DefaultExportSettingsPreviewReadyStatus { get; } = "Settings export preview ready";

    public static string DefaultImportSettingsBlockedStatus { get; } = "Settings import unavailable";

    public static string DefaultResetSettingsBlockedStatus { get; } = "Settings reset unavailable";

    public static string DefaultPermissionRequestBlockedStatus { get; } = "Permission request unavailable";

    public static string DefaultSystemPreferencesBlockedStatus { get; } = "System preferences unavailable";

    public static string DefaultApplySettingsBlockedStatus { get; } = "Settings apply unavailable";

    public static string DefaultRestoreDefaultsBlockedStatus { get; } = "Restore defaults unavailable";

    public static string DefaultResetMonitorDataBlockedStatus { get; } = "Monitor data reset unavailable";

    public static string DefaultExportSettingsBlockedMessage { get; } =
        "Settings export requires persisted preferences and an explicit user-selected destination.";

    public static string DefaultExportSettingsPreviewReadyMessage { get; } =
        "Settings export preview prepared in memory only; no file was written and no preference was changed.";

    public static string DefaultImportSettingsBlockedMessage { get; } =
        "Settings import requires file validation before writing preferences.";

    public static string DefaultResetSettingsBlockedMessage { get; } =
        "Settings reset is a destructive preference write that requires confirmation and scoped defaults.";

    public static string DefaultPermissionRequestBlockedMessage { get; } =
        "Permission prompts are high-risk platform writes and require an explicit provider.";

    public static string DefaultSystemPreferencesBlockedMessage { get; } =
        "Windows Settings deep links require SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES=enabled before opening system preferences.";

    public static string DefaultSystemPreferencesOpenedStatus { get; } = "System preferences opened";

    public static string DefaultSystemPreferencesOpenedMessage { get; } =
        "Opened Windows Settings through the explicit system-preferences launcher.";

    public static string DefaultSystemPreferencesLaunchFailedStatus { get; } = "System preferences launch failed";

    public static string DefaultApplySettingsBlockedMessage { get; } =
        "Runtime settings apply requires a persistence bridge and scoped runtime update providers.";

    public static string DefaultRestoreDefaultsBlockedMessage { get; } =
        "Restoring defaults is a destructive preference write that requires confirmation.";

    public static string DefaultResetMonitorDataBlockedMessage { get; } =
        "Monitor retention deletion requires a retention store and explicit confirmation.";

    public static string BuildDefaultCompletedStatus(SettingsWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public static SettingsWorkspaceActionResult BuildDefaultExportSettingsActionResult() =>
        new(DefaultExportSettingsBlockedStatus, DefaultExportSettingsBlockedMessage);

    public static SettingsWorkspaceActionResult BuildExportPreviewReadyActionResult(string previewId) =>
        new(
            DefaultExportSettingsPreviewReadyStatus,
            $"{DefaultExportSettingsPreviewReadyMessage} preview={NormalizeExportPreviewId(previewId)}");

    public static SettingsWorkspaceActionResult BuildDefaultImportSettingsActionResult() =>
        new(DefaultImportSettingsBlockedStatus, DefaultImportSettingsBlockedMessage);

    public static SettingsWorkspaceActionResult BuildDefaultResetSettingsActionResult() =>
        new(DefaultResetSettingsBlockedStatus, DefaultResetSettingsBlockedMessage);

    public static SettingsWorkspaceActionResult BuildDefaultPermissionRequestActionResult() =>
        new(DefaultPermissionRequestBlockedStatus, DefaultPermissionRequestBlockedMessage);

    public static SettingsWorkspaceActionResult BuildDefaultSystemPreferencesActionResult() =>
        new(DefaultSystemPreferencesBlockedStatus, DefaultSystemPreferencesBlockedMessage);

    public static SettingsWorkspaceActionResult BuildDefaultApplySettingsActionResult() =>
        new(DefaultApplySettingsBlockedStatus, DefaultApplySettingsBlockedMessage);

    public static SettingsWorkspaceActionResult BuildDefaultRestoreDefaultsActionResult() =>
        new(DefaultRestoreDefaultsBlockedStatus, DefaultRestoreDefaultsBlockedMessage);

    public static SettingsWorkspaceActionResult BuildDefaultResetMonitorDataActionResult() =>
        new(DefaultResetMonitorDataBlockedStatus, DefaultResetMonitorDataBlockedMessage);

    public Task<SettingsWorkspaceSnapshot> BuildReadOnlySnapshotAsync()
    {
        var exportPreview = _exportPreviewClient.CaptureSnapshot();
        return Task.FromResult(new SettingsWorkspaceSnapshot(
            DateTimeOffset.UtcNow,
            BuildTabs(),
            BuildActions(exportPreview),
            BuildDetails(exportPreview)));
    }

    public Task<SettingsWorkspaceActionResult> BuildExportSettingsActionAsync() =>
        Task.FromResult(_exportPreviewClient.BuildExportPreview());

    public Task<SettingsWorkspaceActionResult> BuildImportSettingsActionAsync() =>
        Task.FromResult(BuildDefaultImportSettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildResetSettingsActionAsync() =>
        Task.FromResult(BuildDefaultResetSettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildPermissionRequestActionAsync() =>
        Task.FromResult(BuildDefaultPermissionRequestActionResult());

    public Task<SettingsWorkspaceActionResult> BuildSystemPreferencesActionAsync() =>
        _systemPreferencesLauncher.OpenSystemPreferencesAsync();

    public Task<SettingsWorkspaceActionResult> BuildApplySettingsActionAsync() =>
        Task.FromResult(BuildDefaultApplySettingsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildRestoreDefaultsActionAsync() =>
        Task.FromResult(BuildDefaultRestoreDefaultsActionResult());

    public Task<SettingsWorkspaceActionResult> BuildResetMonitorDataActionAsync() =>
        Task.FromResult(BuildDefaultResetMonitorDataActionResult());

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

    private static IReadOnlyList<SettingsActionItem> BuildActions(SettingsExportPreviewSnapshot exportPreview) =>
        new List<SettingsActionItem>
        {
            new("ExportSettings", "Export settings", exportPreview.HasPreview ? "Preview ready" : "Ready", BuildExportPreviewDetail(exportPreview)),
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

    private static IReadOnlyList<SettingsDetailItem> BuildDetails(SettingsExportPreviewSnapshot exportPreview) =>
        new List<SettingsDetailItem>
        {
            new("General", "Theme", "System", "Theme color and compact mode are visible but not persisted."),
            new("General", "Notifications", "Pending", "Notification permission request remains disabled."),
            new("General", "Export preview", exportPreview.HasPreview ? NormalizeExportPreviewId(exportPreview.PreviewId) : "Ready", BuildExportPreviewDetail(exportPreview)),
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

    private static string BuildExportPreviewDetail(SettingsExportPreviewSnapshot exportPreview)
    {
        if (!exportPreview.HasPreview || !exportPreview.BuiltAt.HasValue)
        {
            return "Prepares a settings export preview in memory only; no destination file is opened or written.";
        }

        return $"preview={NormalizeExportPreviewId(exportPreview.PreviewId)}; built={exportPreview.BuiltAt.Value:HH:mm:ss} UTC; no file was written";
    }

    private static string NormalizeExportPreviewId(string? previewId)
    {
        var normalized = (previewId ?? "").Trim();
        return normalized.Length == 0 ? "SET-0000" : normalized;
    }
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

public sealed record SettingsExportPreviewSnapshot(
    bool HasPreview,
    string? PreviewId,
    DateTimeOffset? BuiltAt,
    int PreviewCount);

public sealed record SettingsWorkspaceActionResult(
    string Status,
    string Message);

public interface ISystemPreferencesLauncher
{
    bool CanOpenSystemPreferences();

    Task<SettingsWorkspaceActionResult> OpenSystemPreferencesAsync();
}

public sealed class DisabledSystemPreferencesLauncher : ISystemPreferencesLauncher
{
    public bool CanOpenSystemPreferences() => false;

    public Task<SettingsWorkspaceActionResult> OpenSystemPreferencesAsync() =>
        Task.FromResult(SettingsWorkspaceClient.BuildDefaultSystemPreferencesActionResult());
}

public sealed class WindowsSystemPreferencesLauncher : ISystemPreferencesLauncher
{
    private const string SettingsUri = "ms-settings:";

    public bool CanOpenSystemPreferences() => true;

    public Task<SettingsWorkspaceActionResult> OpenSystemPreferencesAsync()
    {
        try
        {
            Process.Start(new ProcessStartInfo(SettingsUri)
            {
                UseShellExecute = true
            });

            return Task.FromResult(new SettingsWorkspaceActionResult(
                SettingsWorkspaceClient.DefaultSystemPreferencesOpenedStatus,
                SettingsWorkspaceClient.DefaultSystemPreferencesOpenedMessage));
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return Task.FromResult(new SettingsWorkspaceActionResult(
                SettingsWorkspaceClient.DefaultSystemPreferencesLaunchFailedStatus,
                $"Windows Settings launch failed: {ex.Message}"));
        }
    }
}
