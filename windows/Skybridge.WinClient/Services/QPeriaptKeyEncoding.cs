using System.Security.Cryptography;

namespace Skybridge.WinClient.Services;

/// <summary>The shared Apple/Android expanded identity layout, backed by ABI 2 operations.</summary>
internal static class QPeriaptKeyEncoding
{
    internal const int PublicLength = 1216;
    internal const int PrivateLength = 3648;
    internal const int CiphertextLength = 1120;

    internal static byte[] ExportPublic(QPeriaptKeyPair owner)
    {
        using var material = owner.Capture();
        var encoded = new byte[PublicLength];
        material.PublicPq.CopyTo(encoded, 0); material.PublicTraditional.CopyTo(encoded, 1184);
        return encoded;
    }

    internal static byte[] ExportPrivate(QPeriaptKeyPair owner)
    {
        using var material = owner.Capture();
        var encoded = new byte[PrivateLength];
        material.PrivatePq.CopyTo(encoded, 0); material.PrivateTraditional.CopyTo(encoded, 2400);
        material.PublicPq.CopyTo(encoded, 2432); material.PublicTraditional.CopyTo(encoded, 3616);
        return encoded;
    }

    internal static QPeriaptKeyPair Import(QPeriaptRuntimeSession session, ReadOnlySpan<byte> encoded)
    {
        if (encoded.Length != PrivateLength) { throw new InvalidDataException("Expanded Q-Periapt private key must contain 3648 bytes."); }
        var owner = new QPeriaptKeyPair(encoded[..2400].ToArray(), encoded.Slice(2432, 1184).ToArray(),
            encoded.Slice(2400, 32).ToArray(), encoded.Slice(3616, 32).ToArray());
        try { Verify(session, owner); return owner; }
        catch { owner.Dispose(); throw; }
    }

    internal static void Verify(QPeriaptRuntimeSession session, QPeriaptKeyPair owner)
    {
        var context = "SkyBridge-Q-Periapt-Identity-Storage-Check-v1"u8;
        using var encapsulation = QPeriaptNativeClient.Encapsulate(session.Decision,
            owner.CopyPublicPq(), owner.CopyPublicTraditional(), context);
        using var recovered = QPeriaptNativeClient.Decapsulate(session.Decision, owner,
            encapsulation.CiphertextPq.Span, encapsulation.CiphertextTraditional.Span, context);
        if (!CryptographicOperations.FixedTimeEquals(encapsulation.Secret.Bytes.Span, recovered.Bytes.Span))
        { throw new CryptographicException("Stored Q-Periapt identity does not match its public key."); }
    }
}
