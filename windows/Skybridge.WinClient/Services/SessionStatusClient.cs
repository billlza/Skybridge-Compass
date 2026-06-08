namespace Skybridge.WinClient.Services;

public interface ISessionStatusClient
{
    string BuildInitialStatusMessage();

    string BuildPendingStatus(SessionStatusAction action);

    string BuildCompletedStatus(SessionStatusAction action);

    string BuildEngineStateStatus(EngineConnectionState state);
}

public sealed class SessionStatusClient : ISessionStatusClient
{
    public string BuildInitialStatusMessage() => DefaultInitialStatusMessage;

    public string BuildPendingStatus(SessionStatusAction action) =>
        BuildDefaultPendingStatus(action);

    public string BuildCompletedStatus(SessionStatusAction action) =>
        BuildDefaultCompletedStatus(action);

    public string BuildEngineStateStatus(EngineConnectionState state) =>
        BuildDefaultEngineStateStatus(state);

    public static string DefaultInitialStatusMessage { get; } = "Idle";

    public static string BuildDefaultPendingStatus(SessionStatusAction action) =>
        action switch
        {
            SessionStatusAction.Connect => "Connecting...",
            SessionStatusAction.Disconnect => "Disconnecting...",
            SessionStatusAction.Heartbeat => "Sending heartbeat...",
            _ => "Working..."
        };

    public static string BuildDefaultCompletedStatus(SessionStatusAction action) =>
        action switch
        {
            SessionStatusAction.Connect => "Connected",
            SessionStatusAction.Disconnect => "Disconnected",
            SessionStatusAction.Heartbeat => "Heartbeat acknowledged",
            _ => "Done"
        };

    public static string BuildDefaultEngineStateStatus(EngineConnectionState state) =>
        state switch
        {
            EngineConnectionState.Connecting => "Connecting...",
            EngineConnectionState.Connected => "Connected",
            EngineConnectionState.Reconnecting => "Reconnecting...",
            EngineConnectionState.ShuttingDown => "Disconnecting...",
            _ => "Disconnected"
        };
}

public enum SessionStatusAction
{
    Connect,
    Disconnect,
    Heartbeat
}
