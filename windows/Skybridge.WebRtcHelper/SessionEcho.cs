using System.Net.Sockets;

namespace Skybridge.WebRtcHelper;

// App-side echo verifier for a live session helper IPC. This is deliberately not
// part of the production data path: it is a test peer that sits behind a helper
// loopback port and echoes exact SBF1 frames back so a product-side client can
// prove send+receive through the real DataChannel.
internal static class SessionEcho
{
    public static async Task<int> RunAsync(Dictionary<string, string> opts)
    {
        if (!int.TryParse(opts.GetValueOrDefault("port", ""), out var port) || port is < 1 or > 65535)
        {
            Console.Error.WriteLine("session-echo requires --port <1..65535>");
            return 2;
        }

        var count = int.TryParse(opts.GetValueOrDefault("count", "1"), out var c) && c > 0 ? c : 1;
        var timeout = TimeSpan.FromSeconds(
            int.TryParse(opts.GetValueOrDefault("timeout-seconds", "30"), out var t) && t > 0 ? t : 30);

        Console.WriteLine($"[echo] port={port} count={count}");
        using var client = await ConnectWithRetryAsync(port, timeout).ConfigureAwait(false);
        client.NoDelay = true;
        using var stream = client.GetStream();
        using var cts = new CancellationTokenSource(timeout);

        var echoed = 0;
        try
        {
            while (echoed < count)
            {
                var frame = await SessionTransport.ReadFrameAsync(stream, cts.Token).ConfigureAwait(false);
                if (frame is null)
                {
                    Console.Error.WriteLine($"[echo] IPC closed after {echoed}/{count} frames");
                    return 1;
                }

                await stream.WriteAsync(frame, cts.Token).ConfigureAwait(false);
                await stream.FlushAsync(cts.Token).ConfigureAwait(false);
                echoed += 1;
                Console.WriteLine(
                    $"[echo] frame {echoed}/{count}: channel={SessionTransport.ChannelOf(frame)} flags=0x{SessionTransport.FlagsOf(frame):x4} bytes={frame.Length}");
            }
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine($"[echo] TIMEOUT: echoed {echoed}/{count} frames within {timeout.TotalSeconds:F0}s");
            return 1;
        }

        Console.WriteLine($"[echo] OK: echoed {echoed} SBF1 frame(s)");
        return 0;
    }

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
}
