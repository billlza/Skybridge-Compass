using System.Text.Json;
using Skybridge.WinClient.Services;

var client = new TopBarNetworkStatusClient();
var before = client.SampleInterfaceCounters();
using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
var latency = client.MeasureLatencyMillisecondsAsync(timeout.Token);
var location = client.ResolveLocationAsync(timeout.Token);
await Task.WhenAll(latency, location);
await Task.Delay(2000, timeout.Token);
var after = client.SampleInterfaceCounters();
var seconds = (after.SampledAt - before.SampledAt).TotalSeconds;
if (seconds <= 0 || after.BytesReceived < before.BytesReceived || after.BytesSent < before.BytesSent)
    throw new InvalidOperationException("Counter samples do not form a valid interval.");
Console.WriteLine(JsonSerializer.Serialize(new
{
    latencyMilliseconds = latency.Result,
    latencySource = TopBarNetworkStatusClient.LatencyEndpoint,
    locationSource = TopBarNetworkStatusClient.LocationEndpoint,
    publicIp = location.Result.PublicIpAddress,
    city = location.Result.City,
    proxy = location.Result.IsSystemProxyEnabled,
    downloadBytesPerSecond = (after.BytesReceived - before.BytesReceived) / seconds,
    uploadBytesPerSecond = (after.BytesSent - before.BytesSent) / seconds
}));
