using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class RemoteDesktopWorkspaceActions
{
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly IRemoteDesktopWorkspaceClient _remoteDesktopClient;
    private readonly Func<string> _getSelectedBitrate;
    private readonly Func<string> _getSelectedFramerate;
    private readonly Action<string> _setRemoteDesktopStatus;
    private readonly Action<string> _setStatusMessage;

    public RemoteDesktopWorkspaceActions(
        WorkspaceBusyCoordinator busyCoordinator,
        IRemoteDesktopWorkspaceClient remoteDesktopClient,
        Func<string> getSelectedBitrate,
        Func<string> getSelectedFramerate,
        Action<string> setRemoteDesktopStatus,
        Action<string> setStatusMessage)
    {
        _busyCoordinator = busyCoordinator ?? throw new ArgumentNullException(nameof(busyCoordinator));
        _remoteDesktopClient = remoteDesktopClient ?? throw new ArgumentNullException(nameof(remoteDesktopClient));
        _getSelectedBitrate = getSelectedBitrate ?? throw new ArgumentNullException(nameof(getSelectedBitrate));
        _getSelectedFramerate = getSelectedFramerate ?? throw new ArgumentNullException(nameof(getSelectedFramerate));
        _setRemoteDesktopStatus = setRemoteDesktopStatus ?? throw new ArgumentNullException(nameof(setRemoteDesktopStatus));
        _setStatusMessage = setStatusMessage ?? throw new ArgumentNullException(nameof(setStatusMessage));
    }

    public Task RecommendedConnectAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildRecommendedConnectPendingStatus,
            _remoteDesktopClient.BuildRecommendedConnectActionAsync);

    public Task AdvancedConnectAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildAdvancedConnectPendingStatus,
            _remoteDesktopClient.BuildAdvancedConnectActionAsync);

    public Task ShowPerformanceOverlayAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildPerformanceOverlayPendingStatus,
            _remoteDesktopClient.BuildPerformanceOverlayActionAsync);

    public Task ApplyQualityAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildQualityPendingStatus,
            () => _remoteDesktopClient.BuildQualityActionAsync(
                _getSelectedBitrate(),
                _getSelectedFramerate()));

    public Task OpenSettingsAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildSettingsPendingStatus,
            _remoteDesktopClient.BuildSettingsActionAsync);

    public Task EnterFullScreenAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildFullScreenPendingStatus,
            _remoteDesktopClient.BuildFullScreenActionAsync);

    public Task DisconnectSessionAsync() =>
        RunAsync(
            _remoteDesktopClient.BuildDisconnectSessionPendingStatus,
            _remoteDesktopClient.BuildDisconnectSessionActionAsync);

    private Task RunAsync(
        Func<string> buildPendingStatus,
        Func<Task<RemoteDesktopWorkspaceActionResult>> buildActionAsync) =>
        _busyCoordinator.RunAsync(
            WorkspaceErrorScope.RemoteDesktop,
            async () =>
            {
                _setRemoteDesktopStatus(buildPendingStatus());
                var result = await buildActionAsync();
                _setRemoteDesktopStatus(result.Status);
                _setStatusMessage(result.Message);
            });
}
