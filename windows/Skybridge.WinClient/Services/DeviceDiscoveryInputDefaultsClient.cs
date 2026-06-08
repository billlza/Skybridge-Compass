namespace Skybridge.WinClient.Services;

public interface IDeviceDiscoveryInputDefaultsClient
{
    DeviceDiscoveryInputDefaultsSnapshot BuildReadOnlySnapshot();
}

public sealed class DeviceDiscoveryInputDefaultsClient : IDeviceDiscoveryInputDefaultsClient
{
    public DeviceDiscoveryInputDefaultsSnapshot BuildReadOnlySnapshot() =>
        new(
            "_skybridge._udp",
            "11550",
            "",
            "");
}

public sealed record DeviceDiscoveryInputDefaultsSnapshot(
    string DiscoveryService,
    string ManualConnectionPort,
    string DiscoveryTxtRecord,
    string PairingConnectionCode);
