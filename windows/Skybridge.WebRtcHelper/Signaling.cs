using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SIPSorcery.Net;

namespace Skybridge.WebRtcHelper;

// A serializable ICE candidate line (offer/answer file-signaling carrier).
internal sealed class Cand
{
    [JsonPropertyName("candidate")] public string Candidate { get; init; } = "";
    [JsonPropertyName("sdpMid")] public string? SdpMid { get; init; }
    [JsonPropertyName("sdpMLineIndex")] public ushort SdpMLineIndex { get; init; }
    [JsonPropertyName("usernameFragment")] public string? UsernameFragment { get; init; }

    public static Cand From(RTCIceCandidate c) => new()
    {
        Candidate = c.candidate,
        SdpMid = c.sdpMid,
        SdpMLineIndex = c.sdpMLineIndex,
        UsernameFragment = c.usernameFragment,
    };

    public RTCIceCandidateInit ToInit() => new()
    {
        candidate = Candidate,
        sdpMid = SdpMid,
        sdpMLineIndex = SdpMLineIndex,
        usernameFragment = UsernameFragment,
    };
}

// The SDP + gathered candidates exchanged via a JSON file. This is the dev
// signaling carrier the proof schema explicitly allows (file/QR/manual). The
// existing CrossNetworkConnectionClient QR/SmartCode payload can carry the same
// fields for a production signaling plane.
internal sealed class Signal
{
    [JsonPropertyName("type")] public string Type { get; init; } = "";
    [JsonPropertyName("sdp")] public string Sdp { get; init; } = "";
    [JsonPropertyName("candidates")] public List<Cand> Candidates { get; init; } = new();

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static void Write(string path, string type, string sdp, List<Cand> candidates)
    {
        var sig = new Signal { Type = type, Sdp = sdp, Candidates = candidates };
        var json = JsonSerializer.Serialize(sig, Options);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        File.Move(tmp, path, overwrite: true);
    }

    // Polls for the signal file to appear and parse cleanly (atomic writers use
    // temp+rename, so a successful parse means the file is complete).
    public static async Task<Signal> WaitReadAsync(string path, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    var sig = JsonSerializer.Deserialize<Signal>(File.ReadAllText(path));
                    if (sig is not null && !string.IsNullOrWhiteSpace(sig.Sdp)) return sig;
                }
                catch (JsonException) { /* writer mid-flight; retry */ }
            }
            await Task.Delay(250);
        }
        throw new TimeoutException($"signal file not available within {timeout.TotalSeconds:F0}s: {path}");
    }
}
