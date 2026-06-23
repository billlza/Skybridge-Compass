using System;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Generates the short-lived, self-signed leaf certificate that QUIC's mandatory TLS 1.3 layer requires.
///
/// QUIC always runs TLS, and TLS always needs a certificate on the server side (and, for the two-sided
/// secret agreement in <see cref="WindowsNativeMsQuicTransportSecret"/>, on the client side too). On the
/// Win-to-Win same-LAN path there is no public CA and no certificate trust to establish: the REAL peer
/// authentication is the SkyBridge PQC handshake that rides INSIDE the QUIC control stream (SBF1/SBP2
/// frames). The QUIC TLS layer is purely the encrypted tunnel. We therefore:
///   - generate an ephemeral ECDSA P-256 self-signed cert at process start (no key on disk, no CA);
///   - accept the peer's cert unconditionally at the TLS layer (RemoteCertificateValidationCallback => true),
///     mirroring the dialer's documented rationale;
///   - BIND both leaf-cert SHA-256 fingerprints into the transport secret so a swapped cert still perturbs
///     the Core transcript digest even though TLS itself does not verify a chain.
/// The cert is valid for a short window (minutes) because it lives only for the lifetime of the adapter
/// instance and is never persisted or reused across sessions.
/// </summary>
internal static class WindowsNativeMsQuicEphemeralCertificate
{
    /// <summary>
    /// Creates a fresh ECDSA P-256 self-signed certificate WITH an exportable private key, suitable for use
    /// as a QUIC TLS server or client certificate. The returned certificate must be disposed by the caller.
    /// </summary>
    /// <param name="subjectCommonName">
    /// The CN to stamp into the subject/issuer DN (purely cosmetic on this path; e.g. "skybridge-msquic-listen").
    /// </param>
    public static X509Certificate2 Create(string subjectCommonName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(subjectCommonName);

        using var ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(
            $"CN={subjectCommonName}",
            ecdsa,
            HashAlgorithmName.SHA256);

        // Leaf cert (not a CA): basic constraints end-entity, digital signature usage, server+client EKUs so
        // the same generator works for either QUIC role.
        request.CertificateExtensions.Add(
            new X509BasicConstraintsExtension(certificateAuthority: false, hasPathLengthConstraint: false, pathLengthConstraint: 0, critical: true));
        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, critical: true));
        request.CertificateExtensions.Add(
            new X509EnhancedKeyUsageExtension(
                new OidCollection
                {
                    new Oid("1.3.6.1.5.5.7.3.1"), // serverAuth
                    new Oid("1.3.6.1.5.5.7.3.2")  // clientAuth
                },
                critical: false));

        var notBefore = DateTimeOffset.UtcNow.AddMinutes(-5);
        var notAfter = DateTimeOffset.UtcNow.AddHours(1);
        using var ephemeral = request.CreateSelfSigned(notBefore, notAfter);

        // Round-trip through a PFX so the returned certificate owns an EXPORTABLE private key handle that
        // System.Net.Quic (SChannel) can consume as a TLS credential. The in-memory-only password is never
        // persisted; the bytes live only for this process.
        var pfxPassword = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var pfxBytes = ephemeral.Export(X509ContentType.Pfx, pfxPassword);
        return X509CertificateLoader.LoadPkcs12(
            pfxBytes,
            pfxPassword,
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
    }
}
