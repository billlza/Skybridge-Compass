using System;
using System.Threading.Tasks;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class SessionEngineActions
{
    private readonly IEngineClient _engineClient;
    private readonly WorkspaceBusyCoordinator _busyCoordinator;
    private readonly ISessionStatusClient _sessionStatusClient;
    private readonly Func<ConnectionLaunchRequest> _buildConnectionLaunchRequest;
    private readonly Action<string> _setStatusMessage;

    public SessionEngineActions(
        IEngineClient engineClient,
        WorkspaceBusyCoordinator busyCoordinator,
        ISessionStatusClient sessionStatusClient,
        Func<ConnectionLaunchRequest> buildConnectionLaunchRequest,
        Action<string> setStatusMessage)
    {
        _engineClient = engineClient;
        _busyCoordinator = busyCoordinator;
        _sessionStatusClient = sessionStatusClient;
        _buildConnectionLaunchRequest = buildConnectionLaunchRequest;
        _setStatusMessage = setStatusMessage;
    }

    public Task ConnectAsync() =>
        _busyCoordinator.RunAsync(WorkspaceErrorScope.Session, async () =>
        {
            _setStatusMessage(_sessionStatusClient.BuildPendingStatus(SessionStatusAction.Connect));

            // Build the launch request ONCE: for the webrtc-verified-launch path the preflight already
            // ran the helper offerer (live DataChannel + verified SBF1 echo) and the verified adapter
            // re-validated the fresh proof, so the request only reaches here when IsLiveAdapterReady.
            var request = _buildConnectionLaunchRequest();
            await _engineClient.ConnectAsync(request);

            // Honest surface: the FFI Core flips SessionState::Connected on a verified CONTROL plane;
            // no media / remote-desktop data plane exists on Windows. Say so for the WebRTC path.
            _setStatusMessage(BuildConnectedStatusMessage(request));
        });

    public Task DisconnectAsync() =>
        RunAsync(SessionStatusAction.Disconnect, _engineClient.DisconnectAsync);

    public Task SendHeartbeatAsync() =>
        RunAsync(SessionStatusAction.Heartbeat, _engineClient.SendHeartbeatAsync);

    private static string BuildConnectedStatusMessage(ConnectionLaunchRequest request) =>
        request.Plan.AdapterKind == ConnectionLaunchAdapterKind.WebRtcDataChannel
            ? "Connected (control-plane verified)"
            : SessionStatusClient.BuildDefaultCompletedStatus(SessionStatusAction.Connect);

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
