using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// ============================================================================
// SkyBridge Windows DATA PLANE — client (app side of the helper loopback IPC).
// ============================================================================
//
// Connects to the helper's loopback TCP IPC (127.0.0.1:<port>, see
// windows/Skybridge.WebRtcHelper/SessionTransport.cs), speaks the SAME 20-byte
// big-endian SBF1 framing (core/skybridge-core/src/frame.rs), multiplexes the
// five channels, reassembles inbound logical messages per END_OF_MESSAGE, and
// raises FrameReceived(channel, payload).
//
// WIRE PROTOCOL ON THE LOOPBACK SOCKET (both directions):
//   Each message is one raw SBF1 frame:
//     bytes  0..4   "SBF1"
//     byte   4      version = 1
//     byte   5      channel code (1..5)
//     bytes  6..8   flags u16 BE (0x0002 END_OF_MESSAGE, 0x0001 SBP2_PADDED)
//     bytes  8..16  sequence u64 BE
//     bytes 16..20  payload_len u32 BE
//     bytes 20..    payload
//   SBF1 is self-delimiting (payload_len gives the exact size), so there is NO
//   extra length prefix. Read 20 header bytes, read payload_len payload bytes,
//   that is one frame.
//
// Fail-closed: SendAsync throws if the IPC is not connected. Reconnect-tolerant:
// StartAsync (re)dials and the background pump survives transient drops by
// reconnecting with backoff until DisposeAsync / cancellation.
public sealed class SkyBridgeDataPlaneClient : ISkyBridgeDataPlane, IAsyncDisposable
{
    private const int Sbf1HeaderLen = 20;
    private const byte Sbf1Version = 1;
    private const ushort FlagSbp2Padded = 0x0001;
    private const ushort FlagEndOfMessage = 0x0002;
    private const ushort KnownFlagsMask = FlagSbp2Padded | FlagEndOfMessage;
    private const int MaxLogicalMessageBytes = 64 * 1024 * 1024;
    private const int MaxFragmentsPerLogicalMessage = 1024;
    private static readonly byte[] Sbf1Magic = { 0x53, 0x42, 0x46, 0x31 }; // "SBF1"

    private readonly string _host;
    private readonly int _port;
    private readonly bool _autoReconnect;
    private readonly TimeSpan _reconnectDelay;
    private readonly object _gate = new();

    // Per-channel monotonically increasing outbound sequence numbers.
    private readonly long[] _txSequence = new long[6];
    // Per-channel inbound reassembly buffers (payload bytes accumulated until END_OF_MESSAGE).
    private readonly Dictionary<byte, ReassemblyState> _rxAssembly = new();

    private TcpClient? _client;
    private NetworkStream? _stream;
    private CancellationTokenSource? _runCts;
    private Task? _pumpTask;
    private volatile bool _connected;
    private volatile bool _disposed;
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    public SkyBridgeDataPlaneClient(
        int port,
        string host = "127.0.0.1",
        bool autoReconnect = true,
        TimeSpan? reconnectDelay = null)
    {
        if (port is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port), port, "data-plane IPC port must be 1..65535");
        }

        _host = string.IsNullOrWhiteSpace(host) ? "127.0.0.1" : host;
        _port = port;
        _autoReconnect = autoReconnect;
        _reconnectDelay = reconnectDelay ?? TimeSpan.FromMilliseconds(500);
    }

    public bool IsConnected => _connected && !_disposed;

    public event Action<DataPlaneChannel, byte[]>? FrameReceived;

    /// <summary>
    /// Dials the helper IPC and starts the background receive pump. Throws if the
    /// initial connect fails (fail-closed). Once started, the pump reconnects
    /// across transient drops if <c>autoReconnect</c> is set.
    /// </summary>
    public async Task StartAsync(CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        lock (_gate)
        {
            if (_pumpTask is not null)
            {
                throw new InvalidOperationException("data-plane client already started");
            }

            _runCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        }

        // First connect happens inline so caller observes immediate failure.
        await ConnectOnceAsync(_runCts!.Token).ConfigureAwait(false);
        _pumpTask = Task.Run(() => PumpLoopAsync(_runCts.Token));
    }

    public async Task SendAsync(
        DataPlaneChannel channel,
        ReadOnlyMemory<byte> payload,
        CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var channelCode = RequireKnownChannel(channel);
        if (payload.Length > MaxLogicalMessageBytes)
        {
            throw new InvalidDataException(
                $"data-plane outbound payload exceeded {MaxLogicalMessageBytes} bytes");
        }

        var stream = _stream;
        if (!_connected || stream is null)
        {
            throw new InvalidOperationException(
                "data-plane IPC is not connected; refusing to send (fail-closed)");
        }

        var seq = (ulong)Interlocked.Increment(ref _txSequence[channelCode]) - 1;
        var frame = EncodeSbf1(channelCode, seq, FlagEndOfMessage, payload.Span);

        await _writeLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Re-read under the lock; a reconnect may have swapped the stream.
            var live = _stream;
            if (!_connected || live is null)
            {
                throw new InvalidOperationException(
                    "data-plane IPC dropped before send completed (fail-closed)");
            }

            await live.WriteAsync(frame, ct).ConfigureAwait(false);
            await live.FlushAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    // ---------------------------------------------------------------- internals

    private async Task ConnectOnceAsync(CancellationToken ct)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(_host, _port, ct).ConfigureAwait(false);
        }
        catch
        {
            client.Dispose();
            throw;
        }

        lock (_gate)
        {
            _client?.Dispose();
            _client = client;
            _stream = client.GetStream();
            _connected = true;
            _rxAssembly.Clear(); // a fresh socket starts message reassembly clean
        }
    }

    private async Task PumpLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var stream = _stream;
                if (stream is null)
                {
                    await ConnectOnceAsync(ct).ConfigureAwait(false);
                    stream = _stream!;
                }

                await ReceiveUntilClosedAsync(stream, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex) when (IsRecoverableTransportClosure(ex))
            {
                // Socket dropped. Mark disconnected and (maybe) retry.
            }

            _connected = false;

            if (!_autoReconnect || ct.IsCancellationRequested)
            {
                break;
            }

            try
            {
                await Task.Delay(_reconnectDelay, ct).ConfigureAwait(false);
                await ConnectOnceAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex) when (IsRecoverableTransportClosure(ex))
            {
                // Helper not back yet; loop and retry after another delay.
            }
        }

        _connected = false;
    }

    private async Task ReceiveUntilClosedAsync(NetworkStream stream, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var frame = await ReadFrameAsync(stream, ct).ConfigureAwait(false);
            if (frame is null)
            {
                return; // clean EOF; pump loop decides whether to reconnect
            }

            DispatchInbound(frame);
        }
    }

    // Accumulates payloads per channel until END_OF_MESSAGE, then raises one
    // FrameReceived with the reassembled logical message. SBP2 padding is left
    // intact (the consumer that flagged SBP2 owns unpadding) — we only reassemble.
    private void DispatchInbound(byte[] frame)
    {
        ValidateSbf1Frame(frame);
        var channelCode = frame[5];
        var flags = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(6, 2));
        var payloadLen = (int)BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(16, 4));
        var payload = new ReadOnlySpan<byte>(frame, Sbf1HeaderLen, payloadLen);
        var endOfMessage = (flags & FlagEndOfMessage) != 0;

        byte[]? message = null;

        lock (_gate)
        {
            if (!_rxAssembly.TryGetValue(channelCode, out var assembly))
            {
                // Fast path: a single self-contained frame (END_OF_MESSAGE, no
                // prior fragments) needs no buffering.
                if (endOfMessage)
                {
                    message = payload.ToArray();
                }
                else
                {
                    assembly = new ReassemblyState(payloadLen);
                    AppendFragment(assembly, payload, channelCode);
                    _rxAssembly[channelCode] = assembly;
                }
            }
            else
            {
                AppendFragment(assembly, payload, channelCode);
                if (endOfMessage)
                {
                    message = assembly.Buffer.ToArray();
                    _rxAssembly.Remove(channelCode);
                }
            }
        }

        if (message is not null)
        {
            FrameReceived?.Invoke((DataPlaneChannel)channelCode, message);
        }
    }

    private static bool IsKnownChannel(byte code) => code is >= 1 and <= 5;

    private static byte RequireKnownChannel(DataPlaneChannel channel)
    {
        var channelCode = (byte)channel;
        if (!IsKnownChannel(channelCode))
        {
            throw new InvalidDataException($"data-plane outbound channel {channel} is not a known SBF1 channel");
        }

        return channelCode;
    }

    private static bool IsRecoverableTransportClosure(Exception ex) =>
        ex is IOException or SocketException or ObjectDisposedException or EndOfStreamException;

    private static void ValidateSbf1Frame(byte[] frame)
    {
        if (frame.Length < Sbf1HeaderLen)
        {
            throw new InvalidDataException(
                $"data-plane frame length {frame.Length} is shorter than SBF1 header length {Sbf1HeaderLen}");
        }

        if (!frame.AsSpan(0, 4).SequenceEqual(Sbf1Magic))
        {
            throw new InvalidDataException("data-plane stream desync: missing SBF1 magic");
        }

        if (frame[4] != Sbf1Version)
        {
            throw new InvalidDataException($"data-plane frame used unsupported SBF1 version {frame[4]}");
        }

        if (!IsKnownChannel(frame[5]))
        {
            throw new InvalidDataException($"data-plane frame used unknown channel code {frame[5]}");
        }

        var flags = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(6, 2));
        if ((flags & ~KnownFlagsMask) != 0)
        {
            throw new InvalidDataException($"data-plane frame used unknown SBF1 flags 0x{flags:x4}");
        }

        var payloadLen = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(16, 4));
        if (payloadLen > (uint)MaxLogicalMessageBytes)
        {
            throw new InvalidDataException($"data-plane frame payload_len {payloadLen} exceeds cap");
        }

        var actualPayloadLen = frame.Length - Sbf1HeaderLen;
        if (payloadLen != actualPayloadLen)
        {
            throw new InvalidDataException(
                $"data-plane frame payload_len {payloadLen} does not match message payload bytes {actualPayloadLen}");
        }
    }

    private static void AppendFragment(ReassemblyState assembly, ReadOnlySpan<byte> payload, byte channelCode)
    {
        var nextFragmentCount = assembly.FragmentCount + 1;
        if (nextFragmentCount > MaxFragmentsPerLogicalMessage)
        {
            throw new InvalidDataException(
                $"data-plane channel {channelCode} exceeded {MaxFragmentsPerLogicalMessage} fragments without END_OF_MESSAGE");
        }

        var nextBytes = assembly.Buffer.Count + (long)payload.Length;
        if (nextBytes > MaxLogicalMessageBytes)
        {
            throw new InvalidDataException(
                $"data-plane channel {channelCode} logical message exceeded {MaxLogicalMessageBytes} bytes without END_OF_MESSAGE");
        }

        assembly.Buffer.AddRange(payload.ToArray());
        assembly.FragmentCount = nextFragmentCount;
    }

    private sealed class ReassemblyState
    {
        public ReassemblyState(int initialCapacity)
        {
            Buffer = new List<byte>(Math.Min(initialCapacity, MaxLogicalMessageBytes));
        }

        public List<byte> Buffer { get; }

        public int FragmentCount { get; set; }
    }

    private static byte[] EncodeSbf1(byte channelCode, ulong sequence, ushort flags, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[Sbf1HeaderLen + payload.Length];
        Sbf1Magic.CopyTo(buf.AsSpan(0, 4));
        buf[4] = Sbf1Version;
        buf[5] = channelCode;
        BinaryPrimitives.WriteUInt16BigEndian(buf.AsSpan(6, 2), flags);
        BinaryPrimitives.WriteUInt64BigEndian(buf.AsSpan(8, 8), sequence);
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(16, 4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(Sbf1HeaderLen));
        return buf;
    }

    // Reads exactly one SBF1 frame. Returns null on a clean EOF at a frame
    // boundary. Throws on a mid-frame EOF or a malformed/oversized header so the
    // pump treats a desynced stream as a drop (and reconnects), never as data.
    private static async Task<byte[]?> ReadFrameAsync(NetworkStream stream, CancellationToken ct)
    {
        var header = new byte[Sbf1HeaderLen];
        var got = await ReadFullyAsync(stream, header, allowCleanEof: true, ct).ConfigureAwait(false);
        if (got == 0)
        {
            return null;
        }

        var payloadLen = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(16, 4));
        if (payloadLen > (uint)MaxLogicalMessageBytes)
        {
            throw new InvalidDataException($"data-plane frame payload_len {payloadLen} exceeds cap");
        }

        var frame = new byte[Sbf1HeaderLen + (int)payloadLen];
        header.CopyTo(frame, 0);
        if (payloadLen > 0)
        {
            await ReadFullyAsync(stream, frame.AsMemory(Sbf1HeaderLen, (int)payloadLen), allowCleanEof: false, ct)
                .ConfigureAwait(false);
        }

        ValidateSbf1Frame(frame);
        return frame;
    }

    private static async Task<int> ReadFullyAsync(NetworkStream stream, Memory<byte> buffer, bool allowCleanEof, CancellationToken ct)
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
                    $"data-plane stream closed mid-frame ({total}/{buffer.Length})");
            }

            total += n;
        }

        return total;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _connected = false;

        try
        {
            _runCts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            _runCts = null;
        }

        if (_pumpTask is not null)
        {
            try
            {
                await _pumpTask.ConfigureAwait(false);
            }
            catch (Exception ex) when (IsRecoverableTransportClosure(ex) || ex is OperationCanceledException)
            {
                // pump unwinds via cancellation
            }
        }

        lock (_gate)
        {
            _stream?.Dispose();
            _client?.Dispose();
            _stream = null;
            _client = null;
        }

        _runCts?.Dispose();
        _writeLock.Dispose();
    }
}
