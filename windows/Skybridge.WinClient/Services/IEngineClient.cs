using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public enum EngineConnectionState
{
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    ShuttingDown
}

public interface IEngineClient
{
    EngineConnectionState State { get; }

    Task ConnectAsync();

    Task DisconnectAsync();

    Task SendHeartbeatAsync();
}
