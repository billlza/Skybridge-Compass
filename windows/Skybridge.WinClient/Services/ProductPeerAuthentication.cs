using Skybridge.WinClient.Services.RemoteControl;

namespace Skybridge.WinClient.Services;

/// <summary>One prepared handshake from the application's existing paired identity store.</summary>
internal sealed class ProductPeerAuthentication(DiscoveryPeerEndpoint endpoint, ProductHandshakePeerContext peer,
    WebRtcProductPqcHandshakeCryptoProvider crypto, RemoteControlSecurityIdentity localIdentity,
    RemoteControlPairingMaterial localPairing) : IDisposable
{
    internal DiscoveryPeerEndpoint Endpoint { get; } = endpoint;
    internal ProductHandshakePeerContext Peer { get; } = peer;
    internal WebRtcProductPqcHandshakeCryptoProvider Crypto { get; } = crypto;
    internal RemoteControlSecurityIdentity LocalIdentity { get; } = localIdentity;
    internal RemoteControlPairingMaterial LocalPairing { get; } = localPairing;
    public void Dispose() => Crypto.Dispose();
}
