using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using SIPSorcery.Net;

namespace Skybridge.WebRtcHelper;

// ============================================================================
// SkyBridge Windows DATA PLANE (helper side)
// ============================================================================
//
// This is the persistent, multi-channel, framed transport that turns the
// one-shot "open DataChannel + echo one frame" proof into a continuous
// bidirectional byte plane. Clipboard / file / remote-desktop all build on it.
//
// Topology (one helper process per WebRTC peer connection):
//
//     local app  <--loopback TCP-->  helper  <--WebRTC DataChannel-->  peer
//     (WinClient)   127.0.0.1:port   (this)        DTLS+SCTP            (Apple/box)
//
// FRAMING (identical on BOTH hops, so the helper is a verbatim pump):
//   Every message is one SBF1 frame exactly as core/skybridge-core/src/frame.rs
//   defines it (20-byte big-endian header + payload). SBF1 is SELF-DELIMITING:
//   the header's payload_len (bytes 16..20) gives the exact payload size, so no
//   extra length wrapper is needed on the loopback socket. We read 20 header
//   bytes, parse payload_len, read that many payload bytes => one frame. The
//   same bytes are written to the DataChannel unchanged, and vice-versa.
//
//   WebRTC SCTP in SIPSorcery delivers each `dc.send(bytes)` as one discrete
//   `onmessage(bytes)` (message-oriented, reliable+ordered by default), so a
//   single SBF1 frame == a single DataChannel message. The helper does NOT
//   reassemble END_OF_MESSAGE multi-frame logical messages; it forwards each
//   SBF1 frame verbatim and lets the application (WinClient SkyBridgeDataPlaneClient
//   / Apple core) reassemble per END_OF_MESSAGE. This keeps the helper a dumb,
//   robust, channel-agnostic pipe.
//
// The loopback listener binds 127.0.0.1 only (never 0.0.0.0): the IPC is
// reachable solely from processes on the same machine. See the open-items note
// in the deliverable for the residual local-trust caveat.
internal static class SessionTransport
{
    public const int Sbf1HeaderLen = 20;
    private const byte Sbf1Version = 1;
    private const uint MaxPayloadBytes = 64u * 1024 * 1024;
    private const int InboundQueueCapacity = 256;
    private const int IpcAuthMaxLineBytes = 1024;
    private static readonly TimeSpan IpcAuthTimeout = TimeSpan.FromSeconds(5);
    private static readonly byte[] Sbf1Magic = { 0x53, 0x42, 0x46, 0x31 }; // "SBF1"

    // Reads exactly one SBF1 frame (header + declared payload) from a stream.
    // Returns null on a clean EOF at a frame boundary (peer closed). Throws on a
    // mid-frame EOF or a malformed header so callers fail closed rather than
    // silently desync the byte stream.
    public static async Task<byte[]?> ReadFrameAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[Sbf1HeaderLen];
        var got = await ReadFullyAsync(stream, header, allowCleanEof: true, ct).ConfigureAwait(false);
        if (got == 0)
        {
            return null; // clean EOF at a frame boundary
        }

        if (!header.AsSpan(0, 4).SequenceEqual(Sbf1Magic))
        {
            throw new InvalidDataException("data-plane stream desync: frame did not start with SBF1 magic");
        }

        var payloadLen = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(16, 4));
        // Hard cap so a bogus/hostile length can't allocate the process to death.
        // 64 MiB is far above any real clipboard/file CHUNK; large files are sent
        // as many END_OF_MESSAGE-flagged frames, not one giant payload.
        if (payloadLen > MaxPayloadBytes)
        {
            throw new InvalidDataException(
                $"data-plane frame payload_len {payloadLen} exceeds {MaxPayloadBytes} cap; refusing");
        }

        var frame = new byte[Sbf1HeaderLen + (int)payloadLen];
        header.CopyTo(frame, 0);
        if (payloadLen > 0)
        {
            var slice = frame.AsMemory(Sbf1HeaderLen, (int)payloadLen);
            await ReadFullyAsync(stream, slice, allowCleanEof: false, ct).ConfigureAwait(false);
        }

        return frame;
    }

    private static async Task<int> ReadFullyAsync(Stream stream, Memory<byte> buffer, bool allowCleanEof, CancellationToken ct)
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
                    $"data-plane stream closed mid-frame ({total}/{buffer.Length} bytes)");
            }

            total += n;
        }

        return total;
    }

    // The channel code a frame is destined for (header byte 5). Used only for
    // logging on the helper; routing is by the application.
    public static byte ChannelOf(ReadOnlySpan<byte> frame) =>
        frame.Length > 5 ? frame[5] : (byte)0;

    public static ushort FlagsOf(ReadOnlySpan<byte> frame) =>
        frame.Length >= 8 ? BinaryPrimitives.ReadUInt16BigEndian(frame.Slice(6, 2)) : (ushort)0;

    // ------------------------------------------------------------------------
    // The bidirectional pump. Runs until either side closes. `toPeer` enqueues
    // frames arriving from the loopback app onto the DataChannel; `fromPeer`
    // frames arriving on the DataChannel are written back to the loopback app.
    // ------------------------------------------------------------------------
    public static async Task RunSessionAsync(
        RTCDataChannel dc,
        int loopbackPort,
        Action<int> reportBoundPort,
        string tag,
        CancellationToken ct,
        string? ipcToken = null)
    {
        // Inbound (DataChannel -> app) frames are buffered here so the SCTP
        // receive callback never blocks on a slow/absent loopback reader.
        var inbound = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(InboundQueueCapacity)
        {
            SingleReader = true,
            SingleWriter = false,
            FullMode = BoundedChannelFullMode.Wait
        });

        dc.onmessage += (_, _, data) =>
        {
            // SIPSorcery hands us the exact bytes the peer sent in one dc.send.
            // That is one whole SBF1 frame. Forward verbatim.
            if (data is { Length: > 0 })
            {
                if (!TryValidateFrame(data, out var validationError))
                {
                    inbound.Writer.TryComplete(new InvalidDataException(
                        $"peer sent invalid SBF1 frame: {validationError}"));
                    return;
                }

                if (!inbound.Writer.TryWrite(data))
                {
                    inbound.Writer.TryComplete(new InvalidDataException(
                        $"peer inbound SBF1 queue exceeded {InboundQueueCapacity} frames"));
                    return;
                }

                if (data.Length >= Sbf1HeaderLen)
                {
                    Console.WriteLine(
                        $"[{tag}] <- peer frame channel={ChannelOf(data)} flags=0x{FlagsOf(data):x4} bytes={data.Length}");
                }
            }
        };
        // RTCDataChannel teardown is observed via readyState (onclose/onerror are
        // not relied on — only onopen/onmessage are part of the surface this
        // helper depends on). A watcher completes the inbound channel once the
        // DataChannel leaves the open state so the peer->app pump can drain+exit.
        _ = Task.Run(async () =>
        {
            try
            {
                while (!ct.IsCancellationRequested && dc.readyState == RTCDataChannelState.open)
                {
                    await Task.Delay(250, ct).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
            finally
            {
                Console.WriteLine($"[{tag}] DataChannel state={dc.readyState}; completing inbound");
                inbound.Writer.TryComplete();
            }
        }, ct);

        // Loopback listener: 127.0.0.1 only. Port 0 => OS picks a free port.
        var listener = new TcpListener(IPAddress.Loopback, loopbackPort);
        listener.Start();
        var actualPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        reportBoundPort(actualPort);
        Console.WriteLine($"[{tag}] data-plane IPC listening on 127.0.0.1:{actualPort} (SBF1-framed)");
        Console.WriteLine($"SKYBRIDGE_DATAPLANE_PORT={actualPort}"); // machine-parseable handshake line

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        try
        {
            // Accept exactly one app connection at a time (one helper == one peer
            // == one app session). A second connect waits until the first ends.
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

                Console.WriteLine($"[{tag}] data-plane IPC client connected");
                using (client)
                {
                    client.NoDelay = true;
                    using var stream = client.GetStream();
                    if (!string.IsNullOrWhiteSpace(ipcToken)
                        && !await AuthenticateIpcClientAsync(stream, ipcToken!, tag, linked.Token).ConfigureAwait(false))
                    {
                        continue;
                    }

                    // Pump both directions for this client; either ending tears down both.
                    using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
                    var appToPeer = PumpAppToPeerAsync(stream, dc, tag, sessionCts.Token);
                    var peerToApp = PumpPeerToAppAsync(stream, inbound.Reader, tag, sessionCts.Token);
                    var finished = await Task.WhenAny(appToPeer, peerToApp).ConfigureAwait(false);
                    sessionCts.Cancel();
                    await SafeAwait(appToPeer).ConfigureAwait(false);
                    await SafeAwait(peerToApp).ConfigureAwait(false);
                    _ = finished;
                }

                Console.WriteLine($"[{tag}] data-plane IPC client disconnected");

                // If the DataChannel is gone there is nothing left to serve.
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
    }

    private static bool TryValidateFrame(byte[] frame, out string error)
    {
        if (frame.Length < Sbf1HeaderLen)
        {
            error = $"frame length {frame.Length} is shorter than SBF1 header";
            return false;
        }

        if (!frame.AsSpan(0, 4).SequenceEqual(Sbf1Magic))
        {
            error = "missing SBF1 magic";
            return false;
        }

        if (frame[4] != Sbf1Version)
        {
            error = $"unsupported SBF1 version {frame[4]}";
            return false;
        }

        if (!IsKnownChannel(frame[5]))
        {
            error = $"unknown SBF1 channel {frame[5]}";
            return false;
        }

        var payloadLen = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(16, 4));
        if (payloadLen > MaxPayloadBytes)
        {
            error = $"payload_len {payloadLen} exceeds {MaxPayloadBytes}";
            return false;
        }

        var expectedLength = Sbf1HeaderLen + (long)payloadLen;
        if (frame.LongLength != expectedLength)
        {
            error = $"payload_len {payloadLen} does not match frame length {frame.Length}";
            return false;
        }

        error = "";
        return true;
    }

    private static bool IsKnownChannel(byte channel) => channel is >= 1 and <= 5;

    private static async Task<bool> AuthenticateIpcClientAsync(
        NetworkStream stream,
        string expectedToken,
        string tag,
        CancellationToken ct)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(IpcAuthTimeout);

        string line;
        try
        {
            line = await ReadAuthLineAsync(stream, timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Console.Error.WriteLine($"[{tag}] data-plane IPC auth timed out");
            return false;
        }
        catch (IOException ex)
        {
            Console.Error.WriteLine($"[{tag}] data-plane IPC auth read failed: {ex.Message}");
            return false;
        }
        catch (InvalidDataException ex)
        {
            Console.Error.WriteLine($"[{tag}] data-plane IPC auth rejected: {ex.Message}");
            return false;
        }

        const string prefix = "SKYBRIDGE-IPCTOKEN ";
        if (!line.StartsWith(prefix, StringComparison.Ordinal))
        {
            Console.Error.WriteLine($"[{tag}] data-plane IPC auth rejected: missing token prefix");
            return false;
        }

        var presentedToken = line[prefix.Length..].Trim();
        if (!FixedTimeEquals(presentedToken, expectedToken))
        {
            Console.Error.WriteLine($"[{tag}] data-plane IPC auth rejected: token mismatch");
            return false;
        }

        Console.WriteLine($"[{tag}] data-plane IPC client authenticated");
        return true;
    }

    private static async Task<string> ReadAuthLineAsync(Stream stream, CancellationToken ct)
    {
        var bytes = new List<byte>(IpcAuthMaxLineBytes);
        var buffer = new byte[1];
        while (bytes.Count < IpcAuthMaxLineBytes)
        {
            var read = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
            if (read == 0)
            {
                throw new IOException("data-plane IPC closed before auth token");
            }

            if (buffer[0] == (byte)'\n')
            {
                return Encoding.UTF8.GetString(bytes.ToArray()).TrimEnd('\r');
            }

            bytes.Add(buffer[0]);
        }

        throw new InvalidDataException($"auth line exceeds {IpcAuthMaxLineBytes} bytes");
    }

    private static bool FixedTimeEquals(string presentedToken, string expectedToken)
    {
        var presented = Encoding.UTF8.GetBytes(presentedToken);
        var expected = Encoding.UTF8.GetBytes(expectedToken);
        return presented.Length == expected.Length
            && CryptographicOperations.FixedTimeEquals(presented, expected);
    }

    // App (loopback) -> peer (DataChannel). Reads whole SBF1 frames off the
    // socket and forwards each onto the DataChannel verbatim.
    private static async Task PumpAppToPeerAsync(Stream stream, RTCDataChannel dc, string tag, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            byte[]? frame;
            try
            {
                frame = await ReadFrameAsync(stream, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex) when (ex is IOException or EndOfStreamException or InvalidDataException)
            {
                Console.Error.WriteLine($"[{tag}] app->peer read ended: {ex.Message}");
                return;
            }

            if (frame is null)
            {
                return; // app closed
            }

            if (dc.readyState != RTCDataChannelState.open)
            {
                Console.Error.WriteLine($"[{tag}] dropping app->peer frame: DataChannel not open");
                return;
            }

            dc.send(frame);
            if (frame.Length >= Sbf1HeaderLen)
            {
                Console.WriteLine(
                    $"[{tag}] -> peer frame channel={ChannelOf(frame)} flags=0x{FlagsOf(frame):x4} bytes={frame.Length}");
            }
        }
    }

    // Peer (DataChannel) -> app (loopback). Drains the inbound channel and writes
    // each frame verbatim to the socket.
    private static async Task PumpPeerToAppAsync(Stream stream, ChannelReader<byte[]> inbound, string tag, CancellationToken ct)
    {
        try
        {
            await foreach (var frame in inbound.ReadAllAsync(ct).ConfigureAwait(false))
            {
                await stream.WriteAsync(frame, ct).ConfigureAwait(false);
                await stream.FlushAsync(ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[{tag}] peer->app write ended: {ex.Message}");
        }
    }

    private static async Task SafeAwait(Task t)
    {
        try
        {
            await t.ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is OperationCanceledException
            or IOException
            or ObjectDisposedException
            or EndOfStreamException
            or InvalidDataException)
        {
            // Both pumps are torn down via cancellation; swallow their unwind.
        }
    }
}
