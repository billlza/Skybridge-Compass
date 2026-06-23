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

public interface ISettingsActionIntentClient
{
    bool CanImportSettings();

    bool CanResetSettings();

    bool CanRequestPermission();

    bool CanApplySettings();

    bool CanRestoreDefaults();

    bool CanResetMonitorData();

    SettingsActionIntentSnapshot CaptureSnapshot();

    SettingsWorkspaceActionResult BuildImportSettingsIntent();

    SettingsWorkspaceActionResult BuildResetSettingsIntent();

    SettingsWorkspaceActionResult BuildPermissionRequestIntent();

    SettingsWorkspaceActionResult BuildApplySettingsIntent();

    SettingsWorkspaceActionResult BuildRestoreDefaultsIntent();

    SettingsWorkspaceActionResult BuildResetMonitorDataIntent();
}

public sealed class InMemorySettingsActionIntentClient : ISettingsActionIntentClient
{
    private readonly object _sync = new();
    private int _nextIntentId;
    private string? _latestActionKey;
    private string? _latestIntentId;
    private DateTimeOffset? _latestIntentAt;

    public bool CanImportSettings() => true;

    public bool CanResetSettings() => true;

    public bool CanRequestPermission() => true;

    public bool CanApplySettings() => true;

    public bool CanRestoreDefaults() => true;

    public bool CanResetMonitorData() => true;

    public SettingsActionIntentSnapshot CaptureSnapshot()
    {
        lock (_sync)
        {
            return new SettingsActionIntentSnapshot(
                _latestActionKey is not null,
                _latestActionKey,
                _latestIntentId,
                _latestIntentAt,
                _nextIntentId);
        }
    }

    public SettingsWorkspaceActionResult BuildImportSettingsIntent() =>
        BuildIntent(
            "ImportSettings",
            "SET-IMPORT",
            SettingsWorkspaceClient.DefaultImportSettingsIntentReadyStatus,
            SettingsWorkspaceClient.DefaultImportSettingsIntentReadyMessage);

    public SettingsWorkspaceActionResult BuildResetSettingsIntent() =>
        BuildIntent(
            "ResetSettings",
            "SET-RESET",
            SettingsWorkspaceClient.DefaultResetSettingsIntentReadyStatus,
            SettingsWorkspaceClient.DefaultResetSettingsIntentReadyMessage);

    public SettingsWorkspaceActionResult BuildPermissionRequestIntent() =>
        BuildIntent(
            "RequestPermission",
            "SET-PERM",
            SettingsWorkspaceClient.DefaultPermissionRequestIntentReadyStatus,
            SettingsWorkspaceClient.DefaultPermissionRequestIntentReadyMessage);

    public SettingsWorkspaceActionResult BuildApplySettingsIntent() =>
        BuildIntent(
            "ApplySettings",
            "SET-APPLY",
            SettingsWorkspaceClient.DefaultApplySettingsIntentReadyStatus,
            SettingsWorkspaceClient.DefaultApplySettingsIntentReadyMessage);

    public SettingsWorkspaceActionResult BuildRestoreDefaultsIntent() =>
        BuildIntent(
            "RestoreDefaults",
            "SET-DEFAULTS",
            SettingsWorkspaceClient.DefaultRestoreDefaultsIntentReadyStatus,
            SettingsWorkspaceClient.DefaultRestoreDefaultsIntentReadyMessage);

    public SettingsWorkspaceActionResult BuildResetMonitorDataIntent() =>
        BuildIntent(
            "ResetMonitorData",
            "SET-MONITOR",
            SettingsWorkspaceClient.DefaultResetMonitorDataIntentReadyStatus,
            SettingsWorkspaceClient.DefaultResetMonitorDataIntentReadyMessage);

    private SettingsWorkspaceActionResult BuildIntent(
        string actionKey,
        string intentPrefix,
        string status,
        string message)
    {
        string intentId;
        lock (_sync)
        {
            _nextIntentId++;
            intentId = $"{intentPrefix}-{_nextIntentId:0000}";
            _latestActionKey = actionKey;
            _latestIntentId = intentId;
            _latestIntentAt = DateTimeOffset.UtcNow;
        }

        return SettingsWorkspaceClient.BuildActionIntentReadyActionResult(status, message, intentId);
    }
}

public sealed class SettingsWorkspaceClient : ISettingsWorkspaceClient
{
    private readonly ISettingsExportPreviewClient _exportPreviewClient;
    private readonly ISettingsActionIntentClient _actionIntentClient;
    private readonly ISystemPreferencesLauncher _systemPreferencesLauncher;

    public SettingsWorkspaceClient()
        : this(
            new DisabledSystemPreferencesLauncher(),
            new InMemorySettingsExportPreviewClient(),
            new InMemorySettingsActionIntentClient())
    {
    }

    public SettingsWorkspaceClient(ISystemPreferencesLauncher systemPreferencesLauncher)
        : this(
            systemPreferencesLauncher,
            new InMemorySettingsExportPreviewClient(),
            new InMemorySettingsActionIntentClient())
    {
    }

    public SettingsWorkspaceClient(
        ISystemPreferencesLauncher systemPreferencesLauncher,
        ISettingsExportPreviewClient exportPreviewClient)
        : this(
            systemPreferencesLauncher,
            exportPreviewClient,
            new InMemorySettingsActionIntentClient())
    {
    }

    public SettingsWorkspaceClient(
        ISystemPreferencesLauncher systemPreferencesLauncher,
        ISettingsExportPreviewClient exportPreviewClient,
        ISettingsActionIntentClient actionIntentClient)
    {
        _systemPreferencesLauncher = systemPreferencesLauncher ?? throw new ArgumentNullException(nameof(systemPreferencesLauncher));
        _exportPreviewClient = exportPreviewClient ?? throw new ArgumentNullException(nameof(exportPreviewClient));
        _actionIntentClient = actionIntentClient ?? throw new ArgumentNullException(nameof(actionIntentClient));
    }

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(SettingsWorkspaceSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public bool CanExportSettings() => _exportPreviewClient.CanExportSettings();

    public bool CanImportSettings() => _actionIntentClient.CanImportSettings();

    public bool CanResetSettings() => _actionIntentClient.CanResetSettings();

    public bool CanRequestPermission() => _actionIntentClient.CanRequestPermission();

    public bool CanOpenSystemPreferences() => _systemPreferencesLauncher.CanOpenSystemPreferences();

    public bool CanApplySettings() => _actionIntentClient.CanApplySettings();

    public bool CanRestoreDefaults() => _actionIntentClient.CanRestoreDefaults();

    public bool CanResetMonitorData() => _actionIntentClient.CanResetMonitorData();

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

    public static string DefaultImportSettingsIntentReadyStatus { get; } = "Settings import intent ready";

    public static string DefaultResetSettingsBlockedStatus { get; } = "Settings reset unavailable";

    public static string DefaultResetSettingsIntentReadyStatus { get; } = "Settings reset intent ready";

    public static string DefaultPermissionRequestBlockedStatus { get; } = "Permission request unavailable";

    public static string DefaultPermissionRequestIntentReadyStatus { get; } = "Permission request intent ready";

    public static string DefaultSystemPreferencesBlockedStatus { get; } = "System preferences unavailable";

    public static string DefaultApplySettingsBlockedStatus { get; } = "Settings apply unavailable";

    public static string DefaultApplySettingsIntentReadyStatus { get; } = "Settings apply intent ready";

    public static string DefaultRestoreDefaultsBlockedStatus { get; } = "Restore defaults unavailable";

    public static string DefaultRestoreDefaultsIntentReadyStatus { get; } = "Restore defaults intent ready";

    public static string DefaultResetMonitorDataBlockedStatus { get; } = "Monitor data reset unavailable";

    public static string DefaultResetMonitorDataIntentReadyStatus { get; } = "Monitor data reset intent ready";

    public static string DefaultExportSettingsBlockedMessage { get; } =
        "Settings export requires persisted preferences and an explicit user-selected destination.";

    public static string DefaultExportSettingsPreviewReadyMessage { get; } =
        "Settings export preview prepared in memory only; no file was written and no preference was changed.";

    public static string DefaultImportSettingsBlockedMessage { get; } =
        "Settings import requires file validation before writing preferences.";

    public static string DefaultImportSettingsIntentReadyMessage { get; } =
        "Settings import validation intent prepared in memory only; no file was opened, read, or written.";

    public static string DefaultResetSettingsBlockedMessage { get; } =
        "Settings reset is a destructive preference write that requires confirmation and scoped defaults.";

    public static string DefaultResetSettingsIntentReadyMessage { get; } =
        "Settings reset intent prepared in memory only; no preference was changed.";

    public static string DefaultPermissionRequestBlockedMessage { get; } =
        "Permission prompts are high-risk platform writes and require an explicit provider.";

    public static string DefaultPermissionRequestIntentReadyMessage { get; } =
        "Permission request intent prepared in memory only; no permission prompt was shown.";

    public static string DefaultSystemPreferencesBlockedMessage { get; } =
        "Windows Settings deep links require SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES=enabled before opening system preferences.";

    public static string DefaultSystemPreferencesOpenedStatus { get; } = "System preferences opened";

    public static string DefaultSystemPreferencesOpenedMessage { get; } =
        "Opened Windows Settings through the explicit system-preferences launcher.";

    public static string DefaultSystemPreferencesLaunchFailedStatus { get; } = "System preferences launch failed";

    public static string DefaultApplySettingsBlockedMessage { get; } =
        "Runtime settings apply requires a persistence bridge and scoped runtime update providers.";

    public static string DefaultApplySettingsIntentReadyMessage { get; } =
        "Settings apply intent prepared in memory only; no runtime settings were applied.";

    public static string DefaultRestoreDefaultsBlockedMessage { get; } =
        "Restoring defaults is a destructive preference write that requires confirmation.";

    public static string DefaultRestoreDefaultsIntentReadyMessage { get; } =
        "Restore defaults intent prepared in memory only; no defaults were restored.";

    public static string DefaultResetMonitorDataBlockedMessage { get; } =
        "Monitor retention deletion requires a retention store and explicit confirmation.";

    public static string DefaultResetMonitorDataIntentReadyMessage { get; } =
        "Monitor data reset intent prepared in memory only; no monitor data was deleted.";

    public static string BuildDefaultCompletedStatus(SettingsWorkspaceSnapshot snapshot) =>
        $"Snapshot {snapshot.CapturedAt:HH:mm:ss} UTC";

    public static SettingsWorkspaceActionResult BuildDefaultExportSettingsActionResult() =>
        new(DefaultExportSettingsBlockedStatus, DefaultExportSettingsBlockedMessage);

    public static SettingsWorkspaceActionResult BuildExportPreviewReadyActionResult(string previewId) =>
        new(
            DefaultExportSettingsPreviewReadyStatus,
            $"{DefaultExportSettingsPreviewReadyMessage} preview={NormalizeExportPreviewId(previewId)}");

    public static SettingsWorkspaceActionResult BuildActionIntentReadyActionResult(
        string status,
        string message,
        string intentId) =>
        new(status, $"{message} intent={NormalizeSettingsActionIntentId(intentId)}");

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
        var actionIntent = _actionIntentClient.CaptureSnapshot();
        return Task.FromResult(new SettingsWorkspaceSnapshot(
            DateTimeOffset.UtcNow,
            BuildTabs(),
            BuildActions(exportPreview, actionIntent),
            BuildDetails(exportPreview, actionIntent)));
    }

    public Task<SettingsWorkspaceActionResult> BuildExportSettingsActionAsync() =>
        Task.FromResult(_exportPreviewClient.BuildExportPreview());

    public Task<SettingsWorkspaceActionResult> BuildImportSettingsActionAsync() =>
        Task.FromResult(_actionIntentClient.BuildImportSettingsIntent());

    public Task<SettingsWorkspaceActionResult> BuildResetSettingsActionAsync() =>
        Task.FromResult(_actionIntentClient.BuildResetSettingsIntent());

    public Task<SettingsWorkspaceActionResult> BuildPermissionRequestActionAsync() =>
        Task.FromResult(_actionIntentClient.BuildPermissionRequestIntent());

    public Task<SettingsWorkspaceActionResult> BuildSystemPreferencesActionAsync() =>
        _systemPreferencesLauncher.OpenSystemPreferencesAsync();

    public Task<SettingsWorkspaceActionResult> BuildApplySettingsActionAsync() =>
        Task.FromResult(_actionIntentClient.BuildApplySettingsIntent());

    public Task<SettingsWorkspaceActionResult> BuildRestoreDefaultsActionAsync() =>
        Task.FromResult(_actionIntentClient.BuildRestoreDefaultsIntent());

    public Task<SettingsWorkspaceActionResult> BuildResetMonitorDataActionAsync() =>
        Task.FromResult(_actionIntentClient.BuildResetMonitorDataIntent());

    private static IReadOnlyList<SettingsTabItem> BuildTabs() =>
        new List<SettingsTabItem>
        {
            new("General", "通用 · Language, Preferences, Interface, Data management"),
            new("Network", "网络 · Wi-Fi, Discovery, Top bar, Connection"),
            new("Devices", "设备 · Bluetooth, AirPlay, Filters (display-only on Windows)"),
            new("File Transfer", "文件传输 · Config, Options, Security"),
            new("Remote Desktop", "远程桌面 · Video transfer, Display, Interaction, Network"),
            new("System Monitor", "系统监控 · Config, Display, Alerts, Advanced"),
            new("Permissions", "权限 · Status, Details, Help (no prompt issued by Windows client)"),
            new("Advanced", "高级 · Debug, Performance, Experimental, PQC, Smoothing, Reset")
        };

    private static IReadOnlyList<SettingsActionItem> BuildActions(
        SettingsExportPreviewSnapshot exportPreview,
        SettingsActionIntentSnapshot actionIntent) =>
        new List<SettingsActionItem>
        {
            new("ExportSettings", "Export settings", exportPreview.HasPreview ? "Preview ready" : "Ready", BuildExportPreviewDetail(exportPreview)),
            new("ImportSettings", "Import settings", BuildActionIntentState(actionIntent, "ImportSettings"), BuildActionIntentDetail(actionIntent, "ImportSettings", "Prepares a settings import validation intent in memory only; no file is opened, read, or written.")),
            new("ResetSettings", "Reset settings", BuildActionIntentState(actionIntent, "ResetSettings"), BuildActionIntentDetail(actionIntent, "ResetSettings", "Prepares a reset intent in memory only; no preference is changed.")),
            new("RefreshSettingsStatus", "Refresh Status", "Ready", "Read-only snapshot can be refreshed safely."),
            new("RequestPermission", "Request Permission", BuildActionIntentState(actionIntent, "RequestPermission"), BuildActionIntentDetail(actionIntent, "RequestPermission", "Prepares a permission-request intent in memory only; no permission prompt is shown.")),
            new("OpenSystemPreferences", "Open System Preferences", "Disabled", "Windows Settings deep link requires explicit user click."),
            new("ApplyFileTransferSettings", "Apply file transfer settings", BuildActionIntentState(actionIntent, "ApplySettings"), BuildActionIntentDetail(actionIntent, "ApplySettings", "Prepares a runtime-apply intent in memory only; no runtime setting is changed.")),
            new("ApplyRemoteDesktopSettings", "Apply remote desktop settings", BuildActionIntentState(actionIntent, "ApplySettings"), BuildActionIntentDetail(actionIntent, "ApplySettings", "Prepares a runtime-apply intent in memory only; no live session setting is changed.")),
            new("RestoreDefaults", "Restore Defaults", BuildActionIntentState(actionIntent, "RestoreDefaults"), BuildActionIntentDetail(actionIntent, "RestoreDefaults", "Prepares a restore-defaults intent in memory only; no defaults are restored.")),
            new("ResetMonitorData", "Reset Monitor Data", BuildActionIntentState(actionIntent, "ResetMonitorData"), BuildActionIntentDetail(actionIntent, "ResetMonitorData", "Prepares a monitor-data reset intent in memory only; no monitor data is deleted.")),
            new("ClearHistoryData", "Clear History Data", "Disabled", "History deletion must never run from toggle or refresh paths.")
        };

    // Honest, deterministic read-only constants used across the detail rows.
    // "Default" = the value mac SettingsView shows out of the box; on Windows it is DISPLAY-ONLY
    // (the snapshot is read-only and there is no Windows settings store behind it yet).
    private const string DisplayOnly = "Display-only";
    private const string ReadOnly = "Read-only";
    private const string CoreOwned = "Core-owned";
    private const string NotPersisted = "Not persisted";
    private const string NotWired = "Not wired";

    private static IReadOnlyList<SettingsDetailItem> BuildDetails(
        SettingsExportPreviewSnapshot exportPreview,
        SettingsActionIntentSnapshot actionIntent)
    {
        var details = new List<SettingsDetailItem>();
        AppendGeneral(details, exportPreview, actionIntent);
        AppendNetwork(details);
        AppendDevices(details);
        AppendFileTransfer(details);
        AppendRemoteDesktop(details);
        AppendSystemMonitor(details);
        AppendPermissions(details);
        AppendAdvanced(details);
        return details;
    }

    // ---- TAB 1: General / 通用 ----
    private static void AppendGeneral(
        List<SettingsDetailItem> d,
        SettingsExportPreviewSnapshot exportPreview,
        SettingsActionIntentSnapshot actionIntent)
    {
        // Card: Language / 语言
        d.Add(new("General", "Language · Language / 语言", "System (default)", "Mirrors mac default. Language picker is display-only; no app-language override is persisted on Windows."));
        // Card: Preferences / 偏好
        d.Add(new("General", "Preferences · Auto scan on startup", "On (default)", DisplayOnly + ". Auto-scan toggle reflects the mac default; Windows discovery start remains user/command driven."));
        d.Add(new("General", "Preferences · System notifications", "On (default)", DisplayOnly + ". No notification permission is requested by this workspace."));
        d.Add(new("General", "Preferences · Dark mode", "Off (default)", DisplayOnly + ". Theme follows the host shell; this toggle is not persisted."));
        d.Add(new("General", "Preferences · Scan interval", "30s (default · 15/30/60/120)", DisplayOnly + ". Interval choice is not persisted to a Windows store."));
        // Card: Interface / 界面
        d.Add(new("General", "Interface · Show device details", "On (default)", DisplayOnly + ". Layout preference is not persisted."));
        d.Add(new("General", "Interface · Show connection stats", "On (default)", DisplayOnly + ". Layout preference is not persisted."));
        d.Add(new("General", "Interface · Compact mode", "Off (default)", DisplayOnly + ". Layout preference is not persisted."));
        d.Add(new("General", "Interface · Theme color", "Blue (default)", DisplayOnly + ". Accent color is not persisted."));
        // Card: Data management / 数据管理
        d.Add(new("General", "Data management · Clear cache", "Cache size unknown", NotWired + ". No cache store is measured or cleared by this workspace."));
        d.Add(new("General", "Data management · Export settings", exportPreview.HasPreview ? NormalizeExportPreviewId(exportPreview.PreviewId) : "Ready", BuildExportPreviewDetail(exportPreview)));
        d.Add(new("General", "Data management · Import settings", BuildActionIntentState(actionIntent, "ImportSettings"), BuildActionIntentDetail(actionIntent, "ImportSettings", "Import is an in-memory validation intent only; no file is opened, read, or written.")));
        d.Add(new("General", "Data management · Reset settings", BuildActionIntentState(actionIntent, "ResetSettings"), BuildActionIntentDetail(actionIntent, "ResetSettings", "Reset prepares an in-memory intent only; no preference is changed.")));
        d.Add(new("General", "Data management · Deduplicate keychain", "macOS-only", "Keychain deduplication is an Apple-keychain operation; not applicable on Windows."));
        // Live snapshot rows (real, deterministic)
        d.Add(new("General", "Workspace · Latest settings action", BuildLatestActionIntentValue(actionIntent), BuildLatestActionIntentDetail(actionIntent)));
    }

    // ---- TAB 2: Network / 网络 ----
    private static void AppendNetwork(List<SettingsDetailItem> d)
    {
        // Card: Wi-Fi
        d.Add(new("Network", "Wi-Fi · Current network", "Not reported", DisplayOnly + ". Windows SSID/refresh status is not surfaced through this workspace."));
        d.Add(new("Network", "Wi-Fi · Auto-connect known networks", "On (default)", DisplayOnly + ". OS owns Wi-Fi association; toggle is not persisted."));
        d.Add(new("Network", "Wi-Fi · Show hidden networks", "Off (default)", DisplayOnly + "."));
        d.Add(new("Network", "Wi-Fi · Prefer 5 GHz", "On (default)", DisplayOnly + ". Band selection is OS-owned."));
        d.Add(new("Network", "Wi-Fi · Scan timeout", "10s (default · 5/10/15/30)", DisplayOnly + ". Not persisted."));
        // Card: Discovery / 发现
        d.Add(new("Network", "Discovery · Enable Bonjour", "On (default)", DisplayOnly + ". Windows uses DNS-SD browse; this toggle is not persisted."));
        d.Add(new("Network", "Discovery · Enable mDNS resolution", "On (default)", DisplayOnly + "."));
        d.Add(new("Network", "Discovery · Scan custom ports", "Off (default)", DisplayOnly + "."));
        d.Add(new("Network", "Discovery · Discovery timeout", "30s (default)", DisplayOnly + ". Not persisted."));
        d.Add(new("Network", "Discovery · Custom service types", "Empty (default)", DisplayOnly + ". No custom service-type list is stored on Windows."));
        // Card: Top bar / 顶栏
        d.Add(new("Network", "Top bar · Show IP location", "On (default)", DisplayOnly + ". Mirrors the top-bar status surface."));
        d.Add(new("Network", "Top bar · Show network speed", "On (default)", DisplayOnly + "."));
        d.Add(new("Network", "Top bar · Show network latency", "On (default)", DisplayOnly + "."));
        // Card: Connection / 连接
        d.Add(new("Network", "Connection · Connection timeout", "10s (default)", DisplayOnly + ". Not persisted."));
        d.Add(new("Network", "Connection · Retry count", "3 (default)", DisplayOnly + ". Not persisted."));
        d.Add(new("Network", "Connection · Transport policy", CoreOwned, "Transport/relay selection remains in Rust Core contracts; not user-settable here."));
        d.Add(new("Network", "Connection · Relay policy", CoreOwned, "TURN/signaling credentials are Core-owned and must not be hardcoded."));
    }

    // ---- TAB 3: Devices / 设备 ----
    private static void AppendDevices(List<SettingsDetailItem> d)
    {
        // Card: Bluetooth
        d.Add(new("Devices", "Bluetooth · Status", "Not scanned", DisplayOnly + ". Windows client does not run a CoreBluetooth-equivalent scan from settings."));
        d.Add(new("Devices", "Bluetooth · Auto-connect paired devices", "On (default)", DisplayOnly + "."));
        d.Add(new("Devices", "Bluetooth · Show RSSI", "On (default)", DisplayOnly + "."));
        d.Add(new("Devices", "Bluetooth · Show connectable only", "Off (default)", DisplayOnly + "."));
        // Card: AirPlay
        d.Add(new("Devices", "AirPlay · Status", "macOS-only", "AirPlay discovery is Apple-only; not available on Windows."));
        d.Add(new("Devices", "AirPlay · Auto-discover Apple TV", "On (default · macOS-only)", DisplayOnly + "."));
        d.Add(new("Devices", "AirPlay · Show HomePod devices", "On (default · macOS-only)", DisplayOnly + "."));
        d.Add(new("Devices", "AirPlay · Show third-party AirPlay devices", "On (default · macOS-only)", DisplayOnly + "."));
        // Card: Filters / 过滤
        d.Add(new("Devices", "Filters · Hide offline devices", "Off (default)", DisplayOnly + "."));
        d.Add(new("Devices", "Filters · Sort by signal strength", "On (default)", DisplayOnly + "."));
        d.Add(new("Devices", "Filters · Show device icons", "On (default)", DisplayOnly + "."));
        d.Add(new("Devices", "Filters · Min signal strength", "-80 dBm (default · -100…-30)", DisplayOnly + ". Filter threshold is not persisted."));
        // Real Windows surface
        d.Add(new("Devices", "USB · Provider", ReadOnly, "Windows USB Management currently scans removable storage only; surfaced read-only on the Devices workspace."));
    }

    // ---- TAB 4: File Transfer / 文件传输 ----
    private static void AppendFileTransfer(List<SettingsDetailItem> d)
    {
        // Card: Config / 配置
        d.Add(new("File Transfer", "Config · Default path", "~/Downloads (default)", DisplayOnly + ". Receive directory picker is visible; saving the path is not wired on Windows."));
        d.Add(new("File Transfer", "Config · Max concurrent transfers", "10 (default)", NotPersisted + ". Runtime concurrency must be applied through the file-transfer settings bridge."));
        d.Add(new("File Transfer", "Config · Chunk size", "128 KB (default · 64/128/256/512 KB, 1 MB)", NotPersisted + "."));
        d.Add(new("File Transfer", "Config · Rate limit", "Unlimited (default · 0…500 MB/s)", NotPersisted + ". No bandwidth governor is wired."));
        // Card: Options / 选项
        d.Add(new("File Transfer", "Options · Show notification", "On (default)", DisplayOnly + "."));
        d.Add(new("File Transfer", "Options · Resume enabled", "On (default)", NotPersisted + ". Bound to auto-retry policy on mac; display-only here."));
        d.Add(new("File Transfer", "Options · Keep history", "On (default)", NotWired + ". History retention needs a store before mutation."));
        d.Add(new("File Transfer", "Options · Keep system awake", "Off (default)", DisplayOnly + ". Power requests require explicit runtime ownership."));
        d.Add(new("File Transfer", "Options · Retry count", "3 (default)", NotPersisted + "."));
        // Card: Security / 安全
        d.Add(new("File Transfer", "Security · Enable encryption", "On (default)", CoreOwned + ". Transfer encryption is enforced by the Core/provider; display-only."));
        d.Add(new("File Transfer", "Security · Strict certificate validation", "Always on", ReadOnly + ". Certificate validation is non-optional; no control."));
        d.Add(new("File Transfer", "Security · Scan files for virus", "Off (default)", NotWired + ". Malware scanning provider is not wired."));
        d.Add(new("File Transfer", "Security · Scan level", "Standard (default · Quick/Standard/Deep)", DisplayOnly + ". Disabled unless virus scan is on; not persisted."));
        d.Add(new("File Transfer", "Security · Encryption algorithm", "AES-256-GCM", CoreOwned + ". HMAC/signature and crypto policy remain Core/provider-owned."));
    }

    // ---- TAB 5: Remote Desktop / 远程桌面 ----
    private static void AppendRemoteDesktop(List<SettingsDetailItem> d)
    {
        // Card: Video transfer / Quality & Performance
        d.Add(new("Remote Desktop", "Video transfer · Current config", ReadOnly, "Optimization summary only; no encoder settings are changed."));
        d.Add(new("Remote Desktop", "Video transfer · Optimized / needs-adjust", ReadOnly, "Validation badge is display-only."));
        d.Add(new("Remote Desktop", "Video transfer · Estimated data rate", ReadOnly, "Estimated bitrate is not pushed to runtime."));
        d.Add(new("Remote Desktop", "Video transfer · Resolution", "1080P (default · 1080P/2K/4K/5K)", NotPersisted + "."));
        d.Add(new("Remote Desktop", "Video transfer · Frame rate", "30 fps (default · 30/60/120)", NotPersisted + "."));
        d.Add(new("Remote Desktop", "Video transfer · Preset", "Balanced (default · balanced/highPerf/highQuality/lowLatency)", NotPersisted + "."));
        d.Add(new("Remote Desktop", "Video transfer · Hardware acceleration", "On (default)", DisplayOnly + "."));
        d.Add(new("Remote Desktop", "Video transfer · Apple Silicon optimization", "On (default · macOS-only)", DisplayOnly + ". Apple-Silicon path is not applicable on Windows."));
        d.Add(new("Remote Desktop", "Video transfer · Adaptive bitrate", "On (default)", DisplayOnly + "."));
        d.Add(new("Remote Desktop", "Video transfer · Compression quality", "Balanced (default · none/fast/balanced/maximum)", NotPersisted + "."));
        // Card: Display / 显示
        d.Add(new("Remote Desktop", "Display · Compression level", "50 (default · 1…100)", NotPersisted + ". Not applied to live sessions yet."));
        d.Add(new("Remote Desktop", "Display · Full screen mode", "Off (default)", DisplayOnly + ". Disabled until live-session windowing is wired."));
        // Card: Interaction / 交互
        d.Add(new("Remote Desktop", "Interaction · Clipboard sync", "On (default)", NotWired + ". Clipboard channel requires pairing/trust verification."));
        d.Add(new("Remote Desktop", "Interaction · Audio redirection", "Off (default)", NotWired + ". Audio redirection provider is not wired."));
        d.Add(new("Remote Desktop", "Interaction · File transfer", "On (default)", DisplayOnly + ". File-transfer bridge is a separate subsystem."));
        d.Add(new("Remote Desktop", "Interaction · Trackpad gestures", "On (default)", NotWired + ". Input forwarding is disabled."));
        d.Add(new("Remote Desktop", "Interaction · Mouse sensitivity", "1.0 (default · 0.1…3.0)", NotPersisted + ". Input scaling is not applied to runtime."));
        d.Add(new("Remote Desktop", "Interaction · Double-click interval", "500 ms (default)", NotPersisted + "."));
        // Card: Network / 网络
        d.Add(new("Remote Desktop", "Network · Bandwidth adaptive", "On (default)", DisplayOnly + ". Adaptive quality needs transport metrics."));
        d.Add(new("Remote Desktop", "Network · Enable UDP", "On (default)", CoreOwned + ". Transport policy remains Core-owned."));
        d.Add(new("Remote Desktop", "Network · Encryption", "Strict-PQC / TLS 1.3", ReadOnly + ". Encryption is non-optional; no control."));
        d.Add(new("Remote Desktop", "Network · Compression", "6 (default · 0…9)", NotPersisted + "."));
        d.Add(new("Remote Desktop", "Network · Bandwidth limit", "0 = unlimited (default)", NotWired + "."));
        d.Add(new("Remote Desktop", "Network · Buffer size", "1 MB (default · 512 KB/1/2/4 MB)", NotPersisted + ". Network buffers are not applied to runtime."));
    }

    // ---- TAB 6: System Monitor / 系统监控 ----
    private static void AppendSystemMonitor(List<SettingsDetailItem> d)
    {
        // Real, deterministic runtime values (reflect this Windows host).
        d.Add(new("System Monitor", "Runtime · .NET", RuntimeInformation.FrameworkDescription, $"Process architecture: {RuntimeInformation.ProcessArchitecture}"));
        d.Add(new("System Monitor", "Runtime · OS", RuntimeInformation.OSDescription, $"OS architecture: {RuntimeInformation.OSArchitecture}"));
        d.Add(new("System Monitor", "Runtime · Host", Environment.MachineName, $"Logical processors: {Environment.ProcessorCount}"));
        // Card: Config / 配置
        d.Add(new("System Monitor", "Config · Refresh interval", "1s (default · 1/5/10/30)", DisplayOnly + ". ETW/EventSource sampling is pending."));
        d.Add(new("System Monitor", "Config · Enable realtime", "On (default)", NotWired + ". Auto refresh does not start background polling."));
        d.Add(new("System Monitor", "Config · Enable history", "On (default)", NotWired + ". History retention store is not wired."));
        d.Add(new("System Monitor", "Config · Performance alerts", "On (default)", NotWired + ". Alerts require notification permissions and thresholds."));
        d.Add(new("System Monitor", "Config · Retention days", "7 (default)", NotPersisted + ". Retention changes are destructive and gated."));
        d.Add(new("System Monitor", "Config · Max history points", "300 (default · 50…2000)", NotPersisted + "."));
        // Card: Display / 显示
        d.Add(new("System Monitor", "Display · CPU", "On (default)", DisplayOnly + "."));
        d.Add(new("System Monitor", "Display · Memory", "On (default)", DisplayOnly + "."));
        d.Add(new("System Monitor", "Display · Disk", "On (default)", DisplayOnly + "."));
        d.Add(new("System Monitor", "Display · Network", "On (default)", DisplayOnly + "."));
        d.Add(new("System Monitor", "Display · Temperature", "On (default)", DisplayOnly + ". Temperature sampling provider is pending on Windows."));
        d.Add(new("System Monitor", "Display · Fan speed", "On (default)", DisplayOnly + ". Fan-speed sampling provider is pending on Windows."));
        d.Add(new("System Monitor", "Display · Chart type", "Line (default · Line/Bar/Area)", DisplayOnly + "."));
        // Card: Alerts / 警报
        d.Add(new("System Monitor", "Alerts · CPU threshold", "80% (default · 50…95)", NotPersisted + "."));
        d.Add(new("System Monitor", "Alerts · Memory threshold", "80% (default · 50…95)", NotPersisted + "."));
        d.Add(new("System Monitor", "Alerts · Temperature monitoring", "On (default)", NotWired + "."));
        d.Add(new("System Monitor", "Alerts · Temperature threshold", "80°C (default · 60…95)", NotPersisted + ". Disabled unless temperature monitoring is on."));
        d.Add(new("System Monitor", "Alerts · Fan speed monitoring", "On (default)", NotWired + "."));
        d.Add(new("System Monitor", "Alerts · Fan speed threshold", "4000 RPM (default · 2000…8000)", NotPersisted + ". Disabled unless fan monitoring is on."));
        d.Add(new("System Monitor", "Alerts · Disk threshold", "90% (default · 70…95)", NotPersisted + "."));
        d.Add(new("System Monitor", "Alerts · Sound alerts", "Off (default)", NotWired + ". Notification writes require explicit permission flow."));
        d.Add(new("System Monitor", "Alerts · Notification Center", "On (default)", NotWired + ". No system notification is posted by this workspace."));
        // Card: Advanced / 高级
        d.Add(new("System Monitor", "Advanced · Thermal throttling alert", "On (default)", NotWired + "."));
        d.Add(new("System Monitor", "Advanced · Enable remote monitoring", "Off (default)", DisplayOnly + "."));
        d.Add(new("System Monitor", "Advanced · Sampling precision", "Normal (default · Low/Normal/High)", DisplayOnly + "."));
    }

    // ---- TAB 7: Permissions / 权限 ----
    private static void AppendPermissions(List<SettingsDetailItem> d)
    {
        // Card: Status / 状态
        d.Add(new("Permissions", "Status · Summary", "Not requested", "No permission prompt is issued by this workspace; status is display-only."));
        // Card: Details / 详情
        d.Add(new("Permissions", "Details · Wi-Fi access", "OS-managed", "Windows grants network access at the OS level; not prompted here."));
        d.Add(new("Permissions", "Details · Bluetooth access", "OS-managed", "Windows grants Bluetooth at the OS level; not prompted here."));
        d.Add(new("Permissions", "Details · Location access", "OS-managed", "Location is governed by Windows privacy settings; not prompted here."));
        d.Add(new("Permissions", "Details · System configuration access", "OS-managed", "System integration is governed by Windows; not prompted here."));
        // Card: Help / 帮助
        d.Add(new("Permissions", "Help · System preferences", CanOpenSystemPreferencesStatic(), "Open Windows Settings (ms-settings:) — disabled unless the explicit launcher is enabled."));
    }

    // ---- TAB 8: Advanced / 高级 ----
    private static void AppendAdvanced(List<SettingsDetailItem> d)
    {
        // Card: Debug / 调试
        d.Add(new("Advanced", "Debug · Verbose logging", "Off (default)", DisplayOnly + ". Logging level is not persisted."));
        d.Add(new("Advanced", "Debug · Show debug info", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Debug · Save network logs", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Debug · Log level", "Info (default · Error/Warning/Info/Debug)", DisplayOnly + "."));
        // Card: Performance / 性能
        d.Add(new("Advanced", "Performance · Performance mode", "Balanced (default · extreme/balanced/energySaving/adaptive)", DisplayOnly + ". Render-tier mode is a mac display preference; not persisted on Windows."));
        d.Add(new("Advanced", "Performance · Real-time weather API", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Performance · Show real-time FPS", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Performance · Hardware acceleration", "On (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Performance · Optimize memory usage", "On (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Performance · Background scanning", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Performance · Metal Performance HUD", "macOS-only", "Metal HUD is an Apple/Metal feature; not applicable on Windows."));
        d.Add(new("Advanced", "Performance · Max concurrent connections", "10 (default)", NotPersisted + "."));
        // Card: Experimental / 实验性
        d.Add(new("Advanced", "Experimental · Enable IPv6", "Off (default)", DisplayOnly + ". Experimental flag is not persisted."));
        d.Add(new("Advanced", "Experimental · Use new discovery algorithm", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "Experimental · Enable P2P direct connection", "Off (default)", DisplayOnly + "."));
        // Card: PQC / 后量子加密
        d.Add(new("Advanced", "PQC · App-layer PQC", "Enabled (policy-forced)", ReadOnly + ". Strict-PQC is enforced by policy; no control."));
        d.Add(new("Advanced", "PQC · Hybrid TLS", "OS-negotiated", ReadOnly + ". Hybrid TLS is negotiated by the OS transport; no control."));
        d.Add(new("Advanced", "PQC · Prefer X-Wing hybrid", "Off (default)", DisplayOnly + "."));
        d.Add(new("Advanced", "PQC · Signature algorithm", "ML-DSA-65 (default · 65/87)", CoreOwned + ". Suite IDs and fallback policy remain in Rust Core."));
        d.Add(new("Advanced", "PQC · Secure Enclave ML-DSA", "macOS-only", "Secure Enclave is Apple hardware; not applicable on Windows."));
        d.Add(new("Advanced", "PQC · ML-KEM key agreement", "X-Wing hybrid · ephemeral", ReadOnly + ". Key agreement is Core-owned; no control."));
        // Card: Smoothing / 平滑
        d.Add(new("Advanced", "Smoothing · Signal strength alpha", "0.60 (default · 0.10…0.95)", NotPersisted + ". Smoothing factor is display-only."));
        // Card: Reset / 重置
        d.Add(new("Advanced", "Reset · Reset all settings", "Gated", "Destructive preference write; prepares an in-memory intent only."));
        d.Add(new("Advanced", "Reset · Reset network settings", "Gated", "Destructive preference write; prepares an in-memory intent only."));
        // Diagnostics
        d.Add(new("Advanced", "Diagnostics · Acceptance gates", "Text gates", "UI parity and service-boundary scripts are the current acceptance checks."));
    }

    // Honest read-only mirror of the launcher's capability without needing an instance.
    // The default Windows client uses DisabledSystemPreferencesLauncher, so this reads "Disabled"
    // unless SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES=enabled gates a real launcher in.
    private static string CanOpenSystemPreferencesStatic()
    {
        var gate = Environment.GetEnvironmentVariable("SKYBRIDGE_WINDOWS_SETTINGS_SYSTEM_PREFERENCES");
        return string.Equals(gate, "enabled", StringComparison.OrdinalIgnoreCase) ? "Available" : "Disabled";
    }

    private static string BuildExportPreviewDetail(SettingsExportPreviewSnapshot exportPreview)
    {
        if (!exportPreview.HasPreview || !exportPreview.BuiltAt.HasValue)
        {
            return "Prepares a settings export preview in memory only; no destination file is opened or written.";
        }

        return $"preview={NormalizeExportPreviewId(exportPreview.PreviewId)}; built={exportPreview.BuiltAt.Value:HH:mm:ss} UTC; no file was written";
    }

    private static string BuildActionIntentState(
        SettingsActionIntentSnapshot actionIntent,
        string actionKey) =>
        IsLatestActionIntent(actionIntent, actionKey) ? "Intent ready" : "Ready";

    private static string BuildActionIntentDetail(
        SettingsActionIntentSnapshot actionIntent,
        string actionKey,
        string readyDetail)
    {
        if (!IsLatestActionIntent(actionIntent, actionKey) || !actionIntent.BuiltAt.HasValue)
        {
            return readyDetail;
        }

        return $"intent={NormalizeSettingsActionIntentId(actionIntent.IntentId)}; built={actionIntent.BuiltAt.Value:HH:mm:ss} UTC; {readyDetail}";
    }

    private static string BuildLatestActionIntentValue(SettingsActionIntentSnapshot actionIntent) =>
        actionIntent.HasIntent
            ? NormalizeSettingsActionIntentId(actionIntent.IntentId)
            : "Ready";

    private static string BuildLatestActionIntentDetail(SettingsActionIntentSnapshot actionIntent)
    {
        if (!actionIntent.HasIntent || !actionIntent.BuiltAt.HasValue)
        {
            return "Settings actions prepare in-memory intents only; no preferences, files, permissions, runtime settings, defaults, or monitor data are changed.";
        }

        return $"action={NormalizeSettingsActionKey(actionIntent.ActionKey)}; intent={NormalizeSettingsActionIntentId(actionIntent.IntentId)}; built={actionIntent.BuiltAt.Value:HH:mm:ss} UTC; no settings side effect was performed";
    }

    private static bool IsLatestActionIntent(
        SettingsActionIntentSnapshot actionIntent,
        string actionKey) =>
        actionIntent.HasIntent
            && string.Equals(actionIntent.ActionKey, actionKey, StringComparison.Ordinal);

    private static string NormalizeExportPreviewId(string? previewId)
    {
        var normalized = (previewId ?? "").Trim();
        return normalized.Length == 0 ? "SET-0000" : normalized;
    }

    private static string NormalizeSettingsActionIntentId(string? intentId)
    {
        var normalized = (intentId ?? "").Trim();
        return normalized.Length == 0 ? "SET-ACTION-0000" : normalized;
    }

    private static string NormalizeSettingsActionKey(string? actionKey)
    {
        var normalized = (actionKey ?? "").Trim();
        return normalized.Length == 0 ? "SettingsAction" : normalized;
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

public sealed record SettingsActionIntentSnapshot(
    bool HasIntent,
    string? ActionKey,
    string? IntentId,
    DateTimeOffset? BuiltAt,
    int IntentCount);

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
