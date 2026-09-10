using System.Net;

namespace Skybridge.WinClient.Services.RemoteControl;

public sealed record RemoteControlNetworkInterface(string AdapterId, string Name, IPAddress Address, uint InterfaceIndex)
{
    public string DisplayName => $"{Name} · {Address}";
}

internal sealed record RemoteControlHostPreparation(
    string PublicMaterialJson,
    string DeviceName,
    string Fingerprint,
    IReadOnlyList<string> TrustedDeviceNames,
    IReadOnlyList<RemoteControlNetworkInterface> NetworkInterfaces);

internal sealed record RemoteControlHostWorkspaceStatus(long Generation, WindowsRemoteControlHostStatus Status);
