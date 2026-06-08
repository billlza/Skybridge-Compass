namespace Skybridge.WinClient.Services;

public interface ISessionCommandStateClient
{
    bool CanConnect(EngineConnectionState state, bool isBusy);

    bool CanDisconnect(EngineConnectionState state, bool isBusy);

    bool CanSendHeartbeat(EngineConnectionState state, bool isBusy);
}

public sealed class SessionCommandStateClient : ISessionCommandStateClient
{
    public bool CanConnect(EngineConnectionState state, bool isBusy) =>
        !isBusy && state == EngineConnectionState.Disconnected;

    public bool CanDisconnect(EngineConnectionState state, bool isBusy) =>
        !isBusy && (state == EngineConnectionState.Connected || state == EngineConnectionState.Reconnecting);

    public bool CanSendHeartbeat(EngineConnectionState state, bool isBusy) =>
        !isBusy && state == EngineConnectionState.Connected;
}
