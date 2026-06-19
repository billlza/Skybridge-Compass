using System;
using System.Collections.Generic;
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
/// Inbound (LISTENER) half of the Windows-native Microsoft QUIC (MsQuic via <see cref="System.Net.Quic"/>)
/// transport for Windows-to-Windows same-LAN sessions. This is the T7b counterpart to the T7a dialer
/// (<see cref="WindowsNativeMsQuicTransportAdapterClient"/>): instead of opening a QUIC connection to a peer,
/// it binds a local UDP port with <see cref="QuicListener"/>, ACCEPTS an inbound <see cref="QuicConnection"/>
/// (ALPN "skybridge/1", TLS 1.3), and accepts the inbound bidirectional control stream the dialer opens.
///
/// Together the two halves close the bidirectional Win-to-Win MsQuic path: one Windows box runs the listener
/// (role=listen), the other runs the dialer (role=dial), and both derive the SAME transport-binding secret
/// via <see cref="WindowsNativeMsQuicTransportSecret"/> so the Core transcript digest matches end-to-end.
///
/// Contract parity with the dialer (so the same <see cref="ConnectionPreflightClient"/> /
/// <see cref="CoreBridge.ComputeTransportBindingDigestAsync"/> path consumes it unchanged):
///   - resolves the adapter kind via <see cref="ConnectionPreflightPlan.ResolveAdapterKind"/> and rejects
///     <see cref="ConnectionLaunchAdapterKind.AppleNative"/> at the boundary;
///   - requires the Core-selected transport to be <see cref="ConnectionLaunchAdapterKind.WindowsNativeMsQuic"/>
///     and the audit code to be <see cref="CoreTransportAuditCode.WindowsNativeMsQuicSameLan"/>;
///   - requires BOTH peers to advertise <see cref="PeerCapabilities.SupportsMsQuic"/> (MsQuic is never assumed);
///   - emits a 32-byte transport-secret fingerprint + a 32-byte capability digest;
///   - flips <see cref="WindowsTransportAdapterSnapshot.IsLiveAdapterReady"/> to <c>true</c> ONLY after a real
///     inbound connection + accepted bidirectional stream + derived secret exist.
///
/// TLS server certificate: QUIC's mandatory TLS 1.3 server side needs a cert. There is no public CA on the
/// LAN and the SkyBridge PQC handshake riding INSIDE the control stream is the real peer auth, so we generate
/// an ephemeral self-signed ECDSA P-256 cert at runtime (<see cref="WindowsNativeMsQuicEphemeralCertificate"/>)
/// and accept the dialer's client cert unconditionally at the TLS layer — mirroring the dialer's
/// RemoteCertificateValidationCallback rationale — while BINDING both leaf-cert fingerprints into the secret.
/// </summary>
public sealed class WindowsNativeMsQuicListenerTransportAdapterClient : IWindowsTransportAdapterClient
{
    private const string SkyBridgeAlpn = "skybridge/1";

    private readonly WindowsNativeMsQuicListenerTransportAdapterOptions _options;

    public WindowsNativeMsQuicListenerTransportAdapterClient(WindowsNativeMsQuicListenerTransportAdapterOptions options)
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
                "Windows native MsQuic listener must not select AppleNative; Apple-to-Apple remains on the Apple native path.");
        }

        if (adapterKind != ConnectionLaunchAdapterKind.WindowsNativeMsQuic)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic listener requires the Core-selected transport to be WindowsNativeMsQuic.");
        }

        if (request.TransportAudit != CoreTransportAuditCode.WindowsNativeMsQuicSameLan)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic listener requires the Core transport audit to be WindowsNativeMsQuicSameLan.");
        }

        // Capability negotiation: MsQuic is never assumed. The peer must advertise it (and so must we).
        MustAdvertiseMsQuic(request.LocalCapabilities, "local");
        MustAdvertiseMsQuic(request.RemoteCapabilities, "remote");

        // MsQuic must be present in the runtime; if not, fail closed rather than silently downgrade.
        if (!QuicListener.IsSupported)
        {
            throw new InvalidOperationException(
                "Windows native MsQuic listener requires System.Net.Quic / libmsquic (MsQuic v2.5.8) support, which is unavailable in this runtime.");
        }

        var live = await ListenAndAcceptAsync(request).ConfigureAwait(false);

        var facts = new[]
        {
            new ConnectionPreflightFact(
                "Windows MsQuic listener",
                "live inbound quic session",
                $"MsQuic (System.Net.Quic) accepted an inbound QUIC connection {live.RemoteEndpoint} -> {live.LocalEndpoint} "
                + $"with ALPN '{SkyBridgeAlpn}' and accepted the inbound control stream (MsQuicStream) per channel.rs."),
            new ConnectionPreflightFact(
                "MsQuic capability",
                "negotiated",
                "Both peers advertised SupportsMsQuic in the Core-validated discovery capabilities; MsQuic is never assumed."),
            new ConnectionPreflightFact(
                "MsQuic server cert",
                "ephemeral self-signed",
                "QUIC TLS 1.3 server cert is an ephemeral self-signed ECDSA P-256 leaf (no CA, short-lived). The "
                + "SkyBridge PQC handshake inside the control stream is the real peer auth; both leaf-cert "
                + "fingerprints are bound into the transport secret."),
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
    /// Binds the local UDP endpoint, accepts ONE inbound QUIC connection + its inbound bidirectional control
    /// stream, and derives the binding material from the negotiated session. An accept deadline bounds the
    /// wait so PrepareAsync cannot hang forever when no dialer arrives.
    /// </summary>
    private async Task<LiveQuicBinding> ListenAndAcceptAsync(WindowsTransportAdapterRequest request)
    {
        var listenEndpoint = ParseListenEndpoint(_options.ListenEndpoint);

        // The listener presents its OWN ephemeral leaf cert as the QUIC TLS server credential. The dialer
        // presents its own client cert; both leaf fingerprints feed the SORTED pair in
        // WindowsNativeMsQuicTransportSecret so the two ends agree on the secret.
        using var serverCertificate = WindowsNativeMsQuicEphemeralCertificate.Create("skybridge-msquic-listen");

        var listenerOptions = new QuicListenerOptions
        {
            ListenEndPoint = listenEndpoint,
            ApplicationProtocols = new List<SslApplicationProtocol> { new(SkyBridgeAlpn) },
            ConnectionOptionsCallback = (_, _, _) => ValueTask.FromResult(new QuicServerConnectionOptions
            {
                DefaultStreamErrorCode = 0,
                DefaultCloseErrorCode = 0,
                ServerAuthenticationOptions = new SslServerAuthenticationOptions
                {
                    ApplicationProtocols = new List<SslApplicationProtocol> { new(SkyBridgeAlpn) },
                    ServerCertificate = serverCertificate,
                    // Request the dialer's client cert so connection.RemoteCertificate is populated for the
                    // two-sided secret, but do NOT require a trusted chain: real auth is the PQC handshake
                    // above this tunnel. We accept the presented client cert unconditionally at the TLS layer
                    // and instead bind its fingerprint into the transport secret.
                    ClientCertificateRequired = true,
                    RemoteCertificateValidationCallback = (_, _, _, _) => true
                }
            })
        };

        var acceptCts = new CancellationTokenSource(TimeSpan.FromMilliseconds(_options.AcceptTimeoutMs));
        await using var listener = await QuicListener
            .ListenAsync(listenerOptions, acceptCts.Token)
            .ConfigureAwait(false);

        QuicConnection connection = await listener
            .AcceptConnectionAsync(acceptCts.Token)
            .ConfigureAwait(false);

        try
        {
            // Accept the inbound bidirectional control stream the dialer opens. This proves a real, usable
            // bidirectional QUIC stream exists in BOTH directions before we flip IsLiveAdapterReady.
            await using var controlStream = await connection
                .AcceptInboundStreamAsync(acceptCts.Token)
                .ConfigureAwait(false);

            var localEndpoint = FormatEndpoint(connection.LocalEndPoint);
            var remoteEndpoint = FormatEndpoint(connection.RemoteEndPoint);
            var negotiatedAlpn = connection.NegotiatedApplicationProtocol.ToString();

            // Two-sided secret agreement: "own" = the listener's server cert, "peer" = the dialer's client
            // cert. The dialer mirrors this with own=client, peer=listener-server; the shared helper sorts
            // the leaf-cert pair so both reach identical bytes.
            var transportSecret = WindowsNativeMsQuicTransportSecret.Derive(
                localEndpoint,
                remoteEndpoint,
                negotiatedAlpn,
                request.PairingMaterial.PublicKeyFingerprint,
                WindowsNativeMsQuicTransportSecret.LeafFingerprint(serverCertificate),
                WindowsNativeMsQuicTransportSecret.LeafFingerprint(connection.RemoteCertificate as X509Certificate2));

            var selectedCandidatePair = $"msquic/udp/{localEndpoint}->{remoteEndpoint}/alpn={negotiatedAlpn}";
            var adapterBinding =
                "windows native msquic listener (System.Net.Quic, MsQuic v2.5.8) same-LAN; "
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
    /// Capability digest mirrors the dialer's shape EXACTLY (same domain string, same field order, same
    /// "transport=WindowsNativeMsQuic" tag) so a listener and dialer paired on the same session bind the same
    /// capability material into the Core transcript.
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
                $"Windows native MsQuic listener requires the {side} peer to advertise SupportsMsQuic; MsQuic must not be assumed.");
        }
    }

    private static IPEndPoint ParseListenEndpoint(string endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            throw new InvalidOperationException("Windows native MsQuic listener requires a listen endpoint (host:port).");
        }

        var trimmed = endpoint.Trim();
        var separator = trimmed.LastIndexOf(':');
        if (separator <= 0 || separator == trimmed.Length - 1)
        {
            throw new InvalidOperationException(
                $"Windows native MsQuic listener endpoint must be host:port; got '{endpoint}'.");
        }

        var host = trimmed[..separator];
        var portText = trimmed[(separator + 1)..];
        if (!int.TryParse(portText, out var port) || port is < 1 or > 65535)
        {
            throw new InvalidOperationException(
                $"Windows native MsQuic listener endpoint port must be 1..65535; got '{portText}'.");
        }

        if (string.Equals(host, "0.0.0.0", StringComparison.Ordinal) || host.Length == 0)
        {
            return new IPEndPoint(IPAddress.Any, port);
        }

        if (string.Equals(host, "::", StringComparison.Ordinal))
        {
            return new IPEndPoint(IPAddress.IPv6Any, port);
        }

        if (!IPAddress.TryParse(host, out var address))
        {
            throw new InvalidOperationException(
                $"Windows native MsQuic listener endpoint host must be an IP literal (e.g. 0.0.0.0 or 192.168.0.42); got '{host}'.");
        }

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

public sealed class WindowsNativeMsQuicListenerTransportAdapterOptions
{
    public WindowsNativeMsQuicListenerTransportAdapterOptions(
        string listenEndpoint,
        ulong timestampWindowMs,
        ulong acceptTimeoutMs = 60_000)
    {
        if (string.IsNullOrWhiteSpace(listenEndpoint))
        {
            throw new InvalidOperationException("Windows native MsQuic listener requires a listen endpoint (host:port).");
        }

        if (timestampWindowMs == 0)
        {
            throw new InvalidOperationException("Windows native MsQuic listener requires a non-zero timestamp window.");
        }

        if (acceptTimeoutMs == 0)
        {
            throw new InvalidOperationException("Windows native MsQuic listener requires a non-zero accept timeout.");
        }

        ListenEndpoint = listenEndpoint.Trim();
        TimestampWindowMs = timestampWindowMs;
        AcceptTimeoutMs = acceptTimeoutMs;
    }

    /// <summary>Local QUIC bind endpoint on the LAN, host:port (e.g. 0.0.0.0:5443 or 192.168.0.42:5443).</summary>
    public string ListenEndpoint { get; }

    public ulong TimestampWindowMs { get; }

    /// <summary>Bound wait for an inbound dialer so PrepareAsync cannot hang indefinitely.</summary>
    public ulong AcceptTimeoutMs { get; }
}

#pragma warning restore CA1416
