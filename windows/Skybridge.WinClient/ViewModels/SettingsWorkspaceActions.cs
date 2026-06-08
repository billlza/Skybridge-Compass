using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class SettingsWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ISettingsWorkspaceClient _settingsClient;
    private readonly Action<string> _setSettingsStatus;
    private readonly Action<string> _setStatusMessage;

    public SettingsWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        ISettingsWorkspaceClient settingsClient,
        Action<string> setSettingsStatus,
        Action<string> setStatusMessage)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _settingsClient = settingsClient ?? throw new ArgumentNullException(nameof(settingsClient));
        _setSettingsStatus = setSettingsStatus ?? throw new ArgumentNullException(nameof(setSettingsStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
    }

    public Task ExportSettingsAsync() =>
        RunAsync(
            _settingsClient.BuildExportSettingsPendingStatus,
            _settingsClient.BuildExportSettingsActionAsync);

    public Task ImportSettingsAsync() =>
        RunAsync(
            _settingsClient.BuildImportSettingsPendingStatus,
            _settingsClient.BuildImportSettingsActionAsync);

    public Task ResetSettingsAsync() =>
        RunAsync(
            _settingsClient.BuildResetSettingsPendingStatus,
            _settingsClient.BuildResetSettingsActionAsync);

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
            _settingsClient.BuildApplySettingsActionAsync);

    public Task RestoreDefaultsAsync() =>
        RunAsync(
            _settingsClient.BuildRestoreDefaultsPendingStatus,
            _settingsClient.BuildRestoreDefaultsActionAsync);

    public Task ResetMonitorDataAsync() =>
        RunAsync(
            _settingsClient.BuildResetMonitorDataPendingStatus,
            _settingsClient.BuildResetMonitorDataActionAsync);

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<SettingsWorkspaceActionResult>> buildActionAsync) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.Settings,
            async () =>
            {
                _setSettingsStatus(buildPendingStatus());
                var result = await buildActionAsync();
                _setSettingsStatus(result.Status);
                _setStatusMessage(result.Message);
            });
}
