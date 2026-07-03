using System;
using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// App-side client for the helper's Mac product-control loopback IPC. This is
/// not the SBF1 data plane. Each local IPC message is one raw WebRTC
/// <c>skybridge</c> control-channel chunk, length-prefixed only because TCP is a
/// stream. The bytes inside are owned by the product handshake/SBWC layer.
/// </summary>
public interface IWebRtcProductControlPlane
{
    bool IsConnected { get; }

    Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default);

    event Action<byte[]> MessageReceived;
}

public sealed class WebRtcProductControlPlaneClient : IWebRtcProductControlPlane, IAsyncDisposable
{
    public const int LengthPrefixBytes = 4;
    public const int MaxControlFrameChunkBytes = 8192;
    public const int IpcAuthTokenBytes = 32;
    public const int IpcAuthNonceBytes = 32;
    public const int IpcAuthMacBytes = 32;
    internal const int IpcAuthFrameBytes = 8 + IpcAuthNonceBytes + IpcAuthMacBytes;

    private static readonly byte[] IpcAuthRequestMagic = Encoding.ASCII.GetBytes("SBPCARQ1");
    private static readonly byte[] IpcAuthResponseMagic = Encoding.ASCII.GetBytes("SBPCAOK1");

    private readonly string _host;
    private readonly int _port;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly byte[]? _ipcAuthToken;

    private TcpClient? _client;
    private NetworkStream? _stream;
    private CancellationTokenSource? _runCts;
    private Task? _pumpTask;
    private volatile bool _connected;
    private bool _disposed;

    public WebRtcProductControlPlaneClient(
        int port,
        string host = "127.0.0.1",
        ReadOnlyMemory<byte>? ipcAuthToken = null)
    {
        if (port is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port), port, "product-control IPC port must be 1..65535");
        }

        _host = string.IsNullOrWhiteSpace(host) ? "127.0.0.1" : host.Trim();
        if (!IsLoopbackHost(_host))
        {
            throw new InvalidOperationException(
                "product-control IPC must use a loopback host.");
        }

        _port = port;
        if (!ipcAuthToken.HasValue)
        {
            throw new InvalidOperationException(
                "product-control IPC requires an authentication token.");
        }

        _ipcAuthToken = ValidateIpcAuthToken(ipcAuthToken.Value.Span);
    }

    public bool IsConnected => _connected && !_disposed;

    public event Action<byte[]>? MessageReceived;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        lock (_gate)
        {
            if (_pumpTask is not null)
            {
                throw new InvalidOperationException("product-control client already started");
            }

            _runCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        }

        await ConnectOnceAsync(_runCts!.Token).ConfigureAwait(false);
        _pumpTask = Task.Run(() => PumpLoopAsync(_runCts.Token));
    }

    public async Task SendAsync(ReadOnlyMemory<byte> message, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ValidateMessage(message.Span, "product-control outbound message");

        var stream = _stream;
        if (!_connected || stream is null)
        {
            throw new InvalidOperationException(
                "product-control IPC is not connected; refusing to send (fail-closed)");
        }

        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var live = _stream;
            if (!_connected || live is null)
            {
                throw new InvalidOperationException(
                    "product-control IPC dropped before send completed (fail-closed)");
            }

            await WriteMessageAsync(live, message, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_runCts is not null)
        {
            await _runCts.CancelAsync().ConfigureAwait(false);
        }

        _client?.Dispose();
        if (_pumpTask is not null)
        {
            try
            {
                await _pumpTask.ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
            {
            }
        }

        _runCts?.Dispose();
        _writeLock.Dispose();
        if (_ipcAuthToken is not null)
        {
            CryptographicOperations.ZeroMemory(_ipcAuthToken);
        }

        _connected = false;
    }

    internal static async Task<byte[]?> ReadMessageAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[LengthPrefixBytes];
        var got = await ReadFullyAsync(stream, header, allowCleanEof: true, cancellationToken).ConfigureAwait(false);
        if (got == 0)
        {
            return null;
        }

        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length is 0 or > MaxControlFrameChunkBytes)
        {
            throw new InvalidDataException(
                $"product-control IPC message length {length} is outside 1..{MaxControlFrameChunkBytes}");
        }

        var message = new byte[(int)length];
        await ReadFullyAsync(stream, message, allowCleanEof: false, cancellationToken).ConfigureAwait(false);
        return message;
    }

    internal static async Task WriteMessageAsync(
        Stream stream,
        ReadOnlyMemory<byte> message,
        CancellationToken cancellationToken)
    {
        ValidateMessage(message.Span, "product-control IPC outbound message");
        var header = new byte[LengthPrefixBytes];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)message.Length);
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(message, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task ConnectOnceAsync(CancellationToken cancellationToken)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(_host, _port, cancellationToken).ConfigureAwait(false);
            var stream = client.GetStream();
            if (_ipcAuthToken is not null)
            {
                await AuthenticateIpcAsync(stream, _ipcAuthToken, cancellationToken).ConfigureAwait(false);
            }

            lock (_gate)
            {
                _client?.Dispose();
                _client = client;
                _stream = stream;
                _connected = true;
            }
            client = null;
        }
        catch
        {
            client?.Dispose();
            throw;
        }
    }

    private static bool IsLoopbackHost(string host)
    {
        if (string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return IPAddress.TryParse(host, out var address) && IPAddress.IsLoopback(address);
    }

    private static async Task AuthenticateIpcAsync(
        Stream stream,
        byte[] token,
        CancellationToken cancellationToken)
    {
        var nonce = RandomNumberGenerator.GetBytes(IpcAuthNonceBytes);
        try
        {
            await WriteMessageAsync(stream, BuildIpcAuthRequest(token, nonce), cancellationToken).ConfigureAwait(false);
            var response = await ReadMessageAsync(stream, cancellationToken).ConfigureAwait(false);
            if (response is null)
            {
                throw new InvalidDataException("product-control IPC closed before authentication response.");
            }

            ValidateIpcAuthResponse(token, nonce, response);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(nonce);
        }
    }

    private async Task PumpLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            var stream = _stream ?? throw new InvalidOperationException("product-control IPC stream was not initialized.");
            while (!cancellationToken.IsCancellationRequested)
            {
                var message = await ReadMessageAsync(stream, cancellationToken).ConfigureAwait(false);
                if (message is null)
                {
                    return;
                }

                MessageReceived?.Invoke(message);
            }
        }
        finally
        {
            _connected = false;
        }
    }

    private static void ValidateMessage(ReadOnlySpan<byte> message, string label)
    {
        if (message.IsEmpty)
        {
            throw new InvalidDataException($"{label} must not be empty");
        }

        if (message.Length > MaxControlFrameChunkBytes)
        {
            throw new InvalidDataException(
                $"{label} length {message.Length} exceeds {MaxControlFrameChunkBytes} bytes");
        }
    }

    internal static byte[] BuildIpcAuthRequest(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> nonce)
    {
        ValidateIpcAuthInputs(token, nonce);
        var frame = new byte[IpcAuthFrameBytes];
        IpcAuthRequestMagic.CopyTo(frame, 0);
        nonce.CopyTo(frame.AsSpan(IpcAuthRequestMagic.Length, IpcAuthNonceBytes));
        WriteAuthMac(
            token,
            IpcAuthRequestMagic,
            nonce,
            frame.AsSpan(IpcAuthRequestMagic.Length + IpcAuthNonceBytes, IpcAuthMacBytes));
        return frame;
    }

    internal static byte[] BuildIpcAuthResponse(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> nonce)
    {
        ValidateIpcAuthInputs(token, nonce);
        var frame = new byte[IpcAuthFrameBytes];
        IpcAuthResponseMagic.CopyTo(frame, 0);
        nonce.CopyTo(frame.AsSpan(IpcAuthResponseMagic.Length, IpcAuthNonceBytes));
        WriteAuthMac(
            token,
            IpcAuthResponseMagic,
            nonce,
            frame.AsSpan(IpcAuthResponseMagic.Length + IpcAuthNonceBytes, IpcAuthMacBytes));
        return frame;
    }

    internal static void ValidateIpcAuthRequest(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> frame,
        Span<byte> nonceOut)
    {
        ValidateIpcAuthFrame(token, frame, IpcAuthRequestMagic, "request", nonceOut);
    }

    internal static void ValidateIpcAuthResponse(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> expectedNonce,
        ReadOnlySpan<byte> frame)
    {
        Span<byte> nonce = stackalloc byte[IpcAuthNonceBytes];
        ValidateIpcAuthFrame(token, frame, IpcAuthResponseMagic, "response", nonce);
        if (!CryptographicOperations.FixedTimeEquals(nonce, expectedNonce))
        {
            throw new InvalidDataException("product-control IPC authentication response nonce mismatch.");
        }
    }

    private static byte[] ValidateIpcAuthToken(ReadOnlySpan<byte> token)
    {
        if (token.Length != IpcAuthTokenBytes)
        {
            throw new InvalidDataException(
                $"product-control IPC authentication token must be {IpcAuthTokenBytes} bytes.");
        }

        return token.ToArray();
    }

    private static void ValidateIpcAuthInputs(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> nonce)
    {
        if (token.Length != IpcAuthTokenBytes)
        {
            throw new InvalidDataException(
                $"product-control IPC authentication token must be {IpcAuthTokenBytes} bytes.");
        }

        if (nonce.Length != IpcAuthNonceBytes)
        {
            throw new InvalidDataException(
                $"product-control IPC authentication nonce must be {IpcAuthNonceBytes} bytes.");
        }
    }

    private static void ValidateIpcAuthFrame(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> frame,
        ReadOnlySpan<byte> expectedMagic,
        string label,
        Span<byte> nonceOut)
    {
        if (nonceOut.Length != IpcAuthNonceBytes)
        {
            throw new ArgumentException(
                $"product-control IPC authentication nonce output must be {IpcAuthNonceBytes} bytes.",
                nameof(nonceOut));
        }

        if (frame.Length != IpcAuthFrameBytes)
        {
            throw new InvalidDataException(
                $"product-control IPC authentication {label} has invalid length.");
        }

        if (!frame[..expectedMagic.Length].SequenceEqual(expectedMagic))
        {
            throw new InvalidDataException(
                $"product-control IPC authentication {label} magic mismatch.");
        }

        var nonce = frame.Slice(expectedMagic.Length, IpcAuthNonceBytes);
        nonce.CopyTo(nonceOut);
        Span<byte> expectedMac = stackalloc byte[IpcAuthMacBytes];
        WriteAuthMac(token, expectedMagic, nonce, expectedMac);
        var actualMac = frame.Slice(expectedMagic.Length + IpcAuthNonceBytes, IpcAuthMacBytes);
        var valid = CryptographicOperations.FixedTimeEquals(actualMac, expectedMac);
        expectedMac.Clear();
        if (!valid)
        {
            throw new InvalidDataException(
                $"product-control IPC authentication {label} MAC verification failed.");
        }
    }

    private static void WriteAuthMac(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> magic,
        ReadOnlySpan<byte> nonce,
        Span<byte> output)
    {
        ValidateIpcAuthInputs(token, nonce);
        Span<byte> payload = stackalloc byte[8 + IpcAuthNonceBytes];
        try
        {
            magic.CopyTo(payload);
            nonce.CopyTo(payload[magic.Length..]);
            HMACSHA256.HashData(token, payload, output);
        }
        finally
        {
            payload.Clear();
        }
    }

    private static async Task<int> ReadFullyAsync(
        Stream stream,
        Memory<byte> buffer,
        bool allowCleanEof,
        CancellationToken cancellationToken)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer[total..], cancellationToken).ConfigureAwait(false);
            if (n == 0)
            {
                if (total == 0 && allowCleanEof)
                {
                    return 0;
                }

                throw new EndOfStreamException(
                    $"product-control IPC stream closed mid-message ({total}/{buffer.Length} bytes)");
            }

            total += n;
        }

        return total;
    }
}
