using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;

namespace Skybridge.WebRtcHelper;

// ============================================================================
// Data-plane VERIFY driver (--mode session-driver).
// ============================================================================
//
// A self-contained, net10.0 (Mac-buildable) exerciser of the REAL multi-channel
// data plane. It connects to two helper loopback IPC endpoints — a SENDER and a
// RECEIVER — that are bridged by a live WebRTC DataChannel (a session-offer +
// session-answer pair over file signaling). It pushes N SBF1 frames across
// multiple channels (Control + Clipboard) into the sender IPC and confirms they
// arrive, IN ORDER and correctly REASSEMBLED, on the receiver IPC. That proves
// frames crossed the actual DataChannel, not a loopback shortcut.
//
//   driver --send--> [helper A IPC] --DataChannel--> [helper B IPC] --recv--> driver
//
// It also sends one MULTI-FRAGMENT logical message (two frames, only the second
// flagged END_OF_MESSAGE) to prove the receiver reassembles per END_OF_MESSAGE.
//
// Usage:
//   --mode session-driver --send-port <A> --recv-port <B>
//       [--count <N>=8] [--timeout-seconds <T>=30]
internal static class SessionDriver
{
    private const int Sbf1HeaderLen = 20;
    private const byte Sbf1Version = 1;
    private const ushort FlagEndOfMessage = 0x0002;
    private static readonly byte[] Sbf1Magic = { 0x53, 0x42, 0x46, 0x31 };

    private const byte ChannelControl = 1;
    private const byte ChannelClipboard = 3;

    public static async Task<int> RunAsync(Dictionary<string, string> opts)
    {
        if (!int.TryParse(opts.GetValueOrDefault("send-port", ""), out var sendPort) || sendPort is < 1 or > 65535)
        {
            Console.Error.WriteLine("session-driver requires --send-port <1..65535>");
            return 2;
        }

        if (!int.TryParse(opts.GetValueOrDefault("recv-port", ""), out var recvPort) || recvPort is < 1 or > 65535)
        {
            Console.Error.WriteLine("session-driver requires --recv-port <1..65535>");
            return 2;
        }

        var count = int.TryParse(opts.GetValueOrDefault("count", "8"), out var c) && c > 0 ? c : 8;
        var timeout = TimeSpan.FromSeconds(
            int.TryParse(opts.GetValueOrDefault("timeout-seconds", "30"), out var t) && t > 0 ? t : 30);

        Console.WriteLine($"[driver] send-port={sendPort} recv-port={recvPort} count={count}");

        // The helpers only bind their IPC listeners AFTER the DataChannel opens,
        // so retry-connect to ride out the signaling/ICE/DTLS warm-up.
        var sender = await ConnectWithRetryAsync(sendPort, timeout).ConfigureAwait(false);
        var receiver = await ConnectWithRetryAsync(recvPort, timeout).ConfigureAwait(false);
        using var _s = sender;
        using var _r = receiver;
        using var sendStream = sender.GetStream();
        using var recvStream = receiver.GetStream();
        Console.WriteLine("[driver] connected to both helper IPC endpoints");

        // The exact ordered sequence of (channel, payload) logical messages we
        // expect to come out the receiver, in order.
        var expected = new List<(byte channel, byte[] payload)>();

        // Build + send N single-frame messages, alternating Control / Clipboard.
        ulong ctrlSeq = 0, clipSeq = 0;
        for (var i = 0; i < count; i++)
        {
            var onControl = i % 2 == 0;
            var channel = onControl ? ChannelControl : ChannelClipboard;
            var payload = Encoding.UTF8.GetBytes(
                onControl ? $"ctrl-msg-{i}" : $"clipboard-content-{i}-你好"); // includes non-ASCII
            var seq = onControl ? ctrlSeq++ : clipSeq++;
            var frame = Encode(channel, seq, FlagEndOfMessage, payload);
            await sendStream.WriteAsync(frame).ConfigureAwait(false);
            await sendStream.FlushAsync().ConfigureAwait(false);
            expected.Add((channel, payload));
        }

        // One MULTI-FRAGMENT logical message on Clipboard: two frames, only the
        // second carries END_OF_MESSAGE. The receiver must reassemble into ONE
        // message (partA+partB).
        var partA = Encoding.UTF8.GetBytes("REASSEMBLE-PART-A|");
        var partB = Encoding.UTF8.GetBytes("PART-B-END");
        await sendStream.WriteAsync(Encode(ChannelClipboard, clipSeq++, 0x0000, partA)).ConfigureAwait(false);
        await sendStream.WriteAsync(Encode(ChannelClipboard, clipSeq++, FlagEndOfMessage, partB)).ConfigureAwait(false);
        await sendStream.FlushAsync().ConfigureAwait(false);
        var reassembled = new byte[partA.Length + partB.Length];
        partA.CopyTo(reassembled, 0);
        partB.CopyTo(reassembled, partA.Length);
        expected.Add((ChannelClipboard, reassembled));

        Console.WriteLine($"[driver] sent {count} single-frame + 1 two-fragment message; awaiting {expected.Count} reassembled on receiver...");

        // Receive + reassemble per END_OF_MESSAGE on the receiver IPC, then check
        // order + content against `expected`.
        using var cts = new CancellationTokenSource(timeout);
        var assembly = new Dictionary<byte, List<byte>>();
        var got = new List<(byte channel, byte[] payload)>();

        try
        {
            while (got.Count < expected.Count)
            {
                var frame = await SessionTransport.ReadFrameAsync(recvStream, cts.Token).ConfigureAwait(false);
                if (frame is null)
                {
                    Console.Error.WriteLine("[driver] receiver IPC closed before all messages arrived");
                    return 1;
                }

                var channel = frame[5];
                var flags = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(6, 2));
                var payloadLen = (int)BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(16, 4));
                var payload = frame.AsSpan(Sbf1HeaderLen, payloadLen).ToArray();

                if (!assembly.TryGetValue(channel, out var buf))
                {
                    buf = new List<byte>();
                    assembly[channel] = buf;
                }

                buf.AddRange(payload);
                if ((flags & FlagEndOfMessage) != 0)
                {
                    got.Add((channel, buf.ToArray()));
                    assembly.Remove(channel);
                }
            }
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine($"[driver] TIMEOUT: received {got.Count}/{expected.Count} messages within {timeout.TotalSeconds:F0}s");
            return 1;
        }

        // Verify per-channel order + content. Frames on DIFFERENT channels may
        // interleave on the wire, but within a channel the order is preserved by
        // SCTP, so compare per-channel sequences.
        var ok = VerifyPerChannel(expected, got);
        if (!ok)
        {
            return 1;
        }

        Console.WriteLine($"[driver] OK: all {expected.Count} messages arrived in-order, reassembled, byte-exact across {DistinctChannels(expected)} channels via the real DataChannel");
        return 0;
    }

    private static bool VerifyPerChannel(
        List<(byte channel, byte[] payload)> expected,
        List<(byte channel, byte[] payload)> got)
    {
        foreach (var ch in new[] { ChannelControl, ChannelClipboard })
        {
            var exp = expected.Where(e => e.channel == ch).Select(e => e.payload).ToList();
            var act = got.Where(g => g.channel == ch).Select(g => g.payload).ToList();
            if (exp.Count != act.Count)
            {
                Console.Error.WriteLine($"[driver] FAIL channel {ch}: expected {exp.Count} messages, got {act.Count}");
                return false;
            }

            for (var i = 0; i < exp.Count; i++)
            {
                if (!exp[i].AsSpan().SequenceEqual(act[i]))
                {
                    Console.Error.WriteLine(
                        $"[driver] FAIL channel {ch} msg #{i}: expected '{Encoding.UTF8.GetString(exp[i])}' got '{Encoding.UTF8.GetString(act[i])}'");
                    return false;
                }
            }

            Console.WriteLine($"[driver] channel {ch}: {act.Count} messages matched in order");
        }

        return true;
    }

    private static int DistinctChannels(List<(byte channel, byte[] payload)> msgs) =>
        msgs.Select(m => m.channel).Distinct().Count();

    private static async Task<TcpClient> ConnectWithRetryAsync(int port, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        Exception? last = null;
        while (DateTime.UtcNow < deadline)
        {
            var client = new TcpClient { NoDelay = true };
            try
            {
                await client.ConnectAsync("127.0.0.1", port).ConfigureAwait(false);
                return client;
            }
            catch (SocketException ex)
            {
                last = ex;
                client.Dispose();
                await Task.Delay(250).ConfigureAwait(false);
            }
        }

        throw new TimeoutException(
            $"could not connect to helper IPC 127.0.0.1:{port} within {timeout.TotalSeconds:F0}s: {last?.Message}");
    }

    private static byte[] Encode(byte channelCode, ulong sequence, ushort flags, byte[] payload)
    {
        var buf = new byte[Sbf1HeaderLen + payload.Length];
        Sbf1Magic.CopyTo(buf, 0);
        buf[4] = Sbf1Version;
        buf[5] = channelCode;
        BinaryPrimitives.WriteUInt16BigEndian(buf.AsSpan(6, 2), flags);
        BinaryPrimitives.WriteUInt64BigEndian(buf.AsSpan(8, 8), sequence);
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(16, 4), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(Sbf1HeaderLen));
        return buf;
    }
}
