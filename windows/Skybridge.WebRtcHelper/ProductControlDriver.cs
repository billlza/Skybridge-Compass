using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WebRtcHelper;

// Test driver for the raw product-control IPC profile:
//
//   driver --send--> [helper A IPC] --DataChannel--> [helper B IPC] --recv--> driver
//
// It sends byte-exact Mac-product-control-like chunks, including one full
// 8192-byte boundary chunk, and verifies they arrive in order without SBF1.
internal static class ProductControlDriver
{
    public static async Task<int> RunAsync(Dictionary<string, string> opts)
    {
        if (!int.TryParse(opts.GetValueOrDefault("send-port", ""), out var sendPort) || sendPort is < 1 or > 65535)
        {
            Console.Error.WriteLine("product-control-driver requires --send-port <1..65535>");
            return 2;
        }

        if (!int.TryParse(opts.GetValueOrDefault("recv-port", ""), out var recvPort) || recvPort is < 1 or > 65535)
        {
            Console.Error.WriteLine("product-control-driver requires --recv-port <1..65535>");
            return 2;
        }

        var timeout = TimeSpan.FromSeconds(
            int.TryParse(opts.GetValueOrDefault("timeout-seconds", "30"), out var t) && t > 0 ? t : 30);
        var ipcAuthToken = ReadIpcAuthToken(opts);

        try
        {
            Console.WriteLine($"[product-control-driver] send-port={sendPort} recv-port={recvPort}");
            using var sender = await ConnectWithRetryAsync(sendPort, timeout).ConfigureAwait(false);
            using var receiver = await ConnectWithRetryAsync(recvPort, timeout).ConfigureAwait(false);
            using var sendStream = sender.GetStream();
            using var recvStream = receiver.GetStream();
            using var cts = new CancellationTokenSource(timeout);
            if (ipcAuthToken is not null)
            {
                await ProductControlTransport.AuthenticateIpcServerAsync(sendStream, ipcAuthToken, cts.Token).ConfigureAwait(false);
                await ProductControlTransport.AuthenticateIpcServerAsync(recvStream, ipcAuthToken, cts.Token).ConfigureAwait(false);
                Console.WriteLine("[product-control-driver] authenticated to both product-control IPC endpoints");
            }

            Console.WriteLine("[product-control-driver] connected to both product-control IPC endpoints");

            var expected = BuildMessages();
            foreach (var message in expected)
            {
                await ProductControlTransport.WriteMessageAsync(sendStream, message, cts.Token).ConfigureAwait(false);
            }

            for (var index = 0; index < expected.Count; index++)
            {
                var received = await ProductControlTransport.ReadMessageAsync(recvStream, cts.Token).ConfigureAwait(false);
                if (received is null)
                {
                    Console.Error.WriteLine($"[product-control-driver] receiver IPC closed before message {index + 1}/{expected.Count}");
                    return 1;
                }

                if (!received.AsSpan().SequenceEqual(expected[index]))
                {
                    Console.Error.WriteLine(
                        $"[product-control-driver] FAIL message {index + 1}: expected sha256={Sha256Hex(expected[index])} got sha256={Sha256Hex(received)}");
                    return 1;
                }

                Console.WriteLine($"[product-control-driver] message {index + 1}/{expected.Count}: bytes={received.Length} matched");
            }

            Console.WriteLine($"[product-control-driver] OK: {expected.Count} raw product-control message(s) crossed the real DataChannel byte-exact");
            return 0;
        }
        finally
        {
            if (ipcAuthToken is not null)
            {
                CryptographicOperations.ZeroMemory(ipcAuthToken);
            }
        }
    }

    private static List<byte[]> BuildMessages()
    {
        var sbwcLike = new byte[68];
        Encoding.ASCII.GetBytes("SBWC").CopyTo(sbwcLike, 0);
        sbwcLike[4] = 1;
        sbwcLike[5] = 52;
        sbwcLike[6] = 1;
        sbwcLike[7] = 1;
        RandomNumberGenerator.Fill(sbwcLike.AsSpan(8));

        var boundary = new byte[ProductControlTransport.MaxControlFrameChunkBytes];
        RandomNumberGenerator.Fill(boundary);
        boundary[0] = 1; // handshake-like protocol version byte; content is opaque to the helper.

        return new List<byte[]>
        {
            new byte[] { 1, 0, 0, 0, 0 },
            sbwcLike,
            boundary
        };
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
            $"could not connect to product-control IPC 127.0.0.1:{port} within {timeout.TotalSeconds:F0}s: {last?.Message}");
    }

    private static string Sha256Hex(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static byte[]? ReadIpcAuthToken(Dictionary<string, string> opts)
    {
        var envName = opts.GetValueOrDefault("ipc-auth-token-env", "");
        if (string.IsNullOrWhiteSpace(envName))
        {
            return null;
        }

        envName = envName.Trim();
        if (envName.Any(ch => !(char.IsLetterOrDigit(ch) || ch == '_')))
        {
            throw new ArgumentException("--ipc-auth-token-env must name an environment variable using letters, digits, or underscores.");
        }

        var encoded = Environment.GetEnvironmentVariable(envName);
        if (string.IsNullOrWhiteSpace(encoded))
        {
            throw new ArgumentException("Environment variable named by --ipc-auth-token-env is missing or empty.");
        }

        try
        {
            return ProductControlTransport.DecodeIpcAuthTokenFromBase64(
                encoded.Trim(),
                "product-control driver IPC authentication token");
        }
        finally
        {
            Environment.SetEnvironmentVariable(envName, null);
        }
    }
}
