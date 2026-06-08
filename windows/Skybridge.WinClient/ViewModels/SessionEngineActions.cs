using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class SessionEngineActions
{
    private readonly IEngineClient _engineClient;
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ISessionStatusClient _sessionStatusClient;
    private readonly Action<string> _setStatusMessage;

    public SessionEngineActions(
        IEngineClient engineClient,
        WorkspaceBusyCoordinator busyCoordinator,
        ISessionStatusClient sessionStatusClient,
        Action<string> setStatusMessage)
    {
        _engineClient = engineClient;
        _busyCoordinator = busyCoordinator;
        _sessionStatusClient = sessionStatusClient;
        _setStatusMessage = setStatusMessage;
    }

    public Task ConnectAsync() =>
        RunAsync(SessionStatusAction.Connect, _engineClient.ConnectAsync);

    public Task DisconnectAsync() =>
        RunAsync(SessionStatusAction.Disconnect, _engineClient.DisconnectAsync);

    public Task SendHeartbeatAsync() =>
        RunAsync(SessionStatusAction.Heartbeat, _engineClient.SendHeartbeatAsync);

    private async Task RunAsync(
        SessionStatusAction action,
        Func<Task> engineAction)
    {
        await _busyCoordinator.RunAsync(WorkspaceErrorScope.Session, async () =>
        {
            _setStatusMessage(_sessionStatusClient.BuildPendingStatus(action));
            await engineAction();
            _setStatusMessage(_sessionStatusClient.BuildCompletedStatus(action));
        });
    }
}
