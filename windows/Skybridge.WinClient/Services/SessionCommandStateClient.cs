namespace Skybridge.WinClient.Services;

public interface ISessionCommandStateClient
{
    bool CanConnect(EngineConnectionState state, bool isBusy);

    bool CanDisconnect(EngineConnectionState state, bool isBusy);

    bool CanSendHeartbeat(EngineConnectionState state, bool isBusy);

    SessionCommandGateSnapshot BuildGateSnapshot(EngineConnectionState state, bool isBusy);
}

public sealed class SessionCommandStateClient : ISessionCommandStateClient
{
    public bool CanConnect(EngineConnectionState state, bool isBusy) =>
        !isBusy && state == EngineConnectionState.Disconnected;

    public bool CanDisconnect(EngineConnectionState state, bool isBusy) =>
        !isBusy && (state == EngineConnectionState.Connected || state == EngineConnectionState.Reconnecting);

    public bool CanSendHeartbeat(EngineConnectionState state, bool isBusy) =>
        !isBusy && state == EngineConnectionState.Connected;

    public SessionCommandGateSnapshot BuildGateSnapshot(EngineConnectionState state, bool isBusy) =>
        new(
            CanConnect(state, isBusy),
            CanDisconnect(state, isBusy),
            CanSendHeartbeat(state, isBusy));
}

public sealed record SessionCommandGateSnapshot(
    bool CanConnect,
    bool CanDisconnect,
    bool CanSendHeartbeat);
