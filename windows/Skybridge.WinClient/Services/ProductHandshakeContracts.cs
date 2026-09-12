using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public enum ProductHandshakeRole
{
    Initiator,
    Responder
}

/// <summary>One ordered, framed carrier. Ownership remains with the session across the handshake boundary.</summary>
public interface IProductHandshakeTransport
{
    Task SendAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken = default);

    Task<ReadOnlyMemory<byte>> ReadAsync(CancellationToken cancellationToken = default);
}

/// <summary>Authority resolved by the transport's trusted peer binding, never by a host name or address.</summary>
public sealed record ProductHandshakePeerContext(string PeerDeviceId, string PeerPublicKeyFingerprint);

public interface IProductHandshakeCryptoProvider
{
    ValueTask<WebRtcProductHandshakeMessageA> CreateInitiatorMessageAAsync(
        ProductHandshakePeerContext context, CancellationToken cancellationToken = default);

    ValueTask<ProductHandshakeSharedSecret> OpenResponderMessageBAsync(
        ProductHandshakePeerContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        WebRtcProductHandshakeMessageB messageB,
        CancellationToken cancellationToken = default);

    ValueTask<WebRtcProductHandshakeResponderMaterial> CreateResponderMessageBAsync(
        ProductHandshakePeerContext context,
        WebRtcProductHandshakeMessageA messageA,
        ReadOnlyMemory<byte> transcriptHashA,
        CancellationToken cancellationToken = default);

    void AbortInitiatorSecret(ReadOnlyMemory<byte> transcriptHashA);
}

public sealed class ProductHandshakeException : InvalidOperationException
{
    public ProductHandshakeException(string message) : base(message) { }

    public ProductHandshakeException(string message, Exception innerException) : base(message, innerException) { }
}

public sealed class ProductHandshakeSharedSecret : IDisposable
{
    private readonly byte[] _bytes;
    private bool _disposed;

    public ProductHandshakeSharedSecret(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 32) { throw new InvalidDataException("Product handshake shared secret must be 32 bytes."); }
        _bytes = bytes.ToArray();
    }

    public ReadOnlyMemory<byte> Bytes
    {
        get { ObjectDisposedException.ThrowIf(_disposed, this); return _bytes; }
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        CryptographicOperations.ZeroMemory(_bytes);
        _disposed = true;
    }
}

/// <summary>Exact authenticated session secrets. Callers own the instance and must dispose it at session teardown.</summary>
public sealed class ProductSessionKeys : IDisposable
{
    private readonly byte[] _transcriptHash;
    private readonly byte[] _sendKey;
    private readonly byte[] _receiveKey;
    private bool _disposed;

    public ProductSessionKeys(
        ProductHandshakeRole role, string sessionId, ReadOnlyMemory<byte> transcriptHash,
        ReadOnlyMemory<byte> sendKey, ReadOnlyMemory<byte> receiveKey)
    {
        if (role is not ProductHandshakeRole.Initiator and not ProductHandshakeRole.Responder)
        {
            throw new InvalidDataException("Product session role is invalid.");
        }
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        RequireLength(transcriptHash, nameof(transcriptHash));
        RequireLength(sendKey, nameof(sendKey));
        RequireLength(receiveKey, nameof(receiveKey));
        Role = role;
        SessionId = sessionId;
        _transcriptHash = transcriptHash.ToArray();
        _sendKey = sendKey.ToArray();
        _receiveKey = receiveKey.ToArray();
    }

    public ProductHandshakeRole Role { get; }
    public string SessionId { get; }
    public ReadOnlyMemory<byte> TranscriptHash { get { ThrowIfDisposed(); return _transcriptHash; } }
    public ReadOnlyMemory<byte> SendKey { get { ThrowIfDisposed(); return _sendKey; } }
    public ReadOnlyMemory<byte> ReceiveKey { get { ThrowIfDisposed(); return _receiveKey; } }
    public ProductSessionKeys Clone() => new(Role, SessionId, TranscriptHash, SendKey, ReceiveKey);

    public void Dispose()
    {
        if (_disposed) { return; }
        CryptographicOperations.ZeroMemory(_transcriptHash);
        CryptographicOperations.ZeroMemory(_sendKey);
        CryptographicOperations.ZeroMemory(_receiveKey);
        _disposed = true;
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    private static void RequireLength(ReadOnlyMemory<byte> bytes, string field)
    {
        if (bytes.Length != 32) { throw new InvalidDataException($"Product session {field} must be 32 bytes."); }
    }
}

/// <summary>Returned only after the peer's signature and Finished were verified and the local Finished was sent.</summary>
public sealed class AuthenticatedProductHandshake : IDisposable
{
    internal AuthenticatedProductHandshake(
        ProductSessionKeys keys, ushort suiteWireId, byte[] messageA, byte[] messageB)
    {
        Keys = keys.Clone();
        SuiteWireId = suiteWireId;
        MessageABytes = messageA.Length;
        MessageBBytes = messageB.Length;
        MessageASha256 = Convert.ToHexString(SHA256.HashData(messageA)).ToLowerInvariant();
        MessageBSha256 = Convert.ToHexString(SHA256.HashData(messageB)).ToLowerInvariant();
    }

    public ProductSessionKeys Keys { get; }
    public ushort SuiteWireId { get; }
    public int MessageABytes { get; }
    public int MessageBBytes { get; }
    public string MessageASha256 { get; }
    public string MessageBSha256 { get; }
    public void Dispose() => Keys.Dispose();
}

public sealed class WebRtcProductHandshakeResponderMaterial : IDisposable
{
    private readonly byte[] _sharedSecret;
    private bool _disposed;

    public WebRtcProductHandshakeResponderMaterial(
        WebRtcProductHandshakeMessageB messageB,
        ReadOnlyMemory<byte> sharedSecret)
    {
        MessageB = messageB ?? throw new ArgumentNullException(nameof(messageB));
        _sharedSecret = sharedSecret.ToArray();
    }

    public WebRtcProductHandshakeMessageB MessageB { get; }

    public ReadOnlyMemory<byte> SharedSecret
    {
        get
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(WebRtcProductHandshakeResponderMaterial));
            }

            return _sharedSecret;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        CryptographicOperations.ZeroMemory(_sharedSecret);
    }
}
