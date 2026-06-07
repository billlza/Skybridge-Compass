using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public interface ICrossNetworkConnectionClient
{
    Task<CrossNetworkConnectionSnapshot> BuildReadOnlySnapshotAsync(CrossNetworkConnectionRequest request);
}

public sealed class CrossNetworkConnectionClient : ICrossNetworkConnectionClient
{
    private const string DirectQrPrefix = "skybridge://connect/";
    private const string QueryQrPrefix = "skybridge://connect?data=";
    private const string ShortCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    public Task<CrossNetworkConnectionSnapshot> BuildReadOnlySnapshotAsync(CrossNetworkConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        return request.Action switch
        {
            CrossNetworkConnectionAction.GenerateQrCode => Task.FromResult(BuildQrGenerationSnapshot()),
            CrossNetworkConnectionAction.ScanQrCode => Task.FromResult(BuildQrScanSnapshot(request.QrInput)),
            CrossNetworkConnectionAction.GenerateCode => Task.FromResult(BuildCodeSnapshot("Generate Code")),
            CrossNetworkConnectionAction.RegenerateCode => Task.FromResult(BuildCodeSnapshot("Regenerate")),
            CrossNetworkConnectionAction.CopyCode => Task.FromResult(BuildCopySnapshot(request.CurrentCode)),
            CrossNetworkConnectionAction.ConnectWithCode => Task.FromResult(BuildCodeInputSnapshot(request.CodeInput)),
            _ => throw new InvalidOperationException("Unsupported cross-network connection action.")
        };
    }

    private static CrossNetworkConnectionSnapshot BuildQrGenerationSnapshot()
    {
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Dynamic Encrypted QR Code", "Generate QR Code", "Windows keeps the mac QR entry point visible while native QR bitmap generation is pending."),
            new("URI format", $"{DirectQrPrefix}<base64url-json>", $"Scanner input must also accept {QueryQrPrefix}<base64url-json>."),
            new("Validity", "5 minutes", "Matches the mac discovery.qrCode.description validity window."),
            new("Signature", "sig/pk/ts/fp required", "QR payload signature verification must pass before any future WebRTC answerer starts."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no WebRTC offerer started", "No signaling WebSocket, ICE negotiation, DataChannel, HTTP file server, or FfiEngineClient connection is started.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            "Waiting for connection...",
            null,
            facts);
    }

    private static CrossNetworkConnectionSnapshot BuildQrScanSnapshot(string qrInput)
    {
        var payload = ExtractQrPayload(qrInput);
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Scan QR Code", "accepted", "Input matches the mac cross-network QR URI envelope."),
            new("Accepted formats", $"{DirectQrPrefix} / {QueryQrPrefix}", "Windows accepts both direct path and data query forms before future scanner integration."),
            new("Payload length", payload.Length.ToString(), "Payload is only envelope-checked here; signature and expiry verification remain required."),
            new("Scan Error", "none", "Invalid envelopes fail closed before any transport action."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no WebRTC answerer started", "No signaling WebSocket, ICE negotiation, DataChannel, HTTP file server, or FfiEngineClient connection is started.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            "QR envelope validated",
            null,
            facts);
    }

    private static CrossNetworkConnectionSnapshot BuildCodeSnapshot(string actionLabel)
    {
        var code = GenerateShortCode();
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Smart Connection Code", code, "6-digit code, valid for 10 mins, for remote assistance; this preview is not registered with signaling."),
            new("Alphabet", ShortCodeAlphabet, "Matches the mac short-code character set and excludes ambiguous 0/O and 1/I/l glyphs."),
            new("Action", actionLabel, "Generate Code and Regenerate share the same read-only validation path."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no signaling room registered", "No WebRTC offerer, WebRTC answerer, signaling WebSocket, HTTP file server, or FfiEngineClient connection is started.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            "Waiting for connection...",
            code,
            facts);
    }

    private static CrossNetworkConnectionSnapshot BuildCopySnapshot(string currentCode)
    {
        var normalized = NormalizeConnectionCode(currentCode);
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Copy", normalized, "Mac exposes Copy for generated smart codes; Windows keeps the action visible without mutating the clipboard in this read-only boundary."),
            new("Smart Connection Code", normalized, "Code shape is valid, but no signaling room has been registered."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no clipboard or network write", "Copy remains an explicit future UI action and does not start WebRTC or FfiEngineClient.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            "Copy prepared",
            normalized,
            facts);
    }

    private static CrossNetworkConnectionSnapshot BuildCodeInputSnapshot(string codeInput)
    {
        var normalized = NormalizeConnectionCode(codeInput);
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Connect", normalized, "Input accepted only after the mac 6-character filter; no WebRTC join is started."),
            new("Alphabet", ShortCodeAlphabet, "Only mac-compatible smart-code characters are accepted."),
            new("Validity", "10 minutes", "A live adapter must verify the remote signaling session is still valid."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no WebRTC answerer started", "No signaling room join, ICE negotiation, DataChannel, HTTP file server, or FfiEngineClient connection is started.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            "Code envelope validated",
            normalized,
            facts);
    }

    private static string GenerateShortCode()
    {
        var chars = new char[6];
        for (var index = 0; index < chars.Length; index++)
        {
            chars[index] = ShortCodeAlphabet[RandomNumberGenerator.GetInt32(ShortCodeAlphabet.Length)];
        }

        return new string(chars);
    }

    private static string NormalizeConnectionCode(string raw)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(raw);
        var normalized = new List<char>(6);
        foreach (var current in raw.Trim().ToUpperInvariant())
        {
            if (ShortCodeAlphabet.Contains(current))
            {
                normalized.Add(current);
            }

            if (normalized.Count == 6)
            {
                break;
            }
        }

        var code = new string(normalized.ToArray());
        if (code.Length != 6)
        {
            throw new InvalidOperationException("Connection Code must be exactly 6 characters from ABCDEFGHJKLMNPQRSTUVWXYZ23456789.");
        }

        return code;
    }

    private static string ExtractQrPayload(string qrInput)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(qrInput);
        var trimmed = qrInput.Trim();
        string payload;
        if (trimmed.StartsWith(DirectQrPrefix, StringComparison.Ordinal))
        {
            payload = trimmed[DirectQrPrefix.Length..];
            var queryStart = payload.IndexOf('?', StringComparison.Ordinal);
            if (queryStart >= 0)
            {
                payload = payload[..queryStart];
            }
        }
        else if (trimmed.StartsWith(QueryQrPrefix, StringComparison.Ordinal))
        {
            payload = trimmed[QueryQrPrefix.Length..];
            var queryEnd = payload.IndexOf('&', StringComparison.Ordinal);
            if (queryEnd >= 0)
            {
                payload = payload[..queryEnd];
            }

            payload = Uri.UnescapeDataString(payload);
        }
        else
        {
            throw new InvalidOperationException($"Scan Error: QR URI must start with {DirectQrPrefix} or {QueryQrPrefix}.");
        }

        ValidateQrPayload(payload);
        return payload;
    }

    private static void ValidateQrPayload(string payload)
    {
        if (payload.Length < 8)
        {
            throw new InvalidOperationException("Scan Error: QR payload is too short.");
        }

        foreach (var current in payload)
        {
            if (char.IsLetterOrDigit(current) || current is '-' or '_' or '+' or '/' or '=')
            {
                continue;
            }

            throw new InvalidOperationException("Scan Error: QR payload must be base64 or base64url text.");
        }
    }
}

public enum CrossNetworkConnectionAction
{
    GenerateQrCode,
    ScanQrCode,
    GenerateCode,
    RegenerateCode,
    CopyCode,
    ConnectWithCode
}

public sealed record CrossNetworkConnectionRequest(
    CrossNetworkConnectionAction Action,
    string QrInput,
    string CodeInput,
    string CurrentCode);

public sealed record CrossNetworkConnectionSnapshot(
    DateTimeOffset CapturedAt,
    string Status,
    string? GeneratedCode,
    IReadOnlyList<CrossNetworkConnectionFact> Facts);

public sealed record CrossNetworkConnectionFact(
    string Label,
    string Value,
    string Detail);
