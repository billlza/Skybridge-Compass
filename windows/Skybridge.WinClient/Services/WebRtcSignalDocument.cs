using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Strict reader for the helper's local SDP signaling files. This is shared by
/// the SBF1 session profile and the Mac product-control profile so both derive
/// endpoint and DTLS binding facts from the same parser.
/// </summary>
internal sealed class WebRtcSignalDocument
{
    private const long MaxSignalDocumentBytes = 1_048_576;
    private const int MaxIceCandidates = 256;
    private const int MaxIceCandidateCharacters = 4096;
    private const int MaxSdpMidCharacters = 64;
    private const int MaxUsernameFragmentCharacters = 256;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    [JsonPropertyName("type")]
    public string Type { get; init; } = string.Empty;

    [JsonPropertyName("sdp")]
    public string Sdp { get; init; } = string.Empty;

    [JsonPropertyName("candidates")]
    public SignalCandidate[] Candidates { get; init; } = Array.Empty<SignalCandidate>();

    [JsonIgnore]
    public string SourcePath { get; private set; } = string.Empty;

    public static WebRtcSignalDocument Read(string path, string expectedType)
    {
        if (!File.Exists(path))
        {
            throw new InvalidOperationException($"WebRTC signaling file does not exist: {path}");
        }

        var document = JsonSerializer.Deserialize<WebRtcSignalDocument>(ReadTextWithSizeLimit(path), JsonOptions);
        if (document is null || string.IsNullOrWhiteSpace(document.Sdp))
        {
            throw new InvalidOperationException($"WebRTC signaling file is empty or invalid JSON: {path}");
        }

        document.SourcePath = path;
        if (!string.Equals(document.Type, expectedType, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"WebRTC signaling file type mismatch for {path}; expected {expectedType}.");
        }

        _ = ValidateCandidates(document.Candidates);
        return document;
    }

    public static void Write(
        string path,
        string type,
        string sdp,
        IEnumerable<SignalCandidate> candidates)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!IsOfferOrAnswer(type))
        {
            throw new InvalidDataException("WebRTC signaling file type must be offer or answer.");
        }

        if (string.IsNullOrWhiteSpace(sdp))
        {
            throw new InvalidDataException("WebRTC signaling file must include SDP.");
        }

        var candidateArray = ValidateCandidates(candidates);
        var document = new WebRtcSignalDocument
        {
            Type = type,
            Sdp = sdp,
            Candidates = candidateArray
        };
        var json = JsonSerializer.Serialize(document, JsonOptions);
        if (Encoding.UTF8.GetByteCount(json) > MaxSignalDocumentBytes)
        {
            throw new InvalidDataException(
                $"WebRTC signaling file exceeds the maximum size of {MaxSignalDocumentBytes} bytes: {path}");
        }

        var tmp = path + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        File.Move(tmp, path, overwrite: true);
    }

    private static bool IsOfferOrAnswer(string type) =>
        string.Equals(type, "offer", StringComparison.Ordinal) ||
        string.Equals(type, "answer", StringComparison.Ordinal);

    private static SignalCandidate[] ValidateCandidates(IEnumerable<SignalCandidate> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var validated = new List<SignalCandidate>();
        foreach (var candidate in candidates)
        {
            if (validated.Count >= MaxIceCandidates)
            {
                throw new InvalidDataException(
                    $"WebRTC signaling file contains more than {MaxIceCandidates} ICE candidates.");
            }

            if (string.IsNullOrWhiteSpace(candidate.Candidate))
            {
                throw new InvalidDataException("WebRTC signaling ICE candidate must not be empty.");
            }

            ValidateSingleLine(candidate.Candidate, MaxIceCandidateCharacters, "ICE candidate");
            if (ParseCandidate(candidate.Candidate) is null)
            {
                throw new InvalidDataException("WebRTC signaling ICE candidate is not parseable.");
            }

            if (candidate.SdpMid is not null)
            {
                if (candidate.SdpMid.Length == 0)
                {
                    throw new InvalidDataException("WebRTC signaling ICE candidate sdpMid must not be empty when present.");
                }

                ValidateSingleLine(candidate.SdpMid, MaxSdpMidCharacters, "ICE candidate sdpMid");
            }

            if (candidate.UsernameFragment is not null)
            {
                if (candidate.UsernameFragment.Length == 0)
                {
                    throw new InvalidDataException(
                        "WebRTC signaling ICE candidate usernameFragment must not be empty when present.");
                }

                ValidateSingleLine(
                    candidate.UsernameFragment,
                    MaxUsernameFragmentCharacters,
                    "ICE candidate usernameFragment");
            }

            validated.Add(candidate);
        }

        return validated.ToArray();
    }

    private static void ValidateSingleLine(string value, int maxCharacters, string label)
    {
        if (value.Length > maxCharacters)
        {
            throw new InvalidDataException($"WebRTC signaling {label} exceeds {maxCharacters} characters.");
        }

        foreach (var current in value)
        {
            if (char.IsControl(current))
            {
                throw new InvalidDataException($"WebRTC signaling {label} must not contain control characters.");
            }
        }
    }

    private static string ReadTextWithSizeLimit(string path)
    {
        var fileInfo = new FileInfo(path);
        if (fileInfo.Length > MaxSignalDocumentBytes)
        {
            throw new InvalidDataException(
                $"WebRTC signaling file exceeds the maximum size of {MaxSignalDocumentBytes} bytes: {path}");
        }

        return File.ReadAllText(path);
    }

    public string Fingerprint()
    {
        return RequireFingerprint(Sdp, SourcePath);
    }

    public static string RequireFingerprint(string sdp, string sourcePath)
    {
        var match = Regex.Match(sdp, @"a=fingerprint:\S+\s+([0-9A-Fa-f:]+)");
        if (!match.Success)
        {
            throw new InvalidOperationException(
                $"WebRTC signaling file does not contain a DTLS fingerprint: {sourcePath}");
        }

        return match.Groups[1].Value;
    }

    public string FirstEndpoint()
    {
        var (_, endpoint) = FirstCandidate();
        return endpoint;
    }

    public string FirstCandidateLabel()
    {
        var (kind, endpoint) = FirstCandidate();
        return $"{kind}-{endpoint}";
    }

    public static bool ContainsParseableCandidate(string sdp)
    {
        if (string.IsNullOrWhiteSpace(sdp))
        {
            return false;
        }

        foreach (Match match in Regex.Matches(sdp, @"a=(candidate:\S+ \d+ \S+ \d+ \S+ \d+ typ \S+)[^\r\n]*"))
        {
            if (ParseCandidate(match.Groups[1].Value) is not null)
            {
                return true;
            }
        }

        return false;
    }

    private (string Kind, string Endpoint) FirstCandidate()
    {
        foreach (var candidate in Candidates)
        {
            var parsed = ParseCandidate(candidate.Candidate);
            if (parsed is not null)
            {
                return parsed.Value;
            }
        }

        foreach (Match match in Regex.Matches(Sdp, @"a=(candidate:\S+ \d+ \S+ \d+ \S+ \d+ typ \S+)[^\r\n]*"))
        {
            var parsed = ParseCandidate(match.Groups[1].Value);
            if (parsed is not null)
            {
                return parsed.Value;
            }
        }

        throw new InvalidOperationException(
            $"WebRTC signaling file does not contain a parseable ICE candidate: {SourcePath}");
    }

    private static (string Kind, string Endpoint)? ParseCandidate(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var match = Regex.Match(raw, @"^(?:candidate:)?\S+ \d+ \S+ \d+ (\S+) (\d+) typ (\S+)");
        if (!match.Success)
        {
            return null;
        }

        return (match.Groups[3].Value, $"{match.Groups[1].Value}:{match.Groups[2].Value}");
    }

    internal sealed class SignalCandidate
    {
        [JsonPropertyName("candidate")]
        public string Candidate { get; init; } = string.Empty;

        [JsonPropertyName("sdpMid")]
        public string? SdpMid { get; init; }

        [JsonPropertyName("sdpMLineIndex")]
        public ushort SdpMLineIndex { get; init; }

        [JsonPropertyName("usernameFragment")]
        public string? UsernameFragment { get; init; }
    }
}
