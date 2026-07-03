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
            "",
            // Smart-connection-code lease default (Mac ConnectionCodeLeaseMode). Startup default
            // is the short-lived assistance window; selecting 全天 (day-stable) extends the real
            // generated-code TTL. Carried as the canonical mode name so the startup gate can pin it.
            "shortLived");
}

public sealed record DeviceDiscoveryInputDefaultsSnapshot(
    string DiscoveryService,
    string ManualConnectionPort,
    string DiscoveryTxtRecord,
    string PairingConnectionCode,
    string ConnectionCodeLeaseMode);
