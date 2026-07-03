using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
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
    private const uint MaxSbf1PayloadBytes = 64u * 1024 * 1024;
    private const int InboundFrameQueueCapacity = 64;
    private const ushort FlagSbp2Padded = 0x0001;
    private const ushort FlagEndOfMessage = 0x0002;
    private const ushort KnownFlagsMask = FlagSbp2Padded | FlagEndOfMessage;
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
        if (payloadLen > MaxSbf1PayloadBytes)
        {
            throw new InvalidDataException(
                $"data-plane frame payload_len {payloadLen} exceeds {MaxSbf1PayloadBytes} cap; refusing");
        }

        var frame = new byte[Sbf1HeaderLen + (int)payloadLen];
        header.CopyTo(frame, 0);
        if (payloadLen > 0)
        {
            var slice = frame.AsMemory(Sbf1HeaderLen, (int)payloadLen);
            await ReadFullyAsync(stream, slice, allowCleanEof: false, ct).ConfigureAwait(false);
        }

        if (!TryValidateSbf1Frame(frame, out var rejectionReason))
        {
            throw new InvalidDataException(rejectionReason);
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
        CancellationToken ct)
    {
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

        // Inbound (DataChannel -> app) frames are buffered here so the SCTP receive callback never
        // blocks on a slow/absent loopback reader. Keep it bounded: if the local app cannot drain,
        // fail the session rather than letting a peer allocate unbounded helper memory.
        var inbound = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(InboundFrameQueueCapacity)
        {
            SingleReader = true,
            SingleWriter = false,
            FullMode = BoundedChannelFullMode.Wait,
        });

        dc.onmessage += (_, _, data) =>
        {
            // SIPSorcery hands us the exact bytes the peer sent in one dc.send.
            // That must be one whole SBF1 frame. Validate at the helper boundary before the bytes
            // are forwarded to the local app over loopback.
            if (data is not { Length: > 0 })
            {
                return;
            }

            if (!TryValidateSbf1Frame(data, out var rejectionReason))
            {
                Console.Error.WriteLine($"[{tag}] rejecting peer frame: {rejectionReason}");
                var error = new InvalidDataException(rejectionReason);
                inbound.Writer.TryComplete(error);
                FailSession(error);
                return;
            }

            if (!inbound.Writer.TryWrite(data))
            {
                var message = $"peer->app inbound queue is full ({InboundFrameQueueCapacity} frames); closing data-plane session";
                Console.Error.WriteLine($"[{tag}] {message}");
                var error = new InvalidOperationException(message);
                inbound.Writer.TryComplete(error);
                FailSession(error);
                return;
            }

            Console.WriteLine(
                $"[{tag}] <- peer frame channel={ChannelOf(data)} flags=0x{FlagsOf(data):x4} bytes={data.Length}");
        };
        // RTCDataChannel teardown is observed via readyState (onclose/onerror are
        // not relied on — only onopen/onmessage are part of the surface this
        // helper depends on). A watcher completes the inbound channel once the
        // DataChannel leaves the open state so the peer->app pump can drain+exit.
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
                    // Pump both directions for this client; either ending tears down both.
                    using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
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

        if (fatalError is not null)
        {
            throw new InvalidOperationException("WebRTC helper data-plane session failed.", fatalError);
        }
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
            catch (Exception ex) when (ex is EndOfStreamException or InvalidDataException)
            {
                Console.Error.WriteLine($"[{tag}] app->peer frame rejected: {ex.Message}");
                throw;
            }
            catch (IOException ex)
            {
                Console.Error.WriteLine($"[{tag}] app->peer read ended: {ex.Message}");
                return;
            }

            if (frame is null)
            {
                return; // app closed
            }

            if (!TryValidateSbf1Frame(frame, out var rejectionReason))
            {
                Console.Error.WriteLine($"[{tag}] app->peer frame rejected: {rejectionReason}");
                throw new InvalidDataException(rejectionReason);
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
            return;
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[{tag}] peer->app write ended: {ex.Message}");
        }
    }

    private static async Task SafeAwait(Task t, string tag)
    {
        try
        {
            await t.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[{tag}] pump closed during session teardown: {ex.Message}");
        }
    }

    private static bool TryValidateSbf1Frame(ReadOnlySpan<byte> frame, out string rejectionReason)
    {
        if (frame.Length < Sbf1HeaderLen)
        {
            rejectionReason = $"frame length {frame.Length} is shorter than SBF1 header length {Sbf1HeaderLen}";
            return false;
        }

        if (!frame[..4].SequenceEqual(Sbf1Magic))
        {
            rejectionReason = "frame did not start with SBF1 magic";
            return false;
        }

        if (frame[4] != Sbf1Version)
        {
            rejectionReason = $"frame used unsupported SBF1 version {frame[4]}";
            return false;
        }

        if (!IsKnownChannel(frame[5]))
        {
            rejectionReason = $"frame used unknown channel code {frame[5]}";
            return false;
        }

        var flags = BinaryPrimitives.ReadUInt16BigEndian(frame.Slice(6, 2));
        if ((flags & ~KnownFlagsMask) != 0)
        {
            rejectionReason = $"frame used unknown SBF1 flags 0x{flags:x4}";
            return false;
        }

        var payloadLen = BinaryPrimitives.ReadUInt32BigEndian(frame.Slice(16, 4));
        if (payloadLen > MaxSbf1PayloadBytes)
        {
            rejectionReason = $"frame payload_len {payloadLen} exceeds {MaxSbf1PayloadBytes} cap";
            return false;
        }

        var actualPayloadLen = frame.Length - Sbf1HeaderLen;
        if (payloadLen != actualPayloadLen)
        {
            rejectionReason = $"frame payload_len {payloadLen} does not match message payload bytes {actualPayloadLen}";
            return false;
        }

        rejectionReason = string.Empty;
        return true;
    }

    private static bool IsKnownChannel(byte code) => code is >= 1 and <= 5;
}
