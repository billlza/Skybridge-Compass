using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using SIPSorcery.Net;

namespace Skybridge.WebRtcHelper;

// ============================================================================
// Mac product WebRTC control transport shell (helper side)
// ============================================================================
//
// This profile is intentionally separate from SessionTransport/SBF1. The Mac
// product WebRTC control channel uses DataChannel label "skybridge" and sends
// product control chunks directly over that channel. The local loopback IPC is a
// stream, so the helper frames each raw DataChannel message as:
//
//   u32_be message_length (1..8192)
//   message_length raw bytes
//
// The 8192-byte cap matches the Apple control frame chunk boundary
// (max padded payload 8188 bytes + 4-byte product length prefix). The helper is
// a bounded, fail-closed byte pump only; it does not parse handshake frames,
// decrypt SBWC envelopes, or fall back to SBF1.
internal static class ProductControlTransport
{
    public const string DataChannelLabel = "skybridge";
    public const int LengthPrefixBytes = 4;
    public const int MaxControlFrameChunkBytes = 8192;
    public const int IpcAuthTokenBytes = 32;
    public const int IpcAuthNonceBytes = 32;
    public const int IpcAuthMacBytes = 32;

    private const int InboundQueueCapacity = 64;
    private const int IpcAuthFrameBytes = 8 + IpcAuthNonceBytes + IpcAuthMacBytes;
    private static readonly byte[] IpcAuthRequestMagic = Encoding.ASCII.GetBytes("SBPCARQ1");
    private static readonly byte[] IpcAuthResponseMagic = Encoding.ASCII.GetBytes("SBPCAOK1");

    public static async Task<byte[]?> ReadMessageAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[LengthPrefixBytes];
        var got = await ReadFullyAsync(stream, header, allowCleanEof: true, ct).ConfigureAwait(false);
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
        await ReadFullyAsync(stream, message, allowCleanEof: false, ct).ConfigureAwait(false);
        return message;
    }

    public static async Task WriteMessageAsync(Stream stream, ReadOnlyMemory<byte> message, CancellationToken ct)
    {
        ValidateMessage(message.Span, "product-control IPC outbound message");
        var header = new byte[LengthPrefixBytes];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)message.Length);
        await stream.WriteAsync(header, ct).ConfigureAwait(false);
        await stream.WriteAsync(message, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    public static async Task AuthenticateIpcServerAsync(
        Stream stream,
        byte[] token,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentNullException.ThrowIfNull(token);

        var nonce = new byte[IpcAuthNonceBytes];
        byte[]? request = null;
        try
        {
            RandomNumberGenerator.Fill(nonce);
            request = BuildIpcAuthRequest(token, nonce);
            await WriteMessageAsync(stream, request, ct).ConfigureAwait(false);

            var response = await ReadMessageAsync(stream, ct).ConfigureAwait(false);
            if (response is null)
            {
                throw new InvalidDataException("product-control IPC server closed before authentication response.");
            }

            ValidateIpcAuthResponse(token, response, nonce);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(nonce);
            if (request is not null)
            {
                CryptographicOperations.ZeroMemory(request);
            }
        }
    }

    public static async Task RunSessionAsync(
        RTCDataChannel dc,
        int loopbackPort,
        Action<int> reportBoundPort,
        string tag,
        byte[]? ipcAuthToken,
        CancellationToken ct)
    {
        if (!string.Equals(dc.label, DataChannelLabel, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"product-control transport requires DataChannel label '{DataChannelLabel}', got '{dc.label}'.");
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var failureLock = new object();
        Exception? fatalError = null;

        void FailSession(Exception ex)
        {
            lock (failureLock)
            {
                fatalError ??= ex;
            }

            linked.Cancel();
        }

        var inbound = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(InboundQueueCapacity)
        {
            SingleReader = true,
            SingleWriter = false,
            FullMode = BoundedChannelFullMode.Wait,
        });

        dc.onmessage += (_, _, data) =>
        {
            try
            {
                ValidateMessage(data, "peer product-control message");
            }
            catch (InvalidDataException ex)
            {
                Console.Error.WriteLine($"[{tag}] rejecting peer product-control message: {ex.Message}");
                inbound.Writer.TryComplete(ex);
                FailSession(ex);
                return;
            }

            if (!inbound.Writer.TryWrite(data))
            {
                var message = $"peer->app product-control queue is full ({InboundQueueCapacity} messages); closing transport";
                Console.Error.WriteLine($"[{tag}] {message}");
                var error = new InvalidOperationException(message);
                inbound.Writer.TryComplete(error);
                FailSession(error);
                return;
            }

            Console.WriteLine($"[{tag}] <- peer product-control bytes={data.Length}");
        };

        _ = Task.Run(async () =>
        {
            try
            {
                while (!linked.IsCancellationRequested && dc.readyState == RTCDataChannelState.open)
                {
                    await Task.Delay(250, linked.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
            finally
            {
                Console.WriteLine($"[{tag}] DataChannel state={dc.readyState}; completing product-control inbound");
                inbound.Writer.TryComplete();
            }
        }, ct);

        var listener = new TcpListener(IPAddress.Loopback, loopbackPort);
        listener.Start();
        var actualPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        reportBoundPort(actualPort);
        Console.WriteLine($"[{tag}] product-control IPC listening on 127.0.0.1:{actualPort} (u32-be length-prefixed raw messages)");
        Console.WriteLine($"SKYBRIDGE_PRODUCT_CONTROL_PORT={actualPort}");

        try
        {
            while (!linked.IsCancellationRequested)
            {
                TcpClient client;
                try
                {
                    client = await listener.AcceptTcpClientAsync(linked.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                Console.WriteLine($"[{tag}] product-control IPC client connected");
                using (client)
                {
                    client.NoDelay = true;
                    using var stream = client.GetStream();
                    using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
                    if (ipcAuthToken is not null)
                    {
                        using var authCts = CancellationTokenSource.CreateLinkedTokenSource(sessionCts.Token);
                        authCts.CancelAfter(TimeSpan.FromSeconds(5));
                        try
                        {
                            await AuthenticateIpcClientAsync(stream, ipcAuthToken, authCts.Token).ConfigureAwait(false);
                            Console.WriteLine($"[{tag}] product-control IPC client authenticated");
                        }
                        catch (Exception ex) when (ex is InvalidDataException or IOException or OperationCanceledException)
                        {
                            Console.Error.WriteLine($"[{tag}] product-control IPC client rejected before pump: {ex.Message}");
                            continue;
                        }
                    }

                    var appToPeer = PumpAppToPeerAsync(stream, dc, tag, sessionCts.Token);
                    var peerToApp = PumpPeerToAppAsync(stream, inbound.Reader, tag, sessionCts.Token);
                    var finished = await Task.WhenAny(appToPeer, peerToApp).ConfigureAwait(false);
                    try
                    {
                        await finished.ConfigureAwait(false);
                    }
                    finally
                    {
                        sessionCts.Cancel();
                        await SafeAwait(appToPeer, tag).ConfigureAwait(false);
                        await SafeAwait(peerToApp, tag).ConfigureAwait(false);
                    }
                }

                Console.WriteLine($"[{tag}] product-control IPC client disconnected");
                if (dc.readyState != RTCDataChannelState.open)
                {
                    break;
                }
            }
        }
        finally
        {
            listener.Stop();
        }

        if (fatalError is not null)
        {
            throw new InvalidOperationException("WebRTC helper product-control transport failed.", fatalError);
        }
    }

    private static async Task PumpAppToPeerAsync(Stream stream, RTCDataChannel dc, string tag, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            byte[]? message;
            try
            {
                message = await ReadMessageAsync(stream, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex) when (ex is EndOfStreamException or InvalidDataException)
            {
                Console.Error.WriteLine($"[{tag}] app->peer product-control message rejected: {ex.Message}");
                throw;
            }
            catch (IOException ex)
            {
                Console.Error.WriteLine($"[{tag}] app->peer product-control read ended: {ex.Message}");
                return;
            }

            if (message is null)
            {
                return;
            }

            if (dc.readyState != RTCDataChannelState.open)
            {
                Console.Error.WriteLine($"[{tag}] dropping app->peer product-control message: DataChannel not open");
                return;
            }

            dc.send(message);
            Console.WriteLine($"[{tag}] -> peer product-control bytes={message.Length}");
        }
    }

    private static async Task AuthenticateIpcClientAsync(
        Stream stream,
        byte[] token,
        CancellationToken ct)
    {
        var request = await ReadMessageAsync(stream, ct).ConfigureAwait(false);
        if (request is null)
        {
            throw new InvalidDataException("product-control IPC client closed before authentication request.");
        }

        var nonce = new byte[IpcAuthNonceBytes];
        ValidateIpcAuthRequest(token, request, nonce);
        try
        {
            await WriteMessageAsync(stream, BuildIpcAuthResponse(token, nonce), ct).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(nonce);
        }
    }

    private static async Task PumpPeerToAppAsync(Stream stream, ChannelReader<byte[]> inbound, string tag, CancellationToken ct)
    {
        try
        {
            await foreach (var message in inbound.ReadAllAsync(ct).ConfigureAwait(false))
            {
                await WriteMessageAsync(stream, message, ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[{tag}] peer->app product-control write ended: {ex.Message}");
        }
    }

    private static async Task SafeAwait(Task task, string tag)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[{tag}] product-control pump closed during teardown: {ex.Message}");
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

    public static byte[] DecodeIpcAuthTokenFromBase64(string base64, string label)
    {
        byte[] token;
        try
        {
            token = Convert.FromBase64String(base64);
        }
        catch (FormatException ex)
        {
            throw new InvalidDataException($"{label} must be base64 encoded.", ex);
        }

        if (token.Length != IpcAuthTokenBytes)
        {
            CryptographicOperations.ZeroMemory(token);
            throw new InvalidDataException($"{label} must decode to {IpcAuthTokenBytes} bytes.");
        }

        return token;
    }

    private static byte[] BuildIpcAuthResponse(
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

    private static byte[] BuildIpcAuthRequest(
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

    private static void ValidateIpcAuthRequest(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> frame,
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
            throw new InvalidDataException("product-control IPC authentication request has invalid length.");
        }

        if (!frame[..IpcAuthRequestMagic.Length].SequenceEqual(IpcAuthRequestMagic))
        {
            throw new InvalidDataException("product-control IPC authentication request magic mismatch.");
        }

        var nonce = frame.Slice(IpcAuthRequestMagic.Length, IpcAuthNonceBytes);
        nonce.CopyTo(nonceOut);
        Span<byte> expectedMac = stackalloc byte[IpcAuthMacBytes];
        WriteAuthMac(token, IpcAuthRequestMagic, nonce, expectedMac);
        var actualMac = frame.Slice(IpcAuthRequestMagic.Length + IpcAuthNonceBytes, IpcAuthMacBytes);
        var valid = CryptographicOperations.FixedTimeEquals(actualMac, expectedMac);
        expectedMac.Clear();
        if (!valid)
        {
            throw new InvalidDataException("product-control IPC authentication request MAC verification failed.");
        }
    }

    private static void ValidateIpcAuthResponse(
        ReadOnlySpan<byte> token,
        ReadOnlySpan<byte> frame,
        ReadOnlySpan<byte> expectedNonce)
    {
        if (frame.Length != IpcAuthFrameBytes)
        {
            throw new InvalidDataException("product-control IPC authentication response has invalid length.");
        }

        if (!frame[..IpcAuthResponseMagic.Length].SequenceEqual(IpcAuthResponseMagic))
        {
            throw new InvalidDataException("product-control IPC authentication response magic mismatch.");
        }

        var nonce = frame.Slice(IpcAuthResponseMagic.Length, IpcAuthNonceBytes);
        if (!nonce.SequenceEqual(expectedNonce))
        {
            throw new InvalidDataException("product-control IPC authentication response nonce mismatch.");
        }

        Span<byte> expectedMac = stackalloc byte[IpcAuthMacBytes];
        WriteAuthMac(token, IpcAuthResponseMagic, nonce, expectedMac);
        var actualMac = frame.Slice(IpcAuthResponseMagic.Length + IpcAuthNonceBytes, IpcAuthMacBytes);
        var valid = CryptographicOperations.FixedTimeEquals(actualMac, expectedMac);
        expectedMac.Clear();
        if (!valid)
        {
            throw new InvalidDataException("product-control IPC authentication response MAC verification failed.");
        }
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
        CancellationToken ct)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer[total..], ct).ConfigureAwait(false);
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
