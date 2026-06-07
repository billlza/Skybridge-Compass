using System;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface IDiscoveryClient
{
    string BuildPendingStatus();

    bool CanParseAdvertisement(string service, string txtRecord);

    Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord);
}

public sealed class CoreDiscoveryClient : IDiscoveryClient
{
    private readonly CoreBridge _coreBridge;

    public CoreDiscoveryClient(CoreBridge coreBridge)
    {
        _coreBridge = coreBridge ?? throw new ArgumentNullException(nameof(coreBridge));
    }

    public string BuildPendingStatus() => DefaultPendingStatus;

    public static string DefaultPendingStatus { get; } = "Parsing...";

    public bool CanParseAdvertisement(string service, string txtRecord) =>
        HasParseInputs(service, txtRecord);

    public static bool HasParseInputs(string service, string txtRecord) =>
        !string.IsNullOrWhiteSpace(service)
        && !string.IsNullOrWhiteSpace(txtRecord);

    public async Task<DiscoveredPeer> ParseAdvertisementAsync(string service, string txtRecord)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(service);
        ArgumentException.ThrowIfNullOrWhiteSpace(txtRecord);

        var advertisement = await _coreBridge.ParseDiscoveryAdvertisementAsync(service, txtRecord);
        return DiscoveredPeer.FromAdvertisement(advertisement);
    }
}

public sealed record DiscoveredPeer(
    CoreDiscoveryServiceKind ServiceKind,
    string DeviceId,
    string DisplayName,
    CorePeerPlatform Platform,
    string PlatformLabel,
    string PublicKeyFingerprint,
    string CapabilityTokens,
    string ProtocolVersion,
    PeerCapabilities Capabilities)
{
    internal static DiscoveredPeer FromAdvertisement(DiscoveryAdvertisement advertisement) =>
        new(
            advertisement.ServiceKind,
            advertisement.DeviceId,
            advertisement.Name,
            advertisement.Platform,
            advertisement.PlatformLabel,
            advertisement.PublicKeyFingerprint,
            advertisement.Capabilities,
            advertisement.ProtocolVersion,
            advertisement.PeerCapabilities);
}
