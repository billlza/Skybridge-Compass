namespace Skybridge.WinClient.Services;

public interface IDeviceDiscoveryInputDefaultsClient
{
    DeviceDiscoveryInputDefaultsSnapshot BuildReadOnlySnapshot();
}

public sealed class DeviceDiscoveryInputDefaultsClient : IDeviceDiscoveryInputDefaultsClient
{
    private const string SampleFingerprint =
        "f50924465c15480c8d06de12140f20c69bd2312eeec840c5372f7ce32ffd4009";

    private const string SamplePairingPublicKey =
        "c2FtcGxlLXBlZXItcHVibGljLWtleQ==";

    public DeviceDiscoveryInputDefaultsSnapshot BuildReadOnlySnapshot() =>
        new(
            "_skybridge._udp",
            "11550",
            $"deviceId=mac-1;pubKeyFP={SampleFingerprint};platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1",
            $"skybridge-pair:v1;deviceId=mac-1;pubKey={SamplePairingPublicKey};pubKeyFP={SampleFingerprint};platform=macOS;name=Desk%20Mac;version=v1",
            SampleFingerprint,
            SamplePairingPublicKey);
}

public sealed record DeviceDiscoveryInputDefaultsSnapshot(
    string DiscoveryService,
    string ManualConnectionPort,
    string DiscoveryTxtRecord,
    string PairingConnectionCode,
    string SampleFingerprint,
    string SamplePairingPublicKey);
