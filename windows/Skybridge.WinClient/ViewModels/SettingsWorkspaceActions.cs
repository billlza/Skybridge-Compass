using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class SettingsWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ISettingsWorkspaceClient _settingsClient;
    private readonly Func<Task> _applySettingsSnapshotAsync;
    private readonly Action<string> _setSettingsStatus;
    private readonly Action<string> _setStatusMessage;

    // ---- Real-work seams (Effects phase) -------------------------------------------------
    // The Export/Import/Reset/Apply actions used to be in-memory intent stubs (the action client
    // only built an intent id + a "no side effect was performed" message). They now do REAL work
    // through the self-provisioned SettingsCoordinator the SessionViewModel owns: Export serializes
    // the live settings to a user-chosen file, Import replaces them from a file, Reset/RestoreDefaults
    // revert to defaults, Apply re-pushes the live effects. The file pickers need the window HWND, so
    // they are supplied as async delegates the SessionViewModel routes to MainWindow. All are
    // optional — when null (a unit-test host with no window) the action falls back to the existing
    // intent message, so the surface/counts are byte-stable and nothing throws.
    private readonly SettingsCoordinator? _coordinator;
    private readonly Func<Task<string?>>? _pickExportPathAsync;
    private readonly Func<Task<string?>>? _pickImportPathAsync;

    public SettingsWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        ISettingsWorkspaceClient settingsClient,
        Func<Task> applySettingsSnapshotAsync,
        Action<string> setSettingsStatus,
        Action<string> setStatusMessage,
        SettingsCoordinator? coordinator = null,
        Func<Task<string?>>? pickExportPathAsync = null,
        Func<Task<string?>>? pickImportPathAsync = null)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _settingsClient = settingsClient ?? throw new ArgumentNullException(nameof(settingsClient));
        _applySettingsSnapshotAsync = applySettingsSnapshotAsync ?? throw new ArgumentNullException(nameof(applySettingsSnapshotAsync));
        _setSettingsStatus = setSettingsStatus ?? throw new ArgumentNullException(nameof(setSettingsStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
        _coordinator = coordinator;
        _pickExportPathAsync = pickExportPathAsync;
        _pickImportPathAsync = pickImportPathAsync;
    }

    public Task ExportSettingsAsync() =>
        RunAsync(
            _settingsClient.BuildExportSettingsPendingStatus,
            _settingsClient.BuildExportSettingsActionAsync,
            DoExportAsync);

    public Task ImportSettingsAsync() =>
        RunAsync(
            _settingsClient.BuildImportSettingsPendingStatus,
            _settingsClient.BuildImportSettingsActionAsync,
            DoImportAsync);

    public Task ResetSettingsAsync() =>
        RunAsync(
            _settingsClient.BuildResetSettingsPendingStatus,
            _settingsClient.BuildResetSettingsActionAsync,
            DoResetAsync);

    public Task RequestPermissionAsync() =>
        RunAsync(
            _settingsClient.BuildPermissionRequestPendingStatus,
            _settingsClient.BuildPermissionRequestActionAsync);

    public Task OpenSystemPreferencesAsync() =>
        RunAsync(
            _settingsClient.BuildSystemPreferencesPendingStatus,
            _settingsClient.BuildSystemPreferencesActionAsync);

    public Task ApplySettingsAsync() =>
        RunAsync(
            _settingsClient.BuildApplySettingsPendingStatus,
            _settingsClient.BuildApplySettingsActionAsync,
            DoApplyAsync);

    public Task RestoreDefaultsAsync() =>
        RunAsync(
            _settingsClient.BuildRestoreDefaultsPendingStatus,
            _settingsClient.BuildRestoreDefaultsActionAsync,
            DoResetAsync);

    public Task ResetMonitorDataAsync() =>
        RunAsync(
            _settingsClient.BuildResetMonitorDataPendingStatus,
            _settingsClient.BuildResetMonitorDataActionAsync);

    // ---- Real-work bodies ----------------------------------------------------------------
    // Each returns an overriding (Status, Message) when it performed real work, or null to fall
    // back to the action client's intent result (no coordinator / no picker / user cancelled).

    private async Task<SettingsWorkspaceActionResult?> DoExportAsync()
    {
        if (_coordinator is null || _pickExportPathAsync is null)
        {
            return null;
        }

        var path = await _pickExportPathAsync().ConfigureAwait(true);
        if (string.IsNullOrWhiteSpace(path))
        {
            return new SettingsWorkspaceActionResult("Settings export cancelled", "No file was chosen; settings were not exported.");
        }

        var ok = _coordinator.ExportSettings(path);
        return ok
            ? new SettingsWorkspaceActionResult("Settings exported", $"Settings written to {path}.")
            : new SettingsWorkspaceActionResult("Settings export failed", $"Could not write settings to {path}.");
    }

    private async Task<SettingsWorkspaceActionResult?> DoImportAsync()
    {
        if (_coordinator is null || _pickImportPathAsync is null)
        {
            return null;
        }

        var path = await _pickImportPathAsync().ConfigureAwait(true);
        if (string.IsNullOrWhiteSpace(path))
        {
            return new SettingsWorkspaceActionResult("Settings import cancelled", "No file was chosen; settings were not changed.");
        }

        var ok = _coordinator.ImportSettings(path);
        return ok
            ? new SettingsWorkspaceActionResult("Settings imported", $"Settings replaced from {path}. Live effects re-applied.")
            : new SettingsWorkspaceActionResult("Settings import failed", $"Could not import a valid settings file from {path}; current settings kept.");
    }

    private Task<SettingsWorkspaceActionResult?> DoResetAsync()
    {
        if (_coordinator is null)
        {
            return Task.FromResult<SettingsWorkspaceActionResult?>(null);
        }

        _coordinator.ResetSettings();
        return Task.FromResult<SettingsWorkspaceActionResult?>(
            new SettingsWorkspaceActionResult("Settings reset", "All settings reverted to defaults; live effects re-applied."));
    }

    private Task<SettingsWorkspaceActionResult?> DoApplyAsync()
    {
        if (_coordinator is null)
        {
            return Task.FromResult<SettingsWorkspaceActionResult?>(null);
        }

        _coordinator.ApplySettings();
        return Task.FromResult<SettingsWorkspaceActionResult?>(
            new SettingsWorkspaceActionResult("Settings applied", "Live settings re-applied to theme, discovery, top-bar, weather, clipboard, logging and signal subsystems."));
    }

    // RunAsync overload WITHOUT real work (RequestPermission / OpenSystemPreferences / ResetMonitorData
    // keep their existing behavior).
    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<SettingsWorkspaceActionResult>> buildActionAsync) =>
        RunAsync(buildPendingStatus, buildActionAsync, realWorkAsync: null);

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<SettingsWorkspaceActionResult>> buildActionAsync,
        Func<Task<SettingsWorkspaceActionResult?>>? realWorkAsync) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.Settings,
            async () =>
            {
                _setSettingsStatus(buildPendingStatus());

                // Do the REAL work first (export/import/reset/apply). If it ran, its (Status,
                // Message) overrides the intent stub; otherwise we fall back to the existing intent
                // result so the action still produces an honest status (no-op host / cancel).
                SettingsWorkspaceActionResult? realResult = null;
                if (realWorkAsync is not null)
                {
                    realResult = await realWorkAsync().ConfigureAwait(true);
                }

                var result = realResult ?? await buildActionAsync().ConfigureAwait(true);
                _setSettingsStatus(result.Status);
                _setStatusMessage(result.Message);
                await _applySettingsSnapshotAsync().ConfigureAwait(true);
            });
}
