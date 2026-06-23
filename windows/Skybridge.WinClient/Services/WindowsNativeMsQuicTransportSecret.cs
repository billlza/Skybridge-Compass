using System;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Shared, side-symmetric derivation of the Win-to-Win MsQuic transport-binding secret used by BOTH the
/// dialer (<see cref="WindowsNativeMsQuicTransportAdapterClient"/>) and the listener
/// (<see cref="WindowsNativeMsQuicListenerTransportAdapterClient"/>).
///
/// Why a single shared helper: the transport secret is folded into the Core transcript digest via
/// <see cref="CoreBridge.ComputeTransportBindingDigestAsync"/>, so the two peers MUST derive byte-identical
/// material or their digests will not match and the SkyBridge PQC handshake (which rides OVER this QUIC
/// tunnel) will refuse to bind. Each peer observes the QUIC session from its own vantage point:
///   - the dialer's "local" endpoint is the listener's "remote" endpoint (and vice versa);
///   - the dialer sees the listener's SERVER leaf cert in <c>connection.RemoteCertificate</c>, while the
///     listener sees the dialer's CLIENT leaf cert in <c>connection.RemoteCertificate</c>; each side also
///     holds its OWN presented leaf cert.
/// To collapse those asymmetric views into the same bytes we:
///   1. canonicalize the endpoint pair by ordinal sort (order-independent);
///   2. canonicalize the leaf-cert SHA-256 fingerprint pair by ordinal sort (so {dialerCertFp, listenerCertFp}
///      hashes identically on both ends regardless of which one each side calls "mine" vs "peer");
///   3. bind the negotiated ALPN and the shared pairing public-key fingerprint.
///
/// IMPORTANT HONESTY NOTE: this is a session-BINDING fingerprint, not real keying material. System.Net.Quic
/// still exposes no RFC 5705 TLS exporter (no <c>QuicConnection.ExportKeyingMaterial</c>; tracked in
/// dotnet/runtime), so we cannot extract the true QUIC secret yet. Binding the sorted leaf-cert pair makes a
/// swapped cert, a different UDP 5-tuple, or a different ALPN change the Core transcript digest, but the real
/// keying-material export lands only when the exporter ships.
/// </summary>
internal static class WindowsNativeMsQuicTransportSecret
{
    private const string DomainSeparator = "skybridge-msquic-transport-secret/v2";

    /// <summary>
    /// Computes the lowercase-hex SHA-256 fingerprint of a leaf certificate's DER bytes, or a stable
    /// sentinel when the certificate is absent (which must not happen on a healthy session, but is handled
    /// so the two sides still agree on the sentinel rather than throwing asymmetrically).
    /// </summary>
    public static string LeafFingerprint(X509Certificate2? certificate) =>
        certificate is null
            ? "no-leaf-cert"
            : Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();

    /// <summary>
    /// Derives the 32-byte transport secret from the two peers' views of the same QUIC session.
    ///
    /// All inputs are supplied from each peer's local vantage point; the method itself performs the
    /// order-independent canonicalization, so passing (localEndpoint, remoteEndpoint, ownCertFp, peerCertFp)
    /// on the dialer and the mirrored (localEndpoint, remoteEndpoint, ownCertFp, peerCertFp) on the listener
    /// yields identical bytes.
    /// </summary>
    /// <param name="localEndpoint">This peer's local QUIC UDP endpoint (host:port).</param>
    /// <param name="remoteEndpoint">The other peer's QUIC UDP endpoint (host:port).</param>
    /// <param name="negotiatedAlpn">The ALPN negotiated on the QUIC connection (must be "skybridge/1").</param>
    /// <param name="pairingPublicKeyFingerprint">The shared SkyBridge pairing public-key fingerprint.</param>
    /// <param name="ownLeafFingerprint">Lowercase-hex SHA-256 of THIS peer's presented leaf cert.</param>
    /// <param name="peerLeafFingerprint">Lowercase-hex SHA-256 of the OTHER peer's leaf cert.</param>
    public static byte[] Derive(
        string localEndpoint,
        string remoteEndpoint,
        string negotiatedAlpn,
        string pairingPublicKeyFingerprint,
        string ownLeafFingerprint,
        string peerLeafFingerprint)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localEndpoint);
        ArgumentException.ThrowIfNullOrWhiteSpace(remoteEndpoint);
        ArgumentNullException.ThrowIfNull(negotiatedAlpn);
        ArgumentNullException.ThrowIfNull(pairingPublicKeyFingerprint);
        ArgumentNullException.ThrowIfNull(ownLeafFingerprint);
        ArgumentNullException.ThrowIfNull(peerLeafFingerprint);

        // 1. Canonicalize the endpoint pair (order-independent): dialer.local == listener.remote and
        //    vice versa, so a fixed local|remote ordering would diverge between the two ends.
        var endpointPair = new[] { localEndpoint, remoteEndpoint };
        Array.Sort(endpointPair, StringComparer.Ordinal);

        // 2. Canonicalize the leaf-cert fingerprint pair (order-independent): the dialer holds
        //    {its client cert, listener's server cert} and the listener holds {dialer's client cert,
        //    its server cert} — the SAME set, just labelled "own"/"peer" oppositely. Sorting collapses
        //    both views to one ordering so the secret is mutual-cert symmetric.
        var certPair = new[] { ownLeafFingerprint, peerLeafFingerprint };
        Array.Sort(certPair, StringComparer.Ordinal);

        var material =
            $"{DomainSeparator}"
            + $"|alpn={negotiatedAlpn}"
            + $"|endpoints={endpointPair[0]}|{endpointPair[1]}"
            + $"|leafCerts={certPair[0]}|{certPair[1]}"
            + $"|pairingFp={pairingPublicKeyFingerprint}";

        return SHA256.HashData(Encoding.UTF8.GetBytes(material));
    }
}
