using System;

namespace Skybridge.WinClient.Services;

public enum ConnectionLaunchAdapterKind
{
    None,
    AppleNative,
    WindowsNativeMsQuic,
    SkyBridgeIceMsQuic,
    WebRtcDataChannel,
    Relay,
    TcpFallback
}

public sealed record ConnectionLaunchRequest(
    PairingMaterial PairingMaterial,
    ConnectionPreflightSnapshot PreflightSnapshot)
{
    public ConnectionPreflightPlan Plan => PreflightSnapshot.Plan;
}

public sealed record ConnectionPreflightPlan(
    string PeerDeviceId,
    string PeerPublicKeyFingerprint,
    CoreTransportKind TransportKind,
    CoreTransportAuditCode TransportAudit,
    bool RelayRequired,
    bool RelayAllowed,
    CoreCryptoSuiteKind SelectedSuite,
    ushort SelectedSuiteWireId,
    CoreCryptoSuiteAuditCode SuiteAudit,
    bool Sbp2Enabled,
    nuint Sbp2FixedPayloadLen,
    nuint FrameHeaderLen,
    byte[] TransportBindingDigest,
    ConnectionLaunchAdapterKind AdapterKind,
    bool IsLiveAdapterReady,
    string AdapterBinding,
    string LocalEndpoint,
    string RemoteEndpoint,
    string SelectedCandidatePair,
    string? RelayId,
    ulong TimestampWindowMs)
{
    public static ConnectionLaunchAdapterKind ResolveAdapterKind(CoreTransportKind transportKind) =>
        transportKind switch
        {
            CoreTransportKind.AppleNative => ConnectionLaunchAdapterKind.AppleNative,
            CoreTransportKind.WindowsNativeMsQuic => ConnectionLaunchAdapterKind.WindowsNativeMsQuic,
            CoreTransportKind.SkyBridgeIceMsQuic => ConnectionLaunchAdapterKind.SkyBridgeIceMsQuic,
            CoreTransportKind.WebRtcDataChannel => ConnectionLaunchAdapterKind.WebRtcDataChannel,
            CoreTransportKind.Relay => ConnectionLaunchAdapterKind.Relay,
            CoreTransportKind.TcpFallback => ConnectionLaunchAdapterKind.TcpFallback,
            _ => ConnectionLaunchAdapterKind.None
        };

    public void ValidateForLaunch(PairingMaterial pairingMaterial)
    {
        ArgumentNullException.ThrowIfNull(pairingMaterial);
        ArgumentNullException.ThrowIfNull(TransportBindingDigest);

        if (AdapterKind == ConnectionLaunchAdapterKind.None)
        {
            throw new InvalidOperationException("Connection launch requires a concrete transport adapter kind.");
        }

        if (string.IsNullOrWhiteSpace(AdapterBinding))
        {
            throw new InvalidOperationException("Connection launch requires an adapter binding description.");
        }

        if (string.IsNullOrWhiteSpace(LocalEndpoint))
        {
            throw new InvalidOperationException("Connection launch requires a local transport endpoint.");
        }

        if (string.IsNullOrWhiteSpace(RemoteEndpoint))
        {
            throw new InvalidOperationException("Connection launch requires a remote transport endpoint.");
        }

        if (string.IsNullOrWhiteSpace(SelectedCandidatePair))
        {
            throw new InvalidOperationException("Connection launch requires a selected transport candidate pair.");
        }

        if (TimestampWindowMs == 0)
        {
            throw new InvalidOperationException("Connection launch requires a non-zero transport timestamp window.");
        }

        if (TransportBindingDigest.Length != 32)
        {
            throw new InvalidOperationException("Connection launch requires a 32-byte transport binding digest from Core preflight.");
        }

        if (!string.Equals(PeerDeviceId, pairingMaterial.DeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Connection launch request peer does not match pairing material.");
        }

        if (!string.Equals(
            PeerPublicKeyFingerprint,
            pairingMaterial.PublicKeyFingerprint,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Connection launch request fingerprint does not match pairing material.");
        }
    }
}
