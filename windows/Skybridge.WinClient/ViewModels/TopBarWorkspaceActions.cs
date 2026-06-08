using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class TopBarWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ITopBarStatusClient _topBarStatusClient;
    private readonly Action<string> _setNotificationsStatus;
    private readonly Action<string> _setThemeStatus;
    private readonly Action<string> _setStatusMessage;

    public TopBarWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        ITopBarStatusClient topBarStatusClient,
        Action<string> setNotificationsStatus,
        Action<string> setThemeStatus,
        Action<string> setStatusMessage)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _topBarStatusClient = topBarStatusClient ?? throw new ArgumentNullException(nameof(topBarStatusClient));
        _setNotificationsStatus = setNotificationsStatus ?? throw new ArgumentNullException(nameof(setNotificationsStatus));
        _setThemeStatus = setThemeStatus ?? throw new ArgumentNullException(nameof(setThemeStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
    }

    public Task OpenNotificationsAsync() =>
        RunAsync(
            _topBarStatusClient.BuildNotificationsPendingStatus,
            _topBarStatusClient.BuildNotificationsActionAsync,
            _setNotificationsStatus);

    public Task ToggleThemeAsync() =>
        RunAsync(
            _topBarStatusClient.BuildThemePendingStatus,
            _topBarStatusClient.BuildThemeActionAsync,
            _setThemeStatus);

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<TopBarWorkspaceActionResult>> buildActionAsync,
        Action<string> setTopBarStatus) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.TopBar,
            async () =>
            {
                setTopBarStatus(buildPendingStatus());
                var result = await buildActionAsync();
                setTopBarStatus(result.Status);
                _setStatusMessage(result.Message);
            });
}
