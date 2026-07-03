using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Quic;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

#pragma warning disable CA1416 // QUIC is platform-gated; this adapter only runs on Windows where MsQuic ships.

/// <summary>
/// First real Microsoft-native QUIC (MsQuic via <see cref="System.Net.Quic"/>) transport adapter for
/// Windows-to-Windows same-LAN sessions. Per docs/windows-architecture.md:11,34 and AGENTS.md:11,
/// Windows-to-Windows must prefer <c>WindowsNativeMsQuicTransport</c>; MsQuic v2.5.9 is the pinned
/// native QUIC stack and sits BELOW SkyBridge Core transport binding (it does not own session identity).
///
/// This adapter opens a live QUIC connection on the LAN to a Windows peer, derives the transport-binding
/// material from the negotiated QUIC session (local/remote endpoint, selected candidate, a stable
/// transport secret derived from the negotiated TLS connection plus certificate fingerprints, and a
/// capability digest), and flips <see cref="WindowsTransportAdapterSnapshot.IsLiveAdapterReady"/> to
/// <c>true</c> ONLY when a real QUIC endpoint plus a transport secret exist.
///
/// It mirrors <see cref="ExternalWindowsTransportAdapterClient"/>'s contract:
///   - resolves the adapter kind from the Core-selected transport via <see cref="ConnectionPreflightPlan.ResolveAdapterKind"/>;
///   - rejects <see cref="ConnectionLaunchAdapterKind.AppleNative"/> at the boundary (Apple-to-Apple stays Apple native);
///   - additionally requires the Core-selected transport to be <see cref="CoreTransportKind.WindowsNativeMsQuic"/>
///     and the audit code to be <see cref="CoreTransportAuditCode.WindowsNativeMsQuicSameLan"/>, because this is the
///     Win-to-Win MsQuic-only path (it never handles WebRTC / SkyBridgeIceMsQuic / Relay / TCP);
///   - produces a 32-byte transport-secret fingerprint and a 32-byte capability digest;
///   - the resulting <see cref="WindowsTransportAdapterSnapshot"/> feeds the SAME
///     <see cref="CoreBridge.ComputeTransportBindingDigestAsync"/> path used by every other adapter, so the
///     digest Core binds matches what this adapter advertised.
///
/// Capability negotiation: MsQuic is NEVER assumed. <see cref="MustAdvertiseMsQuic"/> requires BOTH the local
/// and remote <see cref="PeerCapabilities.SupportsMsQuic"/> flags (sourced from the Core-validated discovery
/// advertisement) before any QUIC dial is attempted. That is the same predicate
/// <c>TransportSelector::select</c> uses in core/skybridge-core/src/transport.rs to choose
/// <c>WindowsNativeMsQuic</c>, so this adapter cannot run unless Core already selected MsQuic for a peer that
/// advertised it.
/// </summary>
public sealed class WindowsNativeMsQuicTransportAdapterClient : IWindowsTransportAdapterClient
{
    // SkyBridge Win-to-Win QUIC ALPN. MsQuic requires at least one ALPN; this keeps the SkyBridge
    // session distinguishable from any other QUIC listener on the LAN and is bound into the secret.
    private const string SkyBridgeAlpn = "skybridge/1";

    private readonly WindowsNativeMsQuicTransportAdapterOptions _options;

    public WindowsNativeMsQuicTransportAdapterClient(WindowsNativeMsQuicTransportAdapterOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<WindowsTransportAdapterSnapshot> PrepareAsync(WindowsTransportAdapterRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var adapterKind = ConnectionPreflightPlan.ResolveAdapterKind(request.TransportKind);
        if (adapterKind == ConnectionLaunchAdapterKind.AppleNative)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic adapter must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (adapterKind != ConnectionLaunchAdapterKind.WindowsNativeMsQuic)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic adapter requires the Core-selected transport to be WindowsNativeMsQuic.");
        }

        if (request.TransportAudit != CoreTransportAuditCode.WindowsNativeMsQuicSameLan)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic adapter requires the Core transport audit to be WindowsNativeMsQuicSameLan.");
        }

        // Capability negotiation: MsQuic is never assumed. The peer must advertise it (and so must we).
        MustAdvertiseMsQuic(request.LocalCapabilities, "local");
        MustAdvertiseMsQuic(request.RemoteCapabilities, "remote");

        // MsQuic must be present in the runtime; if not, fail closed rather than silently downgrade.
        if (!QuicConnection.IsSupported)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic adapter requires System.Net.Quic / libmsquic (MsQuic v2.5.9) support, which is unavailable in this runtime.");
        }

        var live = await DialAsync(request).ConfigureAwait(false);

        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows MsQuic adapter",
                "live quic session",
                $"MsQuic (System.Net.Quic) opened a QUIC connection {live.LocalEndpoint} -> {live.RemoteEndpoint} "
                + $"with ALPN '{SkyBridgeAlpn}'; control/file/clipboard map to QUIC streams (MsQuicStream) per channel.rs."),
            new ConnectionPreflightFact(
                "MsQuic capability",
                "negotiated",
                "Both peers advertised SupportsMsQuic in the Core-validated discovery capabilities; MsQuic is never assumed."),
            new ConnectionPreflightFact(
                "MsQuic datagrams",
                "pending-runtime",
                "channel.rs maps telemetry/realtime to MsQuicDatagram, but System.Net.Quic does not yet expose the QUIC "
                + "datagram API (dotnet/runtime #123418, proposed Jan 2026). Until it ships, telemetry/realtime ride QUIC "
                + "streams as a temporary carrier; the Core channel mapping is unchanged.")
        };

        return new WindowsTransportAdapterSnapshot(
            ConnectionLaunchAdapterKind.WindowsNativeMsQuic,
            IsLiveAdapterReady: true,
            live.AdapterBinding,
            live.LocalEndpoint,
            live.RemoteEndpoint,
            live.SelectedCandidatePair,
            live.TransportSecretFingerprint,
            null, // RelayId: Win-to-Win same-LAN MsQuic is direct; relay is never used on this path.
            _options.TimestampWindowMs,
            CapabilityDigest(request),
            facts);
    }

    /// <summary>
    /// Opens the live QUIC connection and derives the binding material from the negotiated session.
    /// </summary>
    private async Task<LiveQuicBinding> DialAsync(WindowsTransportAdapterRequest request)
    {
        var (host, port) = ParseEndpoint(_options.PeerEndpoint);
        var remote = await ResolveRemoteAsync(host, port).ConfigureAwait(false);

        // The dialer presents its OWN ephemeral leaf cert so the listener can read it via
        // connection.RemoteCertificate. That is what lets BOTH sides derive the SAME transport secret from
        // the SORTED pair {dialerLeafFp, listenerLeafFp} (see WindowsNativeMsQuicTransportSecret). Without a
        // client cert the listener would only ever see one cert and the leaf-cert set would diverge.
        using var clientCertificate = WindowsNativeMsQuicEphemeralCertificate.Create("skybridge-msquic-dial");

        var clientOptions = new QuicClientConnectionOptions
        {
            RemoteEndPoint = remote,
            DefaultStreamErrorCode = 0,
            DefaultCloseErrorCode = 0,
            ClientAuthenticationOptions = new SslClientAuthenticationOptions
            {
                ApplicationProtocols = new List<SslApplicationProtocol> { new(SkyBridgeAlpn) },
                TargetHost = host,
                ClientCertificates = new X509CertificateCollection { clientCertificate },
                // QUIC mandates TLS 1.3. The SkyBridge PQC handshake rides OVER QUIC (inside the
                // skybridge.control stream as SBF1/SBP2 frames), so QUIC's TLS is the transport tunnel,
                // not the SkyBridge identity. We therefore pin BOTH leaf-cert fingerprints into the
                // transport secret (so a swapped cert changes the Core transcript digest) but do not
                // require a public CA chain on the LAN. The SkyBridge PQC handshake + pairing material is
                // the real peer authentication and runs above this tunnel.
                RemoteCertificateValidationCallback = (_, _, _, _) => true
            }
        };

        QuicConnection connection = await QuicConnection
            .ConnectAsync(clientOptions, CancellationToken.None)
            .ConfigureAwait(false);

        try
        {
            // Open the Control stream eagerly to prove a real, usable bidirectional QUIC stream exists
            // (control/file/clipboard map to MsQuicStream in core/skybridge-core/src/channel.rs).
            await using var controlStream = await connection
                .OpenOutboundStreamAsync(QuicStreamType.Bidirectional, CancellationToken.None)
                .ConfigureAwait(false);

            var localEndpoint = FormatEndpoint(connection.LocalEndPoint);
            var remoteEndpoint = FormatEndpoint(connection.RemoteEndPoint);
            var negotiatedAlpn = connection.NegotiatedApplicationProtocol.ToString();

            // Two-sided secret agreement: "own" = the dialer's presented client cert, "peer" = the
            // listener's server cert. The listener mirrors this with own=server, peer=dialer-client, and
            // WindowsNativeMsQuicTransportSecret sorts the pair so both reach the same bytes.
            var transportSecret = WindowsNativeMsQuicTransportSecret.Derive(
                localEndpoint,
                remoteEndpoint,
                negotiatedAlpn,
                request.PairingMaterial.PublicKeyFingerprint,
                WindowsNativeMsQuicTransportSecret.LeafFingerprint(clientCertificate),
                WindowsNativeMsQuicTransportSecret.LeafFingerprint(connection.RemoteCertificate as X509Certificate2));

            // "Selected candidate pair" for QUIC is the negotiated UDP 5-tuple plus ALPN; this is the
            // MsQuic analogue of an ICE candidate pair and is bound into the Core transcript digest.
            var selectedCandidatePair = $"msquic/udp/{localEndpoint}->{remoteEndpoint}/alpn={negotiatedAlpn}";
            var adapterBinding =
                "windows native msquic (System.Net.Quic, MsQuic v2.5.9) same-LAN; "
                + "streams=control,file,clipboard datagrams(pending-runtime)=telemetry,realtime";

            return new LiveQuicBinding(
                adapterBinding,
                localEndpoint,
                remoteEndpoint,
                selectedCandidatePair,
                transportSecret);
        }
        finally
        {
            await connection.DisposeAsync().ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Capability digest mirrors the shape produced by <see cref="PendingWindowsTransportAdapterClient"/>
    /// so the negotiated capabilities, peer, fingerprint, and network path are bound into the transcript.
    /// </summary>
    private static byte[] CapabilityDigest(WindowsTransportAdapterRequest request)
    {
        var material =
            $"local={FormatCapabilities(request.LocalCapabilities)};"
            + $"remote={FormatCapabilities(request.RemoteCapabilities)};"
            + $"peer={request.DiscoveredPeer.DeviceId};"
            + $"fingerprint={request.PairingMaterial.PublicKeyFingerprint};"
            + $"sameLan={request.NetworkPath.SameLan};"
            + $"crossNat={request.NetworkPath.CrossNat};"
            + $"transport=WindowsNativeMsQuic";
        return SHA256.HashData(Encoding.UTF8.GetBytes(material));
    }

    private static string FormatCapabilities(PeerCapabilities capabilities) =>
        $"{capabilities.Platform},{capabilities.SupportsAppleNative},{capabilities.SupportsMsQuic},"
        + $"{capabilities.SupportsSkyBridgeIceMsQuic},{capabilities.SupportsWebRtcDataChannel},"
        + $"{capabilities.SupportsTcpFallback},{capabilities.SupportsRelay}";

    private static void MustAdvertiseMsQuic(PeerCapabilities capabilities, string side)
    {
        if (!capabilities.SupportsMsQuic)
        {
            throw new InvalidOperationException(
                $"Windows native MsQuic adapter requires the {side} peer to advertise SupportsMsQuic; MsQuic must not be assumed.");
        }
    }

    private static (string Host, int Port) ParseEndpoint(string endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            throw new InvalidOperationException("Windows native MsQuic adapter requires a peer endpoint (host:port).");
        }

        var trimmed = endpoint.Trim();
        var separator = trimmed.LastIndexOf(':');
        if (separator <= 0 || separator == trimmed.Length - 1)
        {
            throw new InvalidOperationException(
                $"Windows native MsQuic adapter peer endpoint must be host:port; got '{endpoint}'.");
        }

        var host = trimmed[..separator];
        var portText = trimmed[(separator + 1)..];
        if (!int.TryParse(portText, out var port) || port is < 1 or > 65535)
        {
            throw new InvalidOperationException(
                $"Windows native MsQuic adapter peer endpoint port must be 1..65535; got '{portText}'.");
        }

        return (host, port);
    }

    private static async Task<IPEndPoint> ResolveRemoteAsync(string host, int port)
    {
        if (IPAddress.TryParse(host, out var literal))
        {
            return new IPEndPoint(literal, port);
        }

        var addresses = await Dns.GetHostAddressesAsync(host).ConfigureAwait(false);
        var address = addresses.FirstOrDefault()
            ?? throw new InvalidOperationException(
                $"Windows native MsQuic adapter could not resolve peer host '{host}'.");
        return new IPEndPoint(address, port);
    }

    private static string FormatEndpoint(IPEndPoint? endpoint) =>
        endpoint is null ? "0.0.0.0:0" : endpoint.ToString();

    private sealed record LiveQuicBinding(
        string AdapterBinding,
        string LocalEndpoint,
        string RemoteEndpoint,
        string SelectedCandidatePair,
        byte[] TransportSecretFingerprint);
}

public sealed class WindowsNativeMsQuicTransportAdapterOptions
{
    public WindowsNativeMsQuicTransportAdapterOptions(string peerEndpoint, ulong timestampWindowMs)
    {
        if (string.IsNullOrWhiteSpace(peerEndpoint))
        {
            throw new InvalidOperationException("Windows native MsQuic adapter requires a peer endpoint (host:port).");
        }

        if (timestampWindowMs == 0)
        {
            throw new InvalidOperationException("Windows native MsQuic adapter requires a non-zero timestamp window.");
        }

        PeerEndpoint = peerEndpoint.Trim();
        TimestampWindowMs = timestampWindowMs;
    }

    /// <summary>Target Windows peer QUIC endpoint on the LAN, host:port (e.g. 192.168.0.42:5443).</summary>
    public string PeerEndpoint { get; }

    public ulong TimestampWindowMs { get; }
}

#pragma warning restore CA1416
