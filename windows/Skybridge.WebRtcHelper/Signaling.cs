using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
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
    private const long MaxSignalDocumentBytes = 1_048_576;
    private const int MaxIceCandidates = 256;
    private const int MaxIceCandidateCharacters = 4096;
    private const int MaxSdpMidCharacters = 64;
    private const int MaxUsernameFragmentCharacters = 256;

    [JsonPropertyName("type")] public string Type { get; init; } = "";
    [JsonPropertyName("sdp")] public string Sdp { get; init; } = "";
    [JsonPropertyName("candidates")] public List<Cand> Candidates { get; init; } = new();

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static void Write(string path, string type, string sdp, List<Cand> candidates)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var sig = new Signal { Type = type, Sdp = sdp, Candidates = ValidateCandidates(candidates) };
        var json = JsonSerializer.Serialize(sig, Options);
        if (Encoding.UTF8.GetByteCount(json) > MaxSignalDocumentBytes)
        {
            throw new InvalidDataException(
                $"signal file exceeds the maximum size of {MaxSignalDocumentBytes} bytes: {path}");
        }

        WriteTextAtomically(path, json);
    }

    private static void WriteTextAtomically(string path, string contents)
    {
        var fullPath = Path.GetFullPath(path);
        var parent = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrWhiteSpace(parent))
        {
            AssertNoWindowsReparsePointAncestors(parent, "signal output directory");
            Directory.CreateDirectory(parent);
            AssertNoWindowsReparsePointAncestors(parent, "signal output directory");
        }

        AssertNoWindowsReparsePoint(fullPath, "signal output file");

        var tmp = fullPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                using (var writer = new StreamWriter(stream, new UTF8Encoding(false), bufferSize: 4096, leaveOpen: true))
                {
                    writer.Write(contents);
                }

                stream.Flush(flushToDisk: true);
            }

            MoveReplacingWithRetry(tmp, fullPath);
        }
        catch (Exception writeError)
        {
            DeleteTempAfterFailure(tmp, writeError);
            ExceptionDispatchInfo.Capture(writeError).Throw();
            throw;
        }
    }

    public static Signal Read(string path, string expectedType)
    {
        if (!File.Exists(path))
        {
            throw new InvalidOperationException($"signal file does not exist: {path}");
        }

        var sig = JsonSerializer.Deserialize<Signal>(ReadTextWithSizeLimit(path));
        if (sig is null || string.IsNullOrWhiteSpace(sig.Sdp))
        {
            throw new InvalidDataException($"signal file is empty or invalid JSON: {path}");
        }

        if (!string.Equals(sig.Type, expectedType, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"signal file type mismatch for {path}; expected {expectedType}.");
        }

        return new Signal
        {
            Type = sig.Type,
            Sdp = sig.Sdp,
            Candidates = ValidateCandidates(sig.Candidates)
        };
    }

    // Polls for the signal file to appear and parse cleanly (atomic writers use
    // temp+rename, so a successful parse means the file is complete).
    public static async Task<Signal> WaitReadAsync(string path, string expectedType, TimeSpan timeout)
    {
        if (string.IsNullOrWhiteSpace(expectedType))
        {
            throw new ArgumentException("Expected signal type must not be empty.", nameof(expectedType));
        }

        var deadline = DateTime.UtcNow + timeout;
        Exception? lastTransientReadError = null;
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    var sig = JsonSerializer.Deserialize<Signal>(ReadTextWithSizeLimit(path));
                    if (sig is not null && !string.IsNullOrWhiteSpace(sig.Sdp))
                    {
                        if (!string.Equals(sig.Type, expectedType, StringComparison.Ordinal))
                        {
                            throw new InvalidDataException(
                                $"signal file type mismatch for {path}; expected {expectedType}.");
                        }

                        return new Signal
                        {
                            Type = sig.Type,
                            Sdp = sig.Sdp,
                            Candidates = ValidateCandidates(sig.Candidates)
                        };
                    }
                }
                catch (Exception ex) when (ex is JsonException or IOException)
                {
                    lastTransientReadError = ex;
                }
            }
            await Task.Delay(250);
        }

        var message = $"signal file {expectedType} not available within {timeout.TotalSeconds:F0}s: {path}";
        throw lastTransientReadError is null
            ? new TimeoutException(message)
            : new TimeoutException(
                $"{message}; last transient read error was {lastTransientReadError.GetType().Name}: {lastTransientReadError.Message}",
                lastTransientReadError);
    }

    private static List<Cand> ValidateCandidates(IEnumerable<Cand> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var validated = new List<Cand>();
        foreach (var candidate in candidates)
        {
            if (validated.Count >= MaxIceCandidates)
            {
                throw new InvalidDataException($"signal file contains more than {MaxIceCandidates} ICE candidates.");
            }

            if (string.IsNullOrWhiteSpace(candidate.Candidate))
            {
                throw new InvalidDataException("signal ICE candidate must not be empty.");
            }

            ValidateSingleLine(candidate.Candidate, MaxIceCandidateCharacters, "ICE candidate");
            if (!IsParseableCandidate(candidate.Candidate))
            {
                throw new InvalidDataException("signal ICE candidate is not parseable.");
            }

            if (candidate.SdpMid is not null)
            {
                if (candidate.SdpMid.Length == 0)
                {
                    throw new InvalidDataException("signal ICE candidate sdpMid must not be empty when present.");
                }

                ValidateSingleLine(candidate.SdpMid, MaxSdpMidCharacters, "ICE candidate sdpMid");
            }

            if (candidate.UsernameFragment is not null)
            {
                if (candidate.UsernameFragment.Length == 0)
                {
                    throw new InvalidDataException(
                        "signal ICE candidate usernameFragment must not be empty when present.");
                }

                ValidateSingleLine(
                    candidate.UsernameFragment,
                    MaxUsernameFragmentCharacters,
                    "ICE candidate usernameFragment");
            }

            validated.Add(candidate);
        }

        return validated;
    }

    private static void ValidateSingleLine(string value, int maxCharacters, string label)
    {
        if (value.Length > maxCharacters)
        {
            throw new InvalidDataException($"signal {label} exceeds {maxCharacters} characters.");
        }

        foreach (var current in value)
        {
            if (char.IsControl(current))
            {
                throw new InvalidDataException($"signal {label} must not contain control characters.");
            }
        }
    }

    private static bool IsParseableCandidate(string candidate) =>
        Regex.IsMatch(candidate, @"^(?:candidate:)?\S+ \d+ \S+ \d+ \S+ \d+ typ \S+");

    private static string ReadTextWithSizeLimit(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length > MaxSignalDocumentBytes)
        {
            throw new InvalidDataException(
                $"signal file exceeds the maximum size of {MaxSignalDocumentBytes} bytes: {path}");
        }

        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    private static void MoveReplacingWithRetry(string sourcePath, string destinationPath)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
        while (true)
        {
            AssertNoWindowsReparsePoint(destinationPath, "signal output file");
            try
            {
                File.Move(sourcePath, destinationPath, overwrite: true);
                return;
            }
            catch (IOException) when (DateTimeOffset.UtcNow < deadline)
            {
                Thread.Sleep(TimeSpan.FromMilliseconds(50));
            }
        }
    }

    private static void AssertNoWindowsReparsePointAncestors(string path, string label)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var current = Path.GetFullPath(path);
        while (!string.IsNullOrWhiteSpace(current))
        {
            if (Directory.Exists(current) || File.Exists(current))
            {
                AssertNoWindowsReparsePoint(current, label);
            }

            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrWhiteSpace(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            current = parent;
        }
    }

    private static void AssertNoWindowsReparsePoint(string path, string label)
    {
        if (!OperatingSystem.IsWindows() || (!Directory.Exists(path) && !File.Exists(path)))
        {
            return;
        }

        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException($"{label} must not be a reparse point: {path}");
        }
    }

    private static void DeleteTempAfterFailure(string tempPath, Exception writeError)
    {
        try
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }
        }
        catch (Exception cleanupError) when (cleanupError is IOException or UnauthorizedAccessException)
        {
            throw new IOException(
                $"signal write failed and temporary signal cleanup also failed: {tempPath}",
                new AggregateException(writeError, cleanupError));
        }
    }
}
