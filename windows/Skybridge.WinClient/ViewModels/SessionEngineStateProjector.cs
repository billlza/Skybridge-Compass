using System;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed class SessionEngineStateProjector
{
    private readonly ISessionStatusClient _sessionStatusClient;
    private readonly Action<EngineConnectionState> _setConnectionState;
    private readonly Action<string> _setStatusMessage;

    public SessionEngineStateProjector(
        ISessionStatusClient sessionStatusClient,
        Action<EngineConnectionState> setConnectionState,
        Action<string> setStatusMessage)
    {
        _sessionStatusClient = sessionStatusClient;
        _setConnectionState = setConnectionState;
        _setStatusMessage = setStatusMessage;
    }

    public void Apply(EngineConnectionState state)
    {
        _setConnectionState(state);
        _setStatusMessage(_sessionStatusClient.BuildEngineStateStatus(state));
    }
}
