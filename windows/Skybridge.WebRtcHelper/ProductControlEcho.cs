using System.Net.Sockets;
using System.Security.Cryptography;

namespace Skybridge.WebRtcHelper;

// Test-only app-side echo peer for the raw product-control helper IPC. This
// exercises the Mac-product control transport shell without interpreting the
// handshake or SBWC payload bytes.
internal static class ProductControlEcho
{
    public static async Task<int> RunAsync(Dictionary<string, string> opts)
    {
        if (!int.TryParse(opts.GetValueOrDefault("port", ""), out var port) || port is < 1 or > 65535)
        {
            Console.Error.WriteLine("product-control-echo requires --port <1..65535>");
            return 2;
        }

        var count = int.TryParse(opts.GetValueOrDefault("count", "1"), out var c) && c > 0 ? c : 1;
        var timeout = TimeSpan.FromSeconds(
            int.TryParse(opts.GetValueOrDefault("timeout-seconds", "30"), out var t) && t > 0 ? t : 30);
        var ipcAuthToken = ReadIpcAuthToken(opts);

        try
        {
            Console.WriteLine($"[product-control-echo] port={port} count={count}");
            using var client = await ConnectWithRetryAsync(port, timeout).ConfigureAwait(false);
            client.NoDelay = true;
            using var stream = client.GetStream();
            using var cts = new CancellationTokenSource(timeout);
            if (ipcAuthToken is not null)
            {
                await ProductControlTransport.AuthenticateIpcServerAsync(stream, ipcAuthToken, cts.Token).ConfigureAwait(false);
                Console.WriteLine("[product-control-echo] authenticated to product-control IPC endpoint");
            }

            var echoed = 0;
            while (echoed < count)
            {
                var message = await ProductControlTransport.ReadMessageAsync(stream, cts.Token).ConfigureAwait(false);
                if (message is null)
                {
                    Console.Error.WriteLine($"[product-control-echo] IPC closed after {echoed}/{count} message(s)");
                    return 1;
                }

                await ProductControlTransport.WriteMessageAsync(stream, message, cts.Token).ConfigureAwait(false);
                echoed += 1;
                Console.WriteLine($"[product-control-echo] message {echoed}/{count}: bytes={message.Length}");
            }

            Console.WriteLine($"[product-control-echo] OK: echoed {echoed} product-control message(s)");
            return 0;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine($"[product-control-echo] TIMEOUT within {timeout.TotalSeconds:F0}s");
            return 1;
        }
        finally
        {
            if (ipcAuthToken is not null)
            {
                CryptographicOperations.ZeroMemory(ipcAuthToken);
            }
        }
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
                "product-control echo IPC authentication token");
        }
        finally
        {
            Environment.SetEnvironmentVariable(envName, null);
        }
    }
}
