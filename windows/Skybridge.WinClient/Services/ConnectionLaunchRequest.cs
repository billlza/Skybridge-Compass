using System;
using System.Collections.Generic;

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
    IReadOnlyList<ChannelMapping> ChannelMappings,
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

        if (TransportKind == CoreTransportKind.AppleNative
            || AdapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException("Windows connection launch must not use AppleNative transport; Apple-to-Apple stays on the Apple native path.");
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

        if (ChannelMappings is null || ChannelMappings.Count != 5)
        {
            throw new InvalidOperationException("Connection launch requires all five Core channel mappings from preflight.");
        }

        var seenChannels = new HashSet<CoreChannelKind>();
        foreach (var mapping in ChannelMappings)
        {
            if (!IsChannelBindingKindValidForTransport(TransportKind, mapping.BindingKind))
            {
                throw new InvalidOperationException(
                    $"Connection launch channel mapping {mapping.Channel} uses {mapping.BindingKind}, which does not match {TransportKind}.");
            }

            if (!seenChannels.Add(mapping.Channel))
            {
                throw new InvalidOperationException("Connection launch Core channel mappings must not contain duplicate channels.");
            }
        }

        foreach (var requiredChannel in new[]
        {
            CoreChannelKind.Control,
            CoreChannelKind.File,
            CoreChannelKind.Clipboard,
            CoreChannelKind.Telemetry,
            CoreChannelKind.Realtime
        })
        {
            if (!seenChannels.Contains(requiredChannel))
            {
                throw new InvalidOperationException("Connection launch requires all five Core channel mappings from preflight.");
            }
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

    private static bool IsChannelBindingKindValidForTransport(
        CoreTransportKind transportKind,
        CoreAdapterBindingKind bindingKind) =>
        transportKind switch
        {
            CoreTransportKind.AppleNative =>
                bindingKind is CoreAdapterBindingKind.AppleStream
                    or CoreAdapterBindingKind.AppleDatagram,
            CoreTransportKind.WindowsNativeMsQuic
                or CoreTransportKind.SkyBridgeIceMsQuic =>
                bindingKind is CoreAdapterBindingKind.MsQuicStream
                    or CoreAdapterBindingKind.MsQuicDatagram,
            CoreTransportKind.WebRtcDataChannel =>
                bindingKind == CoreAdapterBindingKind.WebRtcDataChannel,
            CoreTransportKind.Relay =>
                bindingKind == CoreAdapterBindingKind.RelayStream,
            CoreTransportKind.TcpFallback =>
                bindingKind == CoreAdapterBindingKind.TcpStream,
            _ => false
        };
}
