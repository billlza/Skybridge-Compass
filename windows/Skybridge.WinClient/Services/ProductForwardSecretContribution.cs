using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

// Uses the Core's existing X25519 implementation; .NET 10 has no portable X25519 API.
internal sealed class ProductForwardSecretContribution : IDisposable
{
    private readonly byte[] _private = RandomNumberGenerator.GetBytes(32);
    private bool _disposed;

    internal ProductForwardSecretContribution()
    {
        SkybridgeNativeLibraryResolver.Register();
        var basepoint = new byte[32];
        basepoint[0] = 9;
        try { PublicKey = Agree(_private, basepoint); }
        catch { CryptographicOperations.ZeroMemory(_private); throw; }
    }

    internal byte[] PublicKey { get; }

    internal byte[] Derive(ReadOnlySpan<byte> peer)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Agree(_private, peer);
    }

    private static byte[] Agree(byte[] privateKey, ReadOnlySpan<byte> peer)
    {
        if (peer.Length != 32) throw new CryptographicException("X25519 peer contribution must be 32 bytes.");
        var result = new byte[32];
        var status = SharedSecret(privateKey, 32, peer.ToArray(), 32, result, 32);
        if (status == 0) return result;
        CryptographicOperations.ZeroMemory(result);
        throw new CryptographicException($"X25519 contribution rejected by Core (status {status}).");
    }

    internal static byte[] Compose(ReadOnlySpan<byte> staticSecret, ReadOnlySpan<byte> ephemeralSecret,
        ReadOnlySpan<byte> transcriptA, ushort suite)
    {
        if (suite != WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure ||
            staticSecret.Length != 32 || ephemeralSecret.Length != 32 || transcriptA.Length != 32)
            throw new CryptographicException("Invalid v2 secret composition inputs.");
        var prefix = Encoding.ASCII.GetBytes("SkyBridge-v2-compose|");
        var material = new byte[prefix.Length + 64];
        prefix.CopyTo(material, 0);
        staticSecret.CopyTo(material.AsSpan(prefix.Length));
        ephemeralSecret.CopyTo(material.AsSpan(prefix.Length + 32));
        var infoPrefix = Encoding.ASCII.GetBytes("SkyBridge-v2-static+ephemeral");
        var info = new byte[infoPrefix.Length + 2];
        infoPrefix.CopyTo(info, 0);
        BinaryPrimitives.WriteUInt16LittleEndian(info.AsSpan(infoPrefix.Length), suite);
        try { return ProductHandshakeKeyDerivation.HkdfSha256(material, transcriptA, info, 32); }
        finally { CryptographicOperations.ZeroMemory(material); }
    }

    public void Dispose()
    {
        if (_disposed) return;
        CryptographicOperations.ZeroMemory(_private);
        _disposed = true;
    }

    [DllImport("skybridge_core", EntryPoint = "skybridge_x25519_shared_secret", CallingConvention = CallingConvention.Cdecl)]
    private static extern int SharedSecret([In] byte[] privateKey, nuint privateLength, [In] byte[] peerKey,
        nuint peerLength, [Out] byte[] output, nuint outputCapacity);
}
