using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using QRCoder;

namespace Skybridge.WinClient.Services;

public interface ICrossNetworkConnectionClient
{
    CrossNetworkCodeInputPolicy BuildCodeInputPolicy();

    string NormalizeCodeInput(string? value);

    bool CanScanQrCode(string qrInput);

    bool CanCopyCode(string generatedCode);

    bool CanConnectWithCode(string codeInput);

    string BuildPendingStatus(CrossNetworkConnectionAction action);

    Task<CrossNetworkConnectionSnapshot> BuildReadOnlySnapshotAsync(CrossNetworkConnectionRequest request);
}

public sealed class CrossNetworkConnectionClient : ICrossNetworkConnectionClient
{
    private const string DirectQrPrefix = "skybridge://connect/";
    private const string QueryQrBase = "skybridge://connect?";
    private const string QueryQrPrefix = "skybridge://connect?data=";
    private const string ShortCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    private const int DynamicQrVersion = 2;
    private const int DeviceFingerprintHexLength = 16;
    private const int PublicKeyLengthBytes = 32;
    private const int RawP256SignatureLengthBytes = 64;
    private const int P256PublicKeyFingerprintHexLength = 64;
    private const double QrSignatureChallengeLifetimeSeconds = 300;
    private const string DynamicQrDeviceType = "macOS";
    private const string GeneratedQrDeviceType = "Windows";
    private const string DynamicQrAddress = "0.0.0.0";
    private const ushort DynamicQrPort = 0;
    private const ushort GeneratedQrPort = 0;
    private const int GeneratedQrPixelsPerModule = 8;
    private static readonly IReadOnlyList<string> DynamicQrCapabilities = new[] { "p2p", "cross-network" };
    private static readonly JsonSerializerOptions QrJsonOptions = new(JsonSerializerDefaults.Web);

    public static CrossNetworkCodeInputPolicy DefaultCodeInputPolicy { get; } =
        new(ShortCodeAlphabet, 6);

    public CrossNetworkCodeInputPolicy BuildCodeInputPolicy() => DefaultCodeInputPolicy;

    public string NormalizeCodeInput(string? value) =>
        NormalizeCodeInput(value, DefaultCodeInputPolicy);

    public static string NormalizeCodeInput(
        string? value,
        CrossNetworkCodeInputPolicy inputPolicy)
    {
        ArgumentNullException.ThrowIfNull(inputPolicy);
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var normalized = new char[inputPolicy.CodeLength];
        var count = 0;
        foreach (var current in value.ToUpperInvariant())
        {
            if (!inputPolicy.Alphabet.Contains(current))
            {
                continue;
            }

            normalized[count] = current;
            count++;
            if (count == normalized.Length)
            {
                break;
            }
        }

        return new string(normalized, 0, count);
    }

    public bool CanScanQrCode(string qrInput) =>
        HasQrInput(qrInput);

    public static bool HasQrInput(string qrInput) =>
        !string.IsNullOrWhiteSpace(qrInput);

    public bool CanCopyCode(string generatedCode) =>
        HasGeneratedCode(generatedCode);

    public static bool HasGeneratedCode(string generatedCode) =>
        !string.IsNullOrWhiteSpace(generatedCode);

    public bool CanConnectWithCode(string codeInput) =>
        CanConnectWithDefaultCodePolicy(codeInput);

    public static bool CanConnectWithDefaultCodePolicy(string codeInput) =>
        TryNormalizeConnectionCode(codeInput, DefaultCodeInputPolicy, out _);

    public string BuildPendingStatus(CrossNetworkConnectionAction action) =>
        BuildDefaultPendingStatus(action);

    public static string BuildDefaultPendingStatus(CrossNetworkConnectionAction action) =>
        action switch
        {
            CrossNetworkConnectionAction.GenerateQrCode => "Generating...",
            CrossNetworkConnectionAction.ScanQrCode => "Scanning...",
            CrossNetworkConnectionAction.GenerateCode => "Generating...",
            CrossNetworkConnectionAction.RegenerateCode => "Generating...",
            CrossNetworkConnectionAction.CopyCode => "Copying...",
            CrossNetworkConnectionAction.ConnectWithCode => "Validating code...",
            _ => "Preparing..."
        };

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
        var generatedQr = BuildSignedGeneratedQrCode();
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Dynamic Encrypted QR Code", "ready", "Windows generates a signed QR URI and renders it as a PNG bitmap for the mac-compatible QR entry point."),
            new("QR bitmap", $"{generatedQr.PngByteLength} bytes", "Rendered with QRCoder PngByteQRCodeHelper and bound to the Windows QR preview image."),
            new("URI format", $"{DirectQrPrefix}<base64url-json>", $"Scanner input must also accept {QueryQrPrefix}<base64url-json>."),
            new("Validity", "5 minutes", "Matches the mac discovery.qrCode.description validity window."),
            new("Session ID", generatedQr.SessionId, "Generated metadata only; no signaling room has been registered for this preview."),
            new("Signature", generatedQr.PublicKeyFingerprint, "sig/pk/ts/fp required by query form; QRCodeSignatureEnvelope embeds signatureBase64/publicKeyBase64/timestamp/publicKeyFingerprint and can be verified by the scanner path."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no WebRTC offerer started", "No signaling WebSocket, ICE negotiation, DataChannel, HTTP file server, or FfiEngineClient connection is started.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            "Waiting for connection...",
            null,
            facts,
            generatedQr.Uri,
            generatedQr.PngBase64);
    }

    private static GeneratedQrCode BuildSignedGeneratedQrCode()
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var publicKey = ExportRawP256PublicKey(signingKey);
        var publicKeyBase64 = Convert.ToBase64String(publicKey);
        var publicKeyFingerprint = Convert.ToHexString(SHA256.HashData(publicKey)).ToLowerInvariant();
        var sessionId = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var timestamp = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0)
            .ToString("0.###", CultureInfo.InvariantCulture);
        var payload = new CanonicalQrPayload(
            sessionId,
            Environment.MachineName,
            GeneratedQrDeviceType,
            DynamicQrAddress,
            GeneratedQrPort,
            Environment.OSVersion.VersionString,
            DynamicQrCapabilities);
        var canonical = BuildQrCanonicalSignaturePayload(
            payload.Id,
            payload.Name,
            payload.Type,
            payload.Address,
            payload.Port,
            payload.OsVersion,
            payload.Capabilities,
            timestamp,
            publicKeyFingerprint);
        var signature = signingKey.SignData(
            Encoding.UTF8.GetBytes(canonical),
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        var envelope = new CanonicalQrEnvelope(
            payload,
            Convert.ToBase64String(signature),
            publicKeyBase64,
            timestamp,
            publicKeyFingerprint);
        var envelopeJson = JsonSerializer.Serialize(envelope, QrJsonOptions);
        var uri = $"{QueryQrPrefix}{Base64UrlEncode(Encoding.UTF8.GetBytes(envelopeJson))}";
        var pngBytes = PngByteQRCodeHelper.GetQRCode(
            uri,
            QRCodeGenerator.ECCLevel.Q,
            GeneratedQrPixelsPerModule);

        return new GeneratedQrCode(
            uri,
            Convert.ToBase64String(pngBytes),
            pngBytes.Length,
            publicKeyFingerprint,
            sessionId);
    }

    private static byte[] ExportRawP256PublicKey(ECDsa signingKey)
    {
        var publicParameters = signingKey.ExportParameters(false);
        if (publicParameters.Q.X is not { Length: 32 } x
            || publicParameters.Q.Y is not { Length: 32 } y)
        {
            throw new InvalidOperationException("QR signing key export must produce a raw P256 public key.");
        }

        var publicKey = new byte[64];
        Buffer.BlockCopy(x, 0, publicKey, 0, x.Length);
        Buffer.BlockCopy(y, 0, publicKey, x.Length, y.Length);
        return publicKey;
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static CrossNetworkConnectionSnapshot BuildQrScanSnapshot(string qrInput)
    {
        var envelope = ExtractQrPayload(qrInput);
        var decodedPayload = DecodeBase64Payload(envelope.Payload);
        var analysis = AnalyzeQrPayload(decodedPayload, envelope);
        var facts = new List<CrossNetworkConnectionFact>
        {
            new("Scan QR Code", "accepted", "Input matches the mac cross-network QR URI envelope."),
            new("Accepted formats", $"{DirectQrPrefix} / {QueryQrPrefix}", "Windows accepts both direct path and data query forms before future scanner integration."),
            new("QR schema", analysis.Schema, "Recognized mac QR payload shape before any transport action."),
            new("Session ID", analysis.SessionId, "Session identifier is metadata only until trust and signaling are wired."),
            new("Device", analysis.DeviceName, analysis.DeviceFingerprint),
            new("Expires At", analysis.ExpiresAtUtc.ToString("O"), analysis.IsExpired ? "expired" : "valid"),
            new("Signature", analysis.SignatureStatus, analysis.SignatureDetail),
            new("Payload length", envelope.Payload.Length.ToString(), "Decoded payload is parsed locally; future adapters must still bind it into Core trust and transport transcripts."),
            new("Scan Error", "none", "Invalid envelopes fail closed before any transport action."),
            new("CrossNetworkReadiness", "idle", "No transportReady or handshakeComplete state is claimed by this read-only snapshot."),
            new("Safety", "no WebRTC answerer started", "No signaling WebSocket, ICE negotiation, DataChannel, HTTP file server, or FfiEngineClient connection is started.")
        };

        return new CrossNetworkConnectionSnapshot(
            DateTimeOffset.UtcNow,
            analysis.SignatureVerified ? "QR signature verified" : "QR payload validated",
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
        if (!TryNormalizeConnectionCode(raw, DefaultCodeInputPolicy, out var code))
        {
            throw new InvalidOperationException("Connection Code must be exactly 6 characters from ABCDEFGHJKLMNPQRSTUVWXYZ23456789.");
        }

        return code;
    }

    private static bool TryNormalizeConnectionCode(
        string raw,
        CrossNetworkCodeInputPolicy inputPolicy,
        out string code)
    {
        code = NormalizeCodeInput(raw, inputPolicy);
        return code.Length == inputPolicy.CodeLength;
    }

    private static QrInputEnvelope ExtractQrPayload(string qrInput)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(qrInput);
        var trimmed = qrInput.Trim();
        string payload;
        IReadOnlyDictionary<string, string> queryParameters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (trimmed.StartsWith(DirectQrPrefix, StringComparison.Ordinal))
        {
            payload = trimmed[DirectQrPrefix.Length..];
            var queryStart = payload.IndexOf('?', StringComparison.Ordinal);
            if (queryStart >= 0)
            {
                queryParameters = ParseQueryParameters(payload[(queryStart + 1)..]);
                payload = payload[..queryStart];
            }
        }
        else if (trimmed.StartsWith(QueryQrBase, StringComparison.Ordinal))
        {
            queryParameters = ParseQueryParameters(trimmed[QueryQrBase.Length..]);
            if (!queryParameters.TryGetValue("data", out var queryPayload))
            {
                throw new InvalidOperationException("Scan Error: QR data query parameter is missing.");
            }

            payload = queryPayload;
        }
        else
        {
            throw new InvalidOperationException($"Scan Error: QR URI must start with {DirectQrPrefix} or {QueryQrPrefix}.");
        }

        ValidateQrPayload(payload);
        return new QrInputEnvelope(payload, queryParameters);
    }

    private static IReadOnlyDictionary<string, string> ParseQueryParameters(string query)
    {
        var parameters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var separator = pair.IndexOf('=', StringComparison.Ordinal);
            var rawName = separator >= 0 ? pair[..separator] : pair;
            var rawValue = separator >= 0 ? pair[(separator + 1)..] : string.Empty;
            var name = Uri.UnescapeDataString(rawName);
            if (string.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            parameters[name] = Uri.UnescapeDataString(rawValue);
        }

        return parameters;
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

    private static byte[] DecodeBase64Payload(string raw)
    {
        var candidates = new List<string> { raw };
        var unescaped = Uri.UnescapeDataString(raw);
        if (!string.Equals(unescaped, raw, StringComparison.Ordinal))
        {
            candidates.Add(unescaped);
        }

        FormatException? lastError = null;
        foreach (var candidate in candidates)
        {
            var padded = candidate
                .Replace('-', '+')
                .Replace('_', '/');
            padded += new string('=', (4 - padded.Length % 4) % 4);
            try
            {
                return Convert.FromBase64String(padded);
            }
            catch (FormatException ex)
            {
                lastError = ex;
            }
        }

        throw new InvalidOperationException("Scan Error: QR payload could not be decoded as base64url JSON.", lastError);
    }

    private static CrossNetworkQrAnalysis AnalyzeQrPayload(byte[] decodedPayload, QrInputEnvelope envelope)
    {
        using var document = JsonDocument.Parse(decodedPayload);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidOperationException("Scan Error: QR payload must decode to a JSON object.");
        }

        if (root.TryGetProperty("payload", out var payload) && root.TryGetProperty("signature", out var legacySignature))
        {
            return AnalyzeSignedQrPayload(payload, legacySignature);
        }

        if (root.TryGetProperty("payload", out var signedEnvelopePayload)
            && root.TryGetProperty("signatureBase64", out _)
            && root.TryGetProperty("publicKeyBase64", out _)
            && root.TryGetProperty("timestamp", out _)
            && root.TryGetProperty("publicKeyFingerprint", out _))
        {
            return AnalyzeCanonicalQrPayload(
                signedEnvelopePayload,
                ReadRequiredString(root, "signatureBase64"),
                ReadRequiredString(root, "publicKeyBase64"),
                ReadCanonicalTimestampText(root.GetProperty("timestamp"), "timestamp"),
                ReadRequiredString(root, "publicKeyFingerprint"),
                "QRCodeSignatureEnvelope");
        }

        if (TryGetQuerySignature(envelope, out var querySignature, out var queryPublicKey, out var queryTimestamp, out var queryFingerprint))
        {
            return AnalyzeCanonicalQrPayload(root, querySignature, queryPublicKey, queryTimestamp, queryFingerprint, "QRCodeSignatureQuery");
        }

        if (root.TryGetProperty("sessionID", out _)
            && root.TryGetProperty("deviceFingerprint", out _)
            && root.TryGetProperty("signingPublicKey", out _)
            && root.TryGetProperty("signature", out _)
            && root.TryGetProperty("signatureTimestamp", out _))
        {
            return AnalyzeDynamicQrCodeData(root, envelope);
        }

        throw new InvalidOperationException("Scan Error: QR payload is not SignedQRPayload, DynamicQRCodeData, or QRCodeSignature payload.");
    }

    private static CrossNetworkQrAnalysis AnalyzeSignedQrPayload(JsonElement payload, JsonElement signature)
    {
        var version = ReadRequiredInt32(payload, "version");
        ValidateQrVersion(version);
        var sessionId = ReadRequiredString(payload, "sessionID");
        var deviceFingerprint = ReadRequiredString(payload, "deviceFingerprint");
        ValidateDeviceFingerprint(deviceFingerprint);
        var deviceName = ReadRequiredString(payload, "deviceName");
        var publicKey = ReadRequiredString(payload, "publicKey");
        var signingPublicKey = ReadRequiredString(payload, "signingPublicKey");
        var localAddresses = ReadRequiredArray(payload, "localAddresses");
        var port = ReadRequiredUInt16(payload, "port");
        var expiresAt = ReadEpochDateTimeOffset(payload, "expiresAt");
        ThrowIfExpired(expiresAt);

        ValidateByteLength(ValidateBase64Bytes(publicKey, "publicKey"), PublicKeyLengthBytes, "publicKey");
        var signingPublicKeyBytes = ValidateBase64Bytes(signingPublicKey, "signingPublicKey");
        ValidateP256PublicKey(signingPublicKeyBytes);
        var signatureBytes = ValidateBase64Bytes(ReadString(signature, "signature"), "signature");
        ValidateByteLength(signatureBytes, RawP256SignatureLengthBytes, "signature");
        var signatureVerified = VerifyP256RawSignature(
            Encoding.UTF8.GetBytes(payload.GetRawText()),
            signatureBytes,
            signingPublicKeyBytes);
        if (!signatureVerified)
        {
            throw new InvalidOperationException("Scan Error: QR signature verification failed.");
        }

        return new CrossNetworkQrAnalysis(
            "SignedQRPayload",
            sessionId,
            deviceName,
            deviceFingerprint,
            expiresAt,
            false,
            "verified",
            $"P256 raw signature verified; version={version}; localAddresses={localAddresses.Count}, port={port}.",
            true);
    }

    private static CrossNetworkQrAnalysis AnalyzeCanonicalQrPayload(
        JsonElement payload,
        string signatureBase64,
        string publicKeyBase64,
        string timestampText,
        string publicKeyFingerprint,
        string schema)
    {
        var id = ReadRequiredString(payload, "id");
        var name = ReadRequiredString(payload, "name");
        var type = ReadRequiredString(payload, "type");
        var address = ReadRequiredString(payload, "address");
        var port = ReadRequiredUInt16(payload, "port", allowZero: true);
        var osVersion = ReadRequiredString(payload, "osVersion");
        var capabilities = ReadRequiredArray(payload, "capabilities");
        var timestamp = ParseUnixTimestamp(timestampText, "timestamp");
        var expiresAt = DateTimeOffset.FromUnixTimeMilliseconds((long)((timestamp + QrSignatureChallengeLifetimeSeconds) * 1000));
        ThrowIfExpired(expiresAt);

        ValidateHex(publicKeyFingerprint, P256PublicKeyFingerprintHexLength, "publicKeyFingerprint");
        var publicKeyBytes = ValidateBase64Bytes(publicKeyBase64, "publicKeyBase64");
        ValidateP256PublicKey(publicKeyBytes);
        ValidateFingerprint(publicKeyBytes, publicKeyFingerprint, "publicKeyFingerprint");
        var signatureBytes = ValidateBase64Bytes(signatureBase64, "signatureBase64");
        ValidateByteLength(signatureBytes, RawP256SignatureLengthBytes, "signatureBase64");

        var canonical = BuildQrCanonicalSignaturePayload(
            id,
            name,
            type,
            address,
            port,
            osVersion,
            capabilities,
            timestampText,
            publicKeyFingerprint);
        if (!VerifyP256RawSignature(Encoding.UTF8.GetBytes(canonical), signatureBytes, publicKeyBytes))
        {
            throw new InvalidOperationException("Scan Error: QR canonical signature verification failed.");
        }

        return new CrossNetworkQrAnalysis(
            schema,
            id,
            name,
            id,
            expiresAt,
            false,
            "verified",
            $"P256 canonical signature verified; challengeLifetime={QrSignatureChallengeLifetimeSeconds:0}s; type={type}; address={address}:{port}.",
            true);
    }

    private static CrossNetworkQrAnalysis AnalyzeDynamicQrCodeData(JsonElement root, QrInputEnvelope envelope)
    {
        var version = ReadRequiredInt32(root, "version");
        ValidateQrVersion(version);
        var sessionId = ReadRequiredString(root, "sessionID");
        var deviceName = ReadRequiredString(root, "deviceName");
        var deviceFingerprint = ReadRequiredString(root, "deviceFingerprint");
        ValidateDeviceFingerprint(deviceFingerprint);
        var publicKey = ReadRequiredString(root, "publicKey");
        var signingPublicKey = ReadRequiredString(root, "signingPublicKey");
        var signature = ReadRequiredString(root, "signature");
        var signatureTimestamp = ReadRequiredDouble(root, "signatureTimestamp");
        var signatureTimestampText = root.GetProperty("signatureTimestamp").GetRawText();
        var iceServers = ReadRequiredArray(root, "iceServers");
        var expiresAt = ReadAppleOrUnixDateTimeOffset(root, "expiresAt");
        ThrowIfExpired(expiresAt);

        ValidateByteLength(ValidateBase64Bytes(publicKey, "publicKey"), PublicKeyLengthBytes, "publicKey");
        var signingPublicKeyBytes = ValidateBase64Bytes(signingPublicKey, "signingPublicKey");
        ValidateP256PublicKey(signingPublicKeyBytes);
        var signingKeyFingerprint = Convert.ToHexString(SHA256.HashData(signingPublicKeyBytes)).ToLowerInvariant();
        var signatureBytes = ValidateBase64Bytes(signature, "signature");
        ValidateByteLength(signatureBytes, RawP256SignatureLengthBytes, "signature");
        ValidateSignatureTimestamp(signatureTimestamp, "signatureTimestamp");

        if (!TryGetDynamicQrSignedOsVersion(root, envelope, out var signedOsVersion))
        {
            return new CrossNetworkQrAnalysis(
                "DynamicQRCodeData",
                sessionId,
                deviceName,
                deviceFingerprint,
                expiresAt,
                false,
                "unverifiable",
                $"version={version}; signingPublicKey/signature present; iceServers={iceServers.Count}; TDSC canonical QR signature requires the generator osVersion, but current DynamicQRCodeData does not carry that signed field.",
                false);
        }

        var canonical = BuildQrCanonicalSignaturePayload(
            deviceFingerprint,
            deviceName,
            DynamicQrDeviceType,
            DynamicQrAddress,
            DynamicQrPort,
            signedOsVersion,
            DynamicQrCapabilities,
            signatureTimestampText,
            signingKeyFingerprint);
        if (!VerifyP256RawSignature(Encoding.UTF8.GetBytes(canonical), signatureBytes, signingPublicKeyBytes))
        {
            throw new InvalidOperationException("Scan Error: QR dynamic canonical signature verification failed.");
        }

        return new CrossNetworkQrAnalysis(
            "DynamicQRCodeData",
            sessionId,
            deviceName,
            deviceFingerprint,
            expiresAt,
            false,
            "verified",
            $"P256 dynamic canonical signature verified; version={version}; osVersion={signedOsVersion}; type={DynamicQrDeviceType}; address={DynamicQrAddress}:{DynamicQrPort}; iceServers={iceServers.Count}.",
            true);
    }

    private static string BuildQrCanonicalSignaturePayload(
        string id,
        string name,
        string type,
        string address,
        ushort port,
        string osVersion,
        IReadOnlyList<string> capabilities,
        string timestampText,
        string publicKeyFingerprint) =>
        $"id={id}|name={name}|type={type}|address={address}|port={port}|os={osVersion}|cap={string.Join(",", capabilities)}|ts={timestampText}|fp={publicKeyFingerprint}";

    private static bool TryGetDynamicQrSignedOsVersion(
        JsonElement root,
        QrInputEnvelope envelope,
        out string osVersion)
    {
        if (TryReadOptionalString(root, "osVersion", out osVersion)
            || TryReadOptionalString(root, "signedOsVersion", out osVersion)
            || TryGetQueryValue(envelope, "osVersion", out osVersion)
            || TryGetQueryValue(envelope, "os", out osVersion))
        {
            return true;
        }

        osVersion = string.Empty;
        return false;
    }

    private static bool TryGetQuerySignature(
        QrInputEnvelope envelope,
        out string signature,
        out string publicKey,
        out string timestamp,
        out string fingerprint)
    {
        var query = envelope.QueryParameters;
        if (query.TryGetValue("sig", out var querySignature)
            && query.TryGetValue("pk", out var queryPublicKey)
            && query.TryGetValue("ts", out var queryTimestamp)
            && query.TryGetValue("fp", out var queryFingerprint)
            && !string.IsNullOrWhiteSpace(querySignature)
            && !string.IsNullOrWhiteSpace(queryPublicKey)
            && !string.IsNullOrWhiteSpace(queryTimestamp)
            && !string.IsNullOrWhiteSpace(queryFingerprint))
        {
            signature = querySignature;
            publicKey = queryPublicKey;
            timestamp = queryTimestamp;
            fingerprint = queryFingerprint;
            return true;
        }

        signature = string.Empty;
        publicKey = string.Empty;
        timestamp = string.Empty;
        fingerprint = string.Empty;
        return false;
    }

    private static string ReadRequiredString(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var property))
        {
            throw new InvalidOperationException($"Scan Error: QR payload missing {propertyName}.");
        }

        var value = ReadString(property, propertyName);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} is empty.");
        }

        return value;
    }

    private static bool TryReadOptionalString(JsonElement element, string propertyName, out string value)
    {
        if (!element.TryGetProperty(propertyName, out var property))
        {
            value = string.Empty;
            return false;
        }

        value = ReadString(property, propertyName);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} is empty.");
        }

        return true;
    }

    private static bool TryGetQueryValue(QrInputEnvelope envelope, string propertyName, out string value)
    {
        if (envelope.QueryParameters.TryGetValue(propertyName, out var queryValue)
            && !string.IsNullOrWhiteSpace(queryValue))
        {
            value = queryValue;
            return true;
        }

        value = string.Empty;
        return false;
    }

    private static string ReadString(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be a string.");
        }

        return element.GetString() ?? string.Empty;
    }

    private static string ReadCanonicalTimestampText(JsonElement element, string propertyName) =>
        element.ValueKind switch
        {
            JsonValueKind.Number => element.GetRawText(),
            JsonValueKind.String => ReadString(element, propertyName),
            _ => throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be numeric or a numeric string.")
        };

    private static int ReadRequiredInt32(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var property) || !property.TryGetInt32(out var value))
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be an integer.");
        }

        return value;
    }

    private static double ReadRequiredDouble(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var property) || !property.TryGetDouble(out var value))
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be numeric.");
        }

        return value;
    }

    private static ushort ReadRequiredUInt16(JsonElement element, string propertyName, bool allowZero = false)
    {
        var value = ReadRequiredInt32(element, propertyName);
        var lowerBound = allowZero ? 0 : 1;
        if (value < lowerBound || value > 65535)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be between {lowerBound} and 65535.");
        }

        return (ushort)value;
    }

    private static IReadOnlyList<string> ReadRequiredArray(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be an array.");
        }

        var values = new List<string>();
        foreach (var current in property.EnumerateArray())
        {
            if (current.ValueKind != JsonValueKind.String)
            {
                throw new InvalidOperationException($"Scan Error: QR payload {propertyName} items must be strings.");
            }

            var value = current.GetString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException($"Scan Error: QR payload {propertyName} items must not be empty.");
            }

            values.Add(value);
        }

        return values;
    }

    private static DateTimeOffset ReadEpochDateTimeOffset(JsonElement element, string propertyName)
    {
        var value = ReadRequiredDouble(element, propertyName);
        return DateTimeOffset.FromUnixTimeMilliseconds((long)(value * 1000));
    }

    private static DateTimeOffset ReadAppleOrUnixDateTimeOffset(JsonElement element, string propertyName)
    {
        var value = ReadRequiredDouble(element, propertyName);
        var unixSeconds = value < 1_000_000_000 ? value + 978_307_200 : value;
        return DateTimeOffset.FromUnixTimeMilliseconds((long)(unixSeconds * 1000));
    }

    private static void ThrowIfExpired(DateTimeOffset expiresAtUtc)
    {
        if (expiresAtUtc <= DateTimeOffset.UtcNow)
        {
            throw new InvalidOperationException("Scan Error: QR code expired.");
        }
    }

    private static void ValidateQrVersion(int version)
    {
        if (version != DynamicQrVersion)
        {
            throw new InvalidOperationException($"Scan Error: QR payload version must be {DynamicQrVersion}.");
        }
    }

    private static void ValidateDeviceFingerprint(string value)
    {
        ValidateHex(value, DeviceFingerprintHexLength, "deviceFingerprint");
    }

    private static void ValidateHex(string value, int expectedLength, string propertyName)
    {
        if (value.Length != expectedLength)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be {expectedLength} hex characters.");
        }

        foreach (var current in value)
        {
            if (!Uri.IsHexDigit(current))
            {
                throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be hex.");
            }
        }
    }

    private static void ValidateByteLength(byte[] value, int expectedLength, string propertyName)
    {
        if (value.Length != expectedLength)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must decode to {expectedLength} bytes.");
        }
    }

    private static void ValidateFingerprint(byte[] publicKeyBytes, string expectedFingerprint, string propertyName)
    {
        var actual = Convert.ToHexString(SHA256.HashData(publicKeyBytes)).ToLowerInvariant();
        if (!string.Equals(actual, expectedFingerprint, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} does not match the signing public key.");
        }
    }

    private static double ParseUnixTimestamp(string value, string propertyName)
    {
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var timestamp) || timestamp <= 0)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be a positive Unix timestamp.");
        }

        return timestamp;
    }

    private static void ValidateSignatureTimestamp(double timestamp, string propertyName)
    {
        if (timestamp <= 0)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be positive.");
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        if (Math.Abs(now - timestamp) > QrSignatureChallengeLifetimeSeconds)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} is outside the {QrSignatureChallengeLifetimeSeconds:0}-second challenge window.");
        }
    }

    private static byte[] ValidateBase64Bytes(string value, string propertyName)
    {
        try
        {
            var bytes = Convert.FromBase64String(value);
            if (bytes.Length == 0)
            {
                throw new InvalidOperationException($"Scan Error: QR payload {propertyName} is empty.");
            }

            return bytes;
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException($"Scan Error: QR payload {propertyName} must be base64.", ex);
        }
    }

    private static bool VerifyP256RawSignature(byte[] payload, byte[] signature, byte[] signingPublicKey)
    {
        using var ecdsa = ECDsa.Create(BuildP256Parameters(signingPublicKey));
        return ecdsa.VerifyData(
            payload,
            signature,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    private static void ValidateP256PublicKey(byte[] signingPublicKey)
    {
        using var ecdsa = ECDsa.Create(BuildP256Parameters(signingPublicKey));
        if (ecdsa.KeySize != 256)
        {
            throw new InvalidOperationException("Scan Error: QR signingPublicKey must be a P256 raw public key.");
        }
    }

    private static ECParameters BuildP256Parameters(byte[] signingPublicKey)
    {
        var key = signingPublicKey;
        if (key.Length == 65 && key[0] == 0x04)
        {
            return new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint
                {
                    X = key[1..33],
                    Y = key[33..65]
                }
            };
        }

        if (key.Length == 64)
        {
            return new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint
                {
                    X = key[..32],
                    Y = key[32..64]
                }
            };
        }

        throw new InvalidOperationException("Scan Error: QR signingPublicKey must be a P256 raw public key.");
    }
}

internal sealed record QrInputEnvelope(
    string Payload,
    IReadOnlyDictionary<string, string> QueryParameters);

internal sealed record CrossNetworkQrAnalysis(
    string Schema,
    string SessionId,
    string DeviceName,
    string DeviceFingerprint,
    DateTimeOffset ExpiresAtUtc,
    bool IsExpired,
    string SignatureStatus,
    string SignatureDetail,
    bool SignatureVerified);

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
    IReadOnlyList<CrossNetworkConnectionFact> Facts,
    string? GeneratedQrCodePayload = null,
    string? GeneratedQrCodePngBase64 = null);

public sealed record CrossNetworkConnectionFact(
    string Label,
    string Value,
    string Detail);

public sealed record CrossNetworkCodeInputPolicy(
    string Alphabet,
    int CodeLength);

internal sealed record GeneratedQrCode(
    string Uri,
    string PngBase64,
    int PngByteLength,
    string PublicKeyFingerprint,
    string SessionId);

internal sealed record CanonicalQrPayload(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("address")] string Address,
    [property: JsonPropertyName("port")] ushort Port,
    [property: JsonPropertyName("osVersion")] string OsVersion,
    [property: JsonPropertyName("capabilities")] IReadOnlyList<string> Capabilities);

internal sealed record CanonicalQrEnvelope(
    [property: JsonPropertyName("payload")] CanonicalQrPayload Payload,
    [property: JsonPropertyName("signatureBase64")] string SignatureBase64,
    [property: JsonPropertyName("publicKeyBase64")] string PublicKeyBase64,
    [property: JsonPropertyName("timestamp")] string Timestamp,
    [property: JsonPropertyName("publicKeyFingerprint")] string PublicKeyFingerprint);
