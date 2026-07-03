using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

public enum CurrentPathProtocolSigningAlgorithm
{
    Ed25519,
    MLDsa65,
}

public static class CurrentPathProtocolSigningAlgorithms
{
    public const string Ed25519WireName = "Ed25519";
    public const string MLDsa65WireName = "ML-DSA-65";

    public static string ToWireName(CurrentPathProtocolSigningAlgorithm algorithm) =>
        algorithm switch
        {
            CurrentPathProtocolSigningAlgorithm.Ed25519 => Ed25519WireName,
            CurrentPathProtocolSigningAlgorithm.MLDsa65 => MLDsa65WireName,
            _ => throw new InvalidDataException($"Unsupported current-path protocol signing algorithm: {algorithm}.")
        };

    public static CurrentPathProtocolSigningAlgorithm ParseWireName(string raw)
    {
        var value = raw.Trim();
        return value switch
        {
            Ed25519WireName => CurrentPathProtocolSigningAlgorithm.Ed25519,
            MLDsa65WireName => CurrentPathProtocolSigningAlgorithm.MLDsa65,
            _ => throw new InvalidDataException($"Unsupported current-path protocol signing algorithm: {value}.")
        };
    }
}

public sealed class CurrentPathProtocolIdentityBinding
{
    public const int MaxDeviceIdLength = 128;
    public const int MinDeviceIdLength = 16;
    private const string AllowedDeviceIdCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-";

    public CurrentPathProtocolIdentityBinding(
        string deviceId,
        CurrentPathProtocolSigningAlgorithm protocolSigningAlgorithm,
        ReadOnlyMemory<byte> protocolPublicKeyBytes,
        string? protocolPublicKeyFingerprint = null)
    {
        DeviceId = NormalizeDeviceId(deviceId);
        ProtocolSigningAlgorithm = protocolSigningAlgorithm;
        ProtocolPublicKeyBytes = ValidatePublicKeyBytes(protocolPublicKeyBytes, protocolSigningAlgorithm);
        var fingerprint = string.IsNullOrWhiteSpace(protocolPublicKeyFingerprint)
            ? ComputeFingerprint(protocolSigningAlgorithm, ProtocolPublicKeyBytes.Span)
            : protocolPublicKeyFingerprint.Trim();
        if (!IsLowerHex(fingerprint, 64))
        {
            throw new InvalidDataException("Current-path protocol identity fingerprint must be 64 lowercase hex characters.");
        }

        ProtocolPublicKeyFingerprint = fingerprint;
    }

    public string DeviceId { get; }

    public CurrentPathProtocolSigningAlgorithm ProtocolSigningAlgorithm { get; }

    public ReadOnlyMemory<byte> ProtocolPublicKeyBytes { get; }

    public string ProtocolPublicKeyFingerprint { get; }

    public string ProtocolSigningAlgorithmWireName =>
        CurrentPathProtocolSigningAlgorithms.ToWireName(ProtocolSigningAlgorithm);

    public static string NormalizeDeviceId(string raw)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(raw);
        var normalized = raw.Trim();
        if (normalized.Length is < MinDeviceIdLength or > MaxDeviceIdLength)
        {
            throw new InvalidDataException("Current-path deviceId length is outside the allowed range.");
        }

        foreach (var current in normalized)
        {
            if (!AllowedDeviceIdCharacters.Contains(current, StringComparison.Ordinal))
            {
                throw new InvalidDataException("Current-path deviceId contains an unsupported character.");
            }
        }

        return normalized;
    }

    public static string ComputeFingerprint(
        CurrentPathProtocolSigningAlgorithm algorithm,
        ReadOnlySpan<byte> publicKeyBytes)
    {
        var algorithmRaw = Encoding.UTF8.GetBytes(CurrentPathProtocolSigningAlgorithms.ToWireName(algorithm));
        Span<byte> header = stackalloc byte[6];
        BinaryPrimitives.WriteUInt16LittleEndian(header[..2], checked((ushort)algorithmRaw.Length));
        BinaryPrimitives.WriteUInt32LittleEndian(header[2..], checked((uint)publicKeyBytes.Length));
        var payload = new byte[header.Length + algorithmRaw.Length + publicKeyBytes.Length];
        header[..2].CopyTo(payload);
        algorithmRaw.CopyTo(payload.AsSpan(2));
        header[2..].CopyTo(payload.AsSpan(2 + algorithmRaw.Length));
        publicKeyBytes.CopyTo(payload.AsSpan(6 + algorithmRaw.Length));
        return Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
    }

    public static bool IsLowerHex(string value, int length) =>
        value.Length == length && value.All(ch => (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'));

    private static byte[] ValidatePublicKeyBytes(
        ReadOnlyMemory<byte> publicKeyBytes,
        CurrentPathProtocolSigningAlgorithm algorithm)
    {
        switch (algorithm)
        {
            case CurrentPathProtocolSigningAlgorithm.Ed25519:
                if (publicKeyBytes.Length != 32)
                {
                    throw new InvalidDataException("Ed25519 current-path public key must be exactly 32 bytes.");
                }

                break;
            case CurrentPathProtocolSigningAlgorithm.MLDsa65:
                if (publicKeyBytes.IsEmpty)
                {
                    throw new InvalidDataException("ML-DSA-65 current-path public key must not be empty.");
                }

                break;
            default:
                throw new InvalidDataException($"Unsupported current-path protocol signing algorithm: {algorithm}.");
        }

        return publicKeyBytes.ToArray();
    }
}

public static class CurrentPathOriginPolicy
{
    public static string CanonicalOrigin(string raw)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(raw);
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri))
        {
            throw new InvalidDataException("Current-path signaling origin is invalid.");
        }

        var scheme = uri.Scheme.ToLowerInvariant();
        if (scheme != Uri.UriSchemeHttps && !(scheme == Uri.UriSchemeHttp && IsLoopbackHost(uri.Host)))
        {
            throw new InvalidDataException("Current-path signaling origin must be https, except http loopback origins.");
        }

        if (!string.IsNullOrEmpty(uri.AbsolutePath) && uri.AbsolutePath != "/")
        {
            throw new InvalidDataException("Current-path signaling origin must not include a path.");
        }

        if (!string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new InvalidDataException("Current-path signaling origin must not include query or fragment components.");
        }

        var builder = new UriBuilder(uri)
        {
            Scheme = scheme,
            Path = string.Empty,
            Query = string.Empty,
            Fragment = string.Empty,
        };
        if ((scheme == Uri.UriSchemeHttps && builder.Port == 443) ||
            (scheme == Uri.UriSchemeHttp && builder.Port == 80))
        {
            builder.Port = -1;
        }

        return builder.Uri.GetLeftPart(UriPartial.Authority).TrimEnd('/');
    }

    public static bool IsLoopbackHost(string rawHost)
    {
        var host = rawHost.Trim().Trim('[', ']').ToLowerInvariant();
        if (host is "localhost" or "::1" or "0:0:0:0:0:0:0:1")
        {
            return true;
        }

        if (IPAddress.TryParse(host, out var address))
        {
            return IPAddress.IsLoopback(address);
        }

        return false;
    }
}

public static class CurrentPathSignalingWebSocketPolicy
{
    public const string SessionIdHeader = "X-SkyBridge-Session-Id";
    public const string SessionTokenHeader = "X-SkyBridge-Session";
    public const string ClientVersionHeader = "X-SkyBridge-Client-Version";
    public const string ProtocolVersionHeader = "X-SkyBridge-Protocol-Version";

    public const int MaxWebSocketPathLength = 256;
    public const int MaxSessionIdLength = 512;
    public const int MaxSessionTokenLength = 4096;
    public const int MaxVersionLength = 64;

    public static Uri BuildHeaderCredentialWebSocketUri(
        string signalingServerOrigin,
        string wsPath,
        string sessionId,
        string sessionToken,
        string clientVersion,
        string protocolVersion)
    {
        var origin = CurrentPathOriginPolicy.CanonicalOrigin(signalingServerOrigin);
        var normalizedSessionId = NormalizeSessionId(sessionId);
        RequireCredentialValue(normalizedSessionId, MaxSessionIdLength, "current-path session id");
        RequireCredentialValue(sessionToken, MaxSessionTokenLength, "current-path session token");
        RequireCredentialValue(clientVersion, MaxVersionLength, "current-path client version");
        RequireCredentialValue(protocolVersion, MaxVersionLength, "current-path protocol version");
        var path = ValidateWebSocketPath(wsPath);
        var originUri = new Uri(origin);
        var builder = new UriBuilder(originUri)
        {
            Scheme = originUri.Scheme == Uri.UriSchemeHttps ? "wss" : "ws",
            Path = path,
            Query = string.Join(
                "&",
                new[]
                {
                    $"shard={Uri.EscapeDataString(normalizedSessionId)}",
                    $"cv={Uri.EscapeDataString(clientVersion.Trim())}",
                    $"pv={Uri.EscapeDataString(protocolVersion.Trim())}",
                }),
        };
        return builder.Uri;
    }

    public static IReadOnlyDictionary<string, string> BuildHeaderCredentials(
        string sessionId,
        string sessionToken,
        string clientVersion,
        string protocolVersion)
    {
        var normalizedSessionId = NormalizeSessionId(sessionId);
        RequireCredentialValue(normalizedSessionId, MaxSessionIdLength, "current-path session id");
        RequireCredentialValue(sessionToken, MaxSessionTokenLength, "current-path session token");
        RequireCredentialValue(clientVersion, MaxVersionLength, "current-path client version");
        RequireCredentialValue(protocolVersion, MaxVersionLength, "current-path protocol version");
        return new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [SessionIdHeader] = normalizedSessionId,
            [SessionTokenHeader] = sessionToken.Trim(),
            [ClientVersionHeader] = clientVersion.Trim(),
            [ProtocolVersionHeader] = protocolVersion.Trim(),
        };
    }

    public static string ValidateWebSocketPath(string rawPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rawPath);
        var path = rawPath.Trim();
        ValidateWebSocketPathCharacters(path);
        ValidateWebSocketPathSegments(path);

        for (var index = 0; index < path.Length; index++)
        {
            if (path[index] != '%')
            {
                continue;
            }

            if (index + 2 >= path.Length || !IsHex(path[index + 1]) || !IsHex(path[index + 2]))
            {
                throw new InvalidDataException("Current-path signaling websocket path contains an invalid percent escape.");
            }
        }

        var decodedPath = Uri.UnescapeDataString(path);
        ValidateWebSocketPathCharacters(decodedPath);
        ValidateWebSocketPathSegments(decodedPath);
        return path;
    }

    private static string NormalizeSessionId(string sessionId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        return sessionId.Trim().ToUpperInvariant();
    }

    private static void RequireCredentialValue(string raw, int maxLength, string label)
    {
        var value = raw.Trim();
        if (value.Length == 0 || value.Length > maxLength)
        {
            throw new InvalidDataException($"{label} is empty or too long.");
        }

        foreach (var current in value)
        {
            if (current < 0x20 || current == 0x7F || current == ',')
            {
                throw new InvalidDataException($"{label} contains an invalid credential character.");
            }
        }
    }

    private static bool IsHex(char value) =>
        (value >= '0' && value <= '9') ||
        (value >= 'a' && value <= 'f') ||
        (value >= 'A' && value <= 'F');

    private static void ValidateWebSocketPathCharacters(string path)
    {
        if (path[0] != '/' ||
            path == "/" ||
            path.Length > MaxWebSocketPathLength ||
            path.Contains('?', StringComparison.Ordinal) ||
            path.Contains('#', StringComparison.Ordinal) ||
            path.Contains('\\', StringComparison.Ordinal) ||
            path.Contains("//", StringComparison.Ordinal))
        {
            throw new InvalidDataException("Current-path signaling websocket path is invalid.");
        }

        foreach (var current in path)
        {
            if (current < 0x21 || current > 0x7E || char.IsWhiteSpace(current))
            {
                throw new InvalidDataException("Current-path signaling websocket path contains an invalid character.");
            }
        }
    }

    private static void ValidateWebSocketPathSegments(string path)
    {
        var segments = path.Split('/');
        if (segments.Length < 2 || segments[0] != string.Empty)
        {
            throw new InvalidDataException("Current-path signaling websocket path is invalid.");
        }

        foreach (var segment in segments.Skip(1))
        {
            if (segment.Length == 0 || segment is "." or "..")
            {
                throw new InvalidDataException("Current-path signaling websocket path contains an unsafe segment.");
            }
        }
    }
}

public sealed class CurrentPathSignalServerClient
{
    private const int MaxJsonResponseBytes = 128 * 1024;

    public const string DefaultBaseUrl = "https://api.nebula-technologies.net";
    public const string DefaultClientApiKey = "skybridge-client-v1";
    public const string DefaultClientVersion = "1.0.0";
    public const string DefaultProtocolVersion = "1";

    public const string AdmissionChallengePath = "/api/webrtc/admission/challenge";
    public const string AdmissionPath = "/api/webrtc/admission";
    public const string RegisterCodePath = "/api/webrtc/register-code";
    public const int MinConnectionCodeTtlSeconds = 60;
    public const int MaxConnectionCodeTtlSeconds = 24 * 60 * 60;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly HttpClient _httpClient;
    private readonly CurrentPathSignalServerClientOptions _options;

    public CurrentPathSignalServerClient(
        HttpClient httpClient,
        CurrentPathSignalServerClientOptions options)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _ = CurrentPathOriginPolicy.CanonicalOrigin(_options.BaseUrl);
    }

    public async Task<CurrentPathAdmissionChallenge> RequestAdmissionChallengeAsync(
        CurrentPathProtocolIdentityBinding binding,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(binding);
        var body = new AdmissionChallengeRequestBody(
            binding.DeviceId,
            binding.ProtocolSigningAlgorithmWireName,
            binding.ProtocolPublicKeyFingerprint,
            _options.ClientVersion,
            _options.ProtocolVersion);
        var response = await PerformJsonRequestAsync<AdmissionChallengeResponseBody>(
                AdmissionChallengePath,
                HttpMethod.Post,
                body,
                requiresUserAuthentication: true,
                extraHeaders: null,
                cancellationToken)
            .ConfigureAwait(false);
        return response.ToDomain();
    }

    public async Task<CurrentPathAdmissionLease> CompleteAdmissionAsync(
        CurrentPathAdmissionChallenge challenge,
        CurrentPathProtocolIdentityBinding binding,
        ReadOnlyMemory<byte> signature,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(challenge);
        ArgumentNullException.ThrowIfNull(binding);
        if (signature.IsEmpty)
        {
            throw new InvalidDataException("Current-path admission signature must not be empty.");
        }

        var body = new AdmissionRequestBody(
            challenge.ChallengeId,
            signature.ToArray(),
            binding.DeviceId,
            binding.ProtocolSigningAlgorithmWireName,
            binding.ProtocolPublicKeyFingerprint,
            binding.ProtocolPublicKeyBytes.ToArray(),
            challenge.ClientVersion,
            challenge.ProtocolVersion);
        var response = await PerformJsonRequestAsync<AdmissionResponseBody>(
                AdmissionPath,
                HttpMethod.Post,
                body,
                requiresUserAuthentication: true,
                extraHeaders: null,
                cancellationToken)
            .ConfigureAwait(false);
        return response.ToDomain();
    }

    public async Task<CurrentPathConnectionCodeLease> RegisterConnectionCodeAsync(
        string admissionToken,
        string deviceName,
        TimeSpan validDuration,
        CancellationToken cancellationToken = default)
    {
        var normalizedAdmissionToken = RequireToken(admissionToken, "current-path admission token");
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceName);
        if (validDuration <= TimeSpan.Zero)
        {
            throw new InvalidDataException("Current-path connection-code duration must be positive.");
        }

        var requestedTtlSeconds = checked((int)Math.Ceiling(validDuration.TotalSeconds));
        if (requestedTtlSeconds > MaxConnectionCodeTtlSeconds)
        {
            throw new InvalidDataException(
                $"Current-path connection-code duration must not exceed {MaxConnectionCodeTtlSeconds} seconds.");
        }

        var body = new RegisterCodeRequestBody(
            deviceName.Trim(),
            Math.Max(MinConnectionCodeTtlSeconds, requestedTtlSeconds));
        var response = await PerformJsonRequestAsync<RegisterCodeResponseBody>(
                RegisterCodePath,
                HttpMethod.Post,
                body,
                requiresUserAuthentication: false,
                extraHeaders: new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["X-SkyBridge-Admission"] = normalizedAdmissionToken,
                },
                cancellationToken)
            .ConfigureAwait(false);
        return response.ToDomain();
    }

    public async Task<CurrentPathConnectionCodeLookup> LookupConnectionCodeAsync(
        string admissionToken,
        string code,
        CancellationToken cancellationToken = default)
    {
        var normalizedAdmissionToken = RequireToken(admissionToken, "current-path admission token");
        var normalizedCode = NormalizeConnectionCode(code);
        var response = await PerformJsonRequestAsync<LookupCodeResponseBody>(
                LookupCodePath(normalizedCode),
                HttpMethod.Get,
                body: null,
                requiresUserAuthentication: false,
                extraHeaders: new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["X-SkyBridge-Admission"] = normalizedAdmissionToken,
                },
                cancellationToken)
            .ConfigureAwait(false);
        return response.ToDomain();
    }

    public static string LookupCodePath(string code) =>
        $"/api/webrtc/lookup/{Uri.EscapeDataString(NormalizeConnectionCode(code))}";

    private static string NormalizeConnectionCode(string raw)
    {
        if (!CrossNetworkConnectionCodePolicy.TryNormalize(raw, out var normalized))
        {
            throw new InvalidDataException(
                CrossNetworkConnectionCodePolicy.BuildInvalidMessage("Current-path connection code"));
        }

        return normalized;
    }

    private async Task<T> PerformJsonRequestAsync<T>(
        string path,
        HttpMethod method,
        object? body,
        bool requiresUserAuthentication,
        IReadOnlyDictionary<string, string>? extraHeaders,
        CancellationToken cancellationToken)
    {
        var baseUri = new Uri(CurrentPathOriginPolicy.CanonicalOrigin(_options.BaseUrl));
        var requestUri = new Uri(baseUri, path);
        using var request = new HttpRequestMessage(method, requestUri);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        var apiKey = _options.ApiKey.Trim();
        if (!string.IsNullOrEmpty(apiKey))
        {
            AddValidatedHeader(request.Headers, "X-API-Key", apiKey, "current-path API key");
        }

        var tenantId = await _options.TenantIdProvider(cancellationToken).ConfigureAwait(false);
        tenantId = tenantId.Trim();
        if (requiresUserAuthentication && string.IsNullOrEmpty(tenantId))
        {
            throw new CurrentPathSignalServerException("missing_tenant_id", HttpStatusCode.Unauthorized);
        }

        if (!string.IsNullOrEmpty(tenantId))
        {
            AddValidatedHeader(request.Headers, "X-SkyBridge-Tenant-Id", tenantId, "current-path tenant id");
        }

        if (requiresUserAuthentication)
        {
            var bearerToken = await _options.BearerTokenProvider(cancellationToken).ConfigureAwait(false);
            bearerToken = bearerToken.Trim();
            if (string.IsNullOrEmpty(bearerToken))
            {
                throw new CurrentPathSignalServerException("missing_bearer_token", HttpStatusCode.Unauthorized);
            }

            request.Headers.Authorization = new AuthenticationHeaderValue(
                "Bearer",
                RequireHeaderValue(bearerToken, "current-path bearer token"));
        }

        if (extraHeaders is not null)
        {
            foreach (var (name, value) in extraHeaders)
            {
                AddValidatedHeader(request.Headers, name, value, $"current-path header {name}");
            }
        }

        if (body is not null)
        {
            request.Content = new StringContent(
                JsonSerializer.Serialize(body, JsonOptions),
                Encoding.UTF8,
                "application/json");
        }

        using var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken)
            .ConfigureAwait(false);
        var data = await ReadBoundedJsonResponseBodyAsync(response, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new CurrentPathSignalServerException(
                CurrentPathSignalServerException.SanitizeServerRejectedBody(data),
                response.StatusCode);
        }

        try
        {
            var decoded = JsonSerializer.Deserialize<T>(data, JsonOptions);
            if (decoded is null)
            {
                throw new InvalidDataException("empty JSON response");
            }

            return decoded;
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException or FormatException)
        {
            throw new InvalidDataException("Current-path signal server response is malformed.", ex);
        }
    }

    private static string RequireToken(string raw, string label)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(raw);
        return RequireHeaderValue(raw, label);
    }

    private static async Task<byte[]> ReadBoundedJsonResponseBodyAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var contentLength = response.Content.Headers.ContentLength;
        if (contentLength > MaxJsonResponseBytes)
        {
            ThrowResponseBodyTooLarge(response);
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return output.ToArray();
            }

            if (output.Length + read > MaxJsonResponseBytes)
            {
                ThrowResponseBodyTooLarge(response);
            }

            output.Write(buffer, 0, read);
        }
    }

    private static void ThrowResponseBodyTooLarge(HttpResponseMessage response)
    {
        if (!response.IsSuccessStatusCode)
        {
            throw new CurrentPathSignalServerException("response_body_too_large", response.StatusCode);
        }

        throw new InvalidDataException("Current-path signal server response body is too large.");
    }

    private static void AddValidatedHeader(
        HttpRequestHeaders headers,
        string name,
        string rawValue,
        string label)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Any(ch => ch <= 0x20 || ch >= 0x7F || ch == ':'))
        {
            throw new InvalidDataException("Current-path header name is invalid.");
        }

        headers.Add(name, RequireHeaderValue(rawValue, label));
    }

    private static string RequireHeaderValue(string raw, string label)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(raw);
        var token = raw.Trim();
        if (token.Length > CurrentPathSignalingWebSocketPolicy.MaxSessionTokenLength)
        {
            throw new InvalidDataException($"{label} is too long.");
        }

        foreach (var current in token)
        {
            if (current < 0x21 || current == 0x7F || current == ',')
            {
                throw new InvalidDataException($"{label} contains an invalid header character.");
            }
        }

        return token;
    }

    private sealed record AdmissionChallengeRequestBody(
        [property: JsonPropertyName("deviceId")] string DeviceId,
        [property: JsonPropertyName("protocolSigningAlgorithm")] string ProtocolSigningAlgorithm,
        [property: JsonPropertyName("protocolPublicKeyFingerprint")] string ProtocolPublicKeyFingerprint,
        [property: JsonPropertyName("clientVersion")] string ClientVersion,
        [property: JsonPropertyName("protocolVersion")] string ProtocolVersion);

    private sealed record AdmissionRequestBody(
        [property: JsonPropertyName("challengeId")] string ChallengeId,
        [property: JsonPropertyName("signature")] byte[] Signature,
        [property: JsonPropertyName("deviceId")] string DeviceId,
        [property: JsonPropertyName("protocolSigningAlgorithm")] string ProtocolSigningAlgorithm,
        [property: JsonPropertyName("protocolPublicKeyFingerprint")] string ProtocolPublicKeyFingerprint,
        [property: JsonPropertyName("protocolPublicKeyBytes")] byte[] ProtocolPublicKeyBytes,
        [property: JsonPropertyName("clientVersion")] string ClientVersion,
        [property: JsonPropertyName("protocolVersion")] string ProtocolVersion);

    private sealed record RegisterCodeRequestBody(
        [property: JsonPropertyName("deviceName")] string DeviceName,
        [property: JsonPropertyName("ttlSeconds")] int TtlSeconds);

    private sealed record AdmissionChallengeResponseBody(
        [property: JsonPropertyName("challengeId")] string? ChallengeId,
        [property: JsonPropertyName("nonce")] string? Nonce,
        [property: JsonPropertyName("tenantId")] string? TenantId,
        [property: JsonPropertyName("userId")] string? UserId,
        [property: JsonPropertyName("deviceId")] string? DeviceId,
        [property: JsonPropertyName("clientIpHash")] string? ClientIpHash,
        [property: JsonPropertyName("clientVersion")] string? ClientVersion,
        [property: JsonPropertyName("protocolVersion")] string? ProtocolVersion,
        [property: JsonPropertyName("state")] string? State,
        [property: JsonPropertyName("issuedAt")] long IssuedAt,
        [property: JsonPropertyName("expiresAt")] long ExpiresAt)
    {
        public CurrentPathAdmissionChallenge ToDomain() =>
            new(
                RequiredString(ChallengeId, "challengeId"),
                RequiredString(Nonce, "nonce"),
                RequiredString(TenantId, "tenantId"),
                RequiredString(UserId, "userId"),
                RequiredString(DeviceId, "deviceId"),
                RequiredString(ClientIpHash, "clientIpHash"),
                RequiredString(ClientVersion, "clientVersion"),
                RequiredString(ProtocolVersion, "protocolVersion"),
                RequiredString(State, "state"),
                UnixMs(IssuedAt, "issuedAt"),
                UnixMs(ExpiresAt, "expiresAt"));
    }

    private sealed record AdmissionResponseBody(
        [property: JsonPropertyName("admissionToken")] string? AdmissionToken,
        [property: JsonPropertyName("state")] string? State,
        [property: JsonPropertyName("issuedAt")] long IssuedAt,
        [property: JsonPropertyName("expiresAt")] long ExpiresAt)
    {
        public CurrentPathAdmissionLease ToDomain() =>
            new(
                RequiredString(AdmissionToken, "admissionToken"),
                RequiredString(State, "state"),
                UnixMs(IssuedAt, "issuedAt"),
                UnixMs(ExpiresAt, "expiresAt"));
    }

    private sealed record RegisterCodeResponseBody(
        [property: JsonPropertyName("code")] string? Code,
        [property: JsonPropertyName("sessionId")] string? SessionId,
        [property: JsonPropertyName("sessionToken")] string? SessionToken,
        [property: JsonPropertyName("turnAdmissionToken")] string? TurnAdmissionToken,
        [property: JsonPropertyName("mediaAdmissionToken")] string? MediaAdmissionToken,
        [property: JsonPropertyName("expiresIn")] int ExpiresIn,
        [property: JsonPropertyName("signalingServerOrigin")] string? SignalingServerOrigin,
        [property: JsonPropertyName("wsPath")] string? WsPath)
    {
        public CurrentPathConnectionCodeLease ToDomain() =>
            new(
                NormalizeConnectionCode(RequiredString(Code, "code")),
                RequiredString(SessionId, "sessionId"),
                RequiredString(SessionToken, "sessionToken"),
                RequiredString(TurnAdmissionToken, "turnAdmissionToken"),
                OptionalString(MediaAdmissionToken),
                PositiveInt(ExpiresIn, "expiresIn"),
                CurrentPathOriginPolicy.CanonicalOrigin(RequiredString(SignalingServerOrigin, "signalingServerOrigin")),
                CurrentPathSignalingWebSocketPolicy.ValidateWebSocketPath(RequiredString(WsPath, "wsPath")));
    }

    private sealed record LookupCodeResponseBody(
        [property: JsonPropertyName("found")] bool Found,
        [property: JsonPropertyName("sessionId")] string? SessionId,
        [property: JsonPropertyName("sessionToken")] string? SessionToken,
        [property: JsonPropertyName("turnAdmissionToken")] string? TurnAdmissionToken,
        [property: JsonPropertyName("mediaAdmissionToken")] string? MediaAdmissionToken,
        [property: JsonPropertyName("expiresIn")] int ExpiresIn,
        [property: JsonPropertyName("signalingServerOrigin")] string? SignalingServerOrigin,
        [property: JsonPropertyName("wsPath")] string? WsPath,
        [property: JsonPropertyName("initiatorDeviceId")] string? InitiatorDeviceId,
        [property: JsonPropertyName("initiatorProtocolSigningAlgorithm")] string? InitiatorProtocolSigningAlgorithm,
        [property: JsonPropertyName("initiatorProtocolPublicKeyFingerprint")] string? InitiatorProtocolPublicKeyFingerprint,
        [property: JsonPropertyName("initiatorDeviceName")] string? InitiatorDeviceName)
    {
        public CurrentPathConnectionCodeLookup ToDomain()
        {
            if (!Found)
            {
                throw new InvalidDataException("Current-path connection code lookup returned found=false.");
            }

            var algorithm = CurrentPathProtocolSigningAlgorithms.ParseWireName(
                RequiredString(InitiatorProtocolSigningAlgorithm, "initiatorProtocolSigningAlgorithm"));
            var fingerprint = RequiredString(
                InitiatorProtocolPublicKeyFingerprint,
                "initiatorProtocolPublicKeyFingerprint");
            if (!CurrentPathProtocolIdentityBinding.IsLowerHex(fingerprint, 64))
            {
                throw new InvalidDataException("Current-path lookup initiator fingerprint must be 64 lowercase hex characters.");
            }

            return new CurrentPathConnectionCodeLookup(
                RequiredString(SessionId, "sessionId"),
                RequiredString(SessionToken, "sessionToken"),
                RequiredString(TurnAdmissionToken, "turnAdmissionToken"),
                OptionalString(MediaAdmissionToken),
                PositiveInt(ExpiresIn, "expiresIn"),
                CurrentPathOriginPolicy.CanonicalOrigin(RequiredString(SignalingServerOrigin, "signalingServerOrigin")),
                CurrentPathSignalingWebSocketPolicy.ValidateWebSocketPath(RequiredString(WsPath, "wsPath")),
                CurrentPathProtocolIdentityBinding.NormalizeDeviceId(RequiredString(InitiatorDeviceId, "initiatorDeviceId")),
                algorithm,
                fingerprint,
                OptionalString(InitiatorDeviceName));
        }
    }

    private static string RequiredString(string? value, string field)
    {
        var normalized = OptionalString(value);
        if (normalized is null)
        {
            throw new InvalidDataException($"Current-path signal server response missing {field}.");
        }

        return normalized;
    }

    private static string? OptionalString(string? value)
    {
        var normalized = value?.Trim();
        return string.IsNullOrEmpty(normalized) ? null : normalized;
    }

    private static DateTimeOffset UnixMs(long value, string field)
    {
        if (value <= 0)
        {
            throw new InvalidDataException($"Current-path signal server response {field} must be positive.");
        }

        return DateTimeOffset.FromUnixTimeMilliseconds(value);
    }

    private static int PositiveInt(int value, string field)
    {
        if (value <= 0)
        {
            throw new InvalidDataException($"Current-path signal server response {field} must be positive.");
        }

        return value;
    }
}

public sealed class CurrentPathSignalServerClientOptions
{
    public CurrentPathSignalServerClientOptions(
        string baseUrl = CurrentPathSignalServerClient.DefaultBaseUrl,
        string apiKey = CurrentPathSignalServerClient.DefaultClientApiKey,
        Func<CancellationToken, Task<string>>? bearerTokenProvider = null,
        Func<CancellationToken, Task<string>>? tenantIdProvider = null,
        string clientVersion = CurrentPathSignalServerClient.DefaultClientVersion,
        string protocolVersion = CurrentPathSignalServerClient.DefaultProtocolVersion)
    {
        BaseUrl = CurrentPathOriginPolicy.CanonicalOrigin(baseUrl);
        ApiKey = apiKey.Trim();
        BearerTokenProvider = bearerTokenProvider ?? (_ => Task.FromResult(string.Empty));
        TenantIdProvider = tenantIdProvider ?? (_ => Task.FromResult(string.Empty));
        ClientVersion = RequireVersion(clientVersion, "current-path client version");
        ProtocolVersion = RequireVersion(protocolVersion, "current-path protocol version");
    }

    public string BaseUrl { get; }

    public string ApiKey { get; }

    public Func<CancellationToken, Task<string>> BearerTokenProvider { get; }

    public Func<CancellationToken, Task<string>> TenantIdProvider { get; }

    public string ClientVersion { get; }

    public string ProtocolVersion { get; }

    private static string RequireVersion(string value, string label)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        var normalized = value.Trim();
        if (normalized.Length > CurrentPathSignalingWebSocketPolicy.MaxVersionLength ||
            normalized.Any(ch => ch < 0x20 || ch == 0x7F || ch == ','))
        {
            throw new InvalidDataException($"{label} is invalid.");
        }

        return normalized;
    }
}

public sealed record CurrentPathAdmissionChallenge(
    string ChallengeId,
    string Nonce,
    string TenantId,
    string UserId,
    string DeviceId,
    string ClientIpHash,
    string ClientVersion,
    string ProtocolVersion,
    string State,
    DateTimeOffset IssuedAt,
    DateTimeOffset ExpiresAt)
{
    public byte[] BuildSignaturePayload() =>
        Encoding.UTF8.GetBytes(string.Join(
            "\n",
            new[]
            {
                "SkyBridge-Admission-Challenge",
                ChallengeId,
                Nonce,
                TenantId,
                UserId,
                DeviceId,
                ClientVersion,
                ProtocolVersion,
            }));
}

public sealed class CurrentPathMldsa65AdmissionSigner : IDisposable
{
    private static readonly byte[] EmptyMldsaContext = Array.Empty<byte>();
    private readonly MLDsa _signer;
    private bool _disposed;

    private CurrentPathMldsa65AdmissionSigner(MLDsa signer)
    {
        _signer = signer;
    }

    public static CurrentPathMldsa65AdmissionSigner ImportPrivateKey(ReadOnlySpan<byte> privateKeyBytes)
    {
        EnsurePlatformSupport();
        if (privateKeyBytes.Length == MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes)
        {
            return new CurrentPathMldsa65AdmissionSigner(
                MLDsa.ImportMLDsaPrivateSeed(MLDsaAlgorithm.MLDsa65, privateKeyBytes));
        }

        if (privateKeyBytes.Length == MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes)
        {
            return new CurrentPathMldsa65AdmissionSigner(
                MLDsa.ImportMLDsaPrivateKey(MLDsaAlgorithm.MLDsa65, privateKeyBytes));
        }

        throw new InvalidDataException(
            $"Current-path ML-DSA-65 private key must be {MLDsaAlgorithm.MLDsa65.PrivateSeedSizeInBytes} byte seed or {MLDsaAlgorithm.MLDsa65.PrivateKeySizeInBytes} byte private key.");
    }

    public CurrentPathProtocolIdentityBinding CreateBinding(string deviceId)
    {
        ThrowIfDisposed();
        return new CurrentPathProtocolIdentityBinding(
            deviceId,
            CurrentPathProtocolSigningAlgorithm.MLDsa65,
            _signer.ExportMLDsaPublicKey());
    }

    public byte[] SignAdmissionChallenge(
        CurrentPathAdmissionChallenge challenge,
        CurrentPathProtocolIdentityBinding binding)
    {
        ArgumentNullException.ThrowIfNull(challenge);
        ArgumentNullException.ThrowIfNull(binding);
        ThrowIfDisposed();
        if (binding.ProtocolSigningAlgorithm != CurrentPathProtocolSigningAlgorithm.MLDsa65)
        {
            throw new InvalidDataException("Current-path ML-DSA-65 admission signer requires an ML-DSA-65 binding.");
        }

        if (!string.Equals(challenge.DeviceId, binding.DeviceId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Current-path admission challenge deviceId does not match the local binding.");
        }

        var localPublicKey = _signer.ExportMLDsaPublicKey();
        if (!localPublicKey.AsSpan().SequenceEqual(binding.ProtocolPublicKeyBytes.Span))
        {
            throw new InvalidDataException("Current-path admission binding public key does not match the local signer.");
        }

        if (!string.Equals(
                CurrentPathProtocolIdentityBinding.ComputeFingerprint(
                    CurrentPathProtocolSigningAlgorithm.MLDsa65,
                    localPublicKey),
                binding.ProtocolPublicKeyFingerprint,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Current-path admission binding fingerprint does not match the local signer.");
        }

        return _signer.SignData(challenge.BuildSignaturePayload(), EmptyMldsaContext);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _signer.Dispose();
    }

    private static void EnsurePlatformSupport()
    {
        if (!MLDsa.IsSupported)
        {
            throw new PlatformNotSupportedException("The current platform does not support ML-DSA.");
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(CurrentPathMldsa65AdmissionSigner));
        }
    }
}

public sealed record CurrentPathAdmissionLease(
    string Token,
    string State,
    DateTimeOffset IssuedAt,
    DateTimeOffset ExpiresAt)
{
    public override string ToString() =>
        $"{nameof(CurrentPathAdmissionLease)} {{ Token = <redacted>, State = {State}, IssuedAt = {IssuedAt:O}, ExpiresAt = {ExpiresAt:O} }}";
}

public sealed record CurrentPathConnectionCodeLease(
    string Code,
    string SessionId,
    string SessionToken,
    string TurnAdmissionToken,
    string? MediaAdmissionToken,
    int ExpiresIn,
    string SignalingServerOrigin,
    string WsPath)
{
    public override string ToString() =>
        $"{nameof(CurrentPathConnectionCodeLease)} {{ Code = <redacted>, SessionId = <redacted>, SessionToken = <redacted>, TurnAdmissionToken = <redacted>, MediaAdmissionToken = {RedactedOptional(MediaAdmissionToken)}, ExpiresIn = {ExpiresIn}, SignalingServerOrigin = {SignalingServerOrigin}, WsPath = {WsPath} }}";

    private static string RedactedOptional(string? value) =>
        string.IsNullOrEmpty(value) ? "null" : "<redacted>";
}

public sealed record CurrentPathConnectionCodeLookup(
    string SessionId,
    string SessionToken,
    string TurnAdmissionToken,
    string? MediaAdmissionToken,
    int ExpiresIn,
    string SignalingServerOrigin,
    string WsPath,
    string InitiatorDeviceId,
    CurrentPathProtocolSigningAlgorithm InitiatorProtocolSigningAlgorithm,
    string InitiatorProtocolPublicKeyFingerprint,
    string? InitiatorDeviceName)
{
    public override string ToString() =>
        $"{nameof(CurrentPathConnectionCodeLookup)} {{ SessionId = <redacted>, SessionToken = <redacted>, TurnAdmissionToken = <redacted>, MediaAdmissionToken = {RedactedOptional(MediaAdmissionToken)}, ExpiresIn = {ExpiresIn}, SignalingServerOrigin = {SignalingServerOrigin}, WsPath = {WsPath}, InitiatorDeviceId = {RedactedStableIdentifier(InitiatorDeviceId)}, InitiatorProtocolSigningAlgorithm = {InitiatorProtocolSigningAlgorithm}, InitiatorProtocolPublicKeyFingerprint = {RedactedStableIdentifier(InitiatorProtocolPublicKeyFingerprint)}, InitiatorDeviceName = {RedactedOptional(InitiatorDeviceName)} }}";

    private static string RedactedOptional(string? value) =>
        string.IsNullOrEmpty(value) ? "null" : "<redacted>";

    private static string RedactedStableIdentifier(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "null";
        }

        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(value.Trim()));
        return "<sha256:" + Convert.ToHexString(digest.AsSpan(0, 6)).ToLowerInvariant() + ">";
    }
}

public enum CurrentPathWebRtcSignalingMessageType
{
    Join,
    Offer,
    Answer,
    IceCandidate,
    Leave,
}

public static class CurrentPathWebRtcSignalingMessageTypes
{
    public static string ToWireName(CurrentPathWebRtcSignalingMessageType type) =>
        type switch
        {
            CurrentPathWebRtcSignalingMessageType.Join => "join",
            CurrentPathWebRtcSignalingMessageType.Offer => "offer",
            CurrentPathWebRtcSignalingMessageType.Answer => "answer",
            CurrentPathWebRtcSignalingMessageType.IceCandidate => "iceCandidate",
            CurrentPathWebRtcSignalingMessageType.Leave => "leave",
            _ => throw new InvalidDataException($"Unsupported current-path WebRTC signaling message type: {type}.")
        };

    public static CurrentPathWebRtcSignalingMessageType ParseWireName(string raw)
    {
        var value = raw.Trim();
        return value switch
        {
            "join" => CurrentPathWebRtcSignalingMessageType.Join,
            "offer" => CurrentPathWebRtcSignalingMessageType.Offer,
            "answer" => CurrentPathWebRtcSignalingMessageType.Answer,
            "iceCandidate" => CurrentPathWebRtcSignalingMessageType.IceCandidate,
            "leave" => CurrentPathWebRtcSignalingMessageType.Leave,
            _ => throw new InvalidDataException($"Unsupported current-path WebRTC signaling message type: {value}.")
        };
    }
}

public sealed class CurrentPathWebRtcSignalingMessageTypeJsonConverter
    : JsonConverter<CurrentPathWebRtcSignalingMessageType>
{
    public override CurrentPathWebRtcSignalingMessageType Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("Current-path WebRTC signaling message type must be a string.");
        }

        return CurrentPathWebRtcSignalingMessageTypes.ParseWireName(reader.GetString() ?? string.Empty);
    }

    public override void Write(
        Utf8JsonWriter writer,
        CurrentPathWebRtcSignalingMessageType value,
        JsonSerializerOptions options) =>
        writer.WriteStringValue(CurrentPathWebRtcSignalingMessageTypes.ToWireName(value));
}

public sealed record CurrentPathBootstrapKemPublicKey
{
    [JsonConstructor]
    public CurrentPathBootstrapKemPublicKey(
        ushort suiteWireId,
        byte[] publicKey)
    {
        if (publicKey.Length == 0)
        {
            throw new InvalidDataException("Current-path bootstrap KEM public key must not be empty.");
        }

        SuiteWireId = suiteWireId;
        PublicKey = publicKey.ToArray();
    }

    [JsonPropertyName("suiteWireId")]
    public ushort SuiteWireId { get; }

    [JsonPropertyName("publicKey")]
    public byte[] PublicKey { get; }
}

public sealed record CurrentPathWebRtcSignalingPayload
{
    public const int MaxSdpBytes = 12 * 1024;
    public const int MaxIceCandidateBytes = 2048;
    public const int MaxSdpMidBytes = 128;

    [JsonConstructor]
    public CurrentPathWebRtcSignalingPayload(
        string? sdp = null,
        string? candidate = null,
        string? sdpMid = null,
        int? sdpMLineIndex = null,
        string? protocolSigningAlgorithm = null,
        string? protocolPublicKeyFingerprint = null,
        byte[]? protocolPublicKeyBytes = null,
        IReadOnlyList<CurrentPathBootstrapKemPublicKey>? kemPublicKeys = null,
        string? platform = null,
        string? osVersion = null)
    {
        Sdp = ValidateBoundedUtf8Text(sdp, MaxSdpBytes, "current-path SDP");
        Candidate = ValidateBoundedUtf8Text(candidate, MaxIceCandidateBytes, "current-path ICE candidate");
        SdpMid = ValidateBoundedUtf8Text(sdpMid, MaxSdpMidBytes, "current-path SDP mid");
        SdpMLineIndex = sdpMLineIndex;
        ProtocolSigningAlgorithm = string.IsNullOrWhiteSpace(protocolSigningAlgorithm)
            ? null
            : CurrentPathProtocolSigningAlgorithms.ToWireName(
                CurrentPathProtocolSigningAlgorithms.ParseWireName(protocolSigningAlgorithm));
        if (sdpMLineIndex < 0)
        {
            throw new InvalidDataException("Current-path SDP m-line index must not be negative.");
        }

        if (!string.IsNullOrWhiteSpace(protocolPublicKeyFingerprint) &&
            !CurrentPathProtocolIdentityBinding.IsLowerHex(protocolPublicKeyFingerprint.Trim(), 64))
        {
            throw new InvalidDataException("Current-path signaling payload fingerprint must be 64 lowercase hex characters.");
        }

        ProtocolPublicKeyFingerprint = string.IsNullOrWhiteSpace(protocolPublicKeyFingerprint)
            ? null
            : protocolPublicKeyFingerprint.Trim();
        ProtocolPublicKeyBytes = protocolPublicKeyBytes is null ? null : protocolPublicKeyBytes.ToArray();
        KemPublicKeys = kemPublicKeys?.Select(key => new CurrentPathBootstrapKemPublicKey(key.SuiteWireId, key.PublicKey)).ToArray();
        Platform = ValidateShortMetadata(platform, "current-path platform");
        OsVersion = ValidateShortMetadata(osVersion, "current-path OS version");
    }

    [JsonPropertyName("sdp")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Sdp { get; }

    [JsonPropertyName("candidate")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Candidate { get; }

    [JsonPropertyName("sdpMid")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SdpMid { get; }

    [JsonPropertyName("sdpMLineIndex")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? SdpMLineIndex { get; }

    [JsonPropertyName("protocolSigningAlgorithm")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ProtocolSigningAlgorithm { get; }

    [JsonPropertyName("protocolPublicKeyFingerprint")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ProtocolPublicKeyFingerprint { get; }

    [JsonPropertyName("protocolPublicKeyBytes")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public byte[]? ProtocolPublicKeyBytes { get; }

    [JsonPropertyName("kemPublicKeys")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<CurrentPathBootstrapKemPublicKey>? KemPublicKeys { get; }

    [JsonPropertyName("platform")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Platform { get; }

    [JsonPropertyName("osVersion")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? OsVersion { get; }

    private static string? ValidateBoundedUtf8Text(string? raw, int maxBytes, string label)
    {
        if (raw is null)
        {
            return null;
        }

        if (Encoding.UTF8.GetByteCount(raw) > maxBytes)
        {
            throw new InvalidDataException($"{label} exceeds the current-path signaling byte limit.");
        }

        return raw;
    }

    private static string? ValidateShortMetadata(string? raw, string label)
    {
        var normalized = raw?.Trim();
        if (string.IsNullOrEmpty(normalized))
        {
            return null;
        }

        if (normalized.Length > 128 || normalized.Any(ch => ch < 0x20 || ch == 0x7F))
        {
            throw new InvalidDataException($"{label} is invalid.");
        }

        return normalized;
    }
}

public sealed record CurrentPathWebRtcSignalingEnvelope
{
    [JsonConstructor]
    public CurrentPathWebRtcSignalingEnvelope(
        string sessionId,
        string from,
        string? to,
        CurrentPathWebRtcSignalingMessageType type,
        CurrentPathWebRtcSignalingPayload? payload = null,
        string? authToken = null,
        double sentAt = 0)
    {
        SessionId = NormalizeSessionId(sessionId);
        From = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(from);
        To = string.IsNullOrWhiteSpace(to) ? null : CurrentPathProtocolIdentityBinding.NormalizeDeviceId(to);
        Type = type;
        ValidatePayloadForType(type, payload);
        Payload = payload;
        if (!string.IsNullOrWhiteSpace(authToken))
        {
            throw new InvalidDataException("Current-path signaling envelopes must not carry authToken; use header credentials.");
        }

        AuthToken = null;
        SentAt = sentAt == 0 ? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000d : sentAt;
        if (!double.IsFinite(SentAt) || SentAt <= 0)
        {
            throw new InvalidDataException("Current-path signaling envelope sentAt must be a positive finite timestamp.");
        }
    }

    [JsonPropertyName("sessionId")]
    public string SessionId { get; }

    [JsonPropertyName("from")]
    public string From { get; }

    [JsonPropertyName("to")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? To { get; }

    [JsonPropertyName("type")]
    [JsonConverter(typeof(CurrentPathWebRtcSignalingMessageTypeJsonConverter))]
    public CurrentPathWebRtcSignalingMessageType Type { get; }

    [JsonPropertyName("payload")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public CurrentPathWebRtcSignalingPayload? Payload { get; }

    [JsonPropertyName("authToken")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AuthToken { get; }

    [JsonPropertyName("sentAt")]
    public double SentAt { get; }

    public override string ToString() =>
        $"{nameof(CurrentPathWebRtcSignalingEnvelope)} {{ SessionId = <redacted>, From = {RedactedStableIdentifier(From)}, To = {RedactedStableIdentifier(To)}, Type = {Type}, PayloadPresent = {Payload is not null}, AuthToken = {RedactedOptional(AuthToken)}, SentAt = {SentAt.ToString(CultureInfo.InvariantCulture)} }}";

    public static string NormalizeSessionId(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw new InvalidDataException("Current-path signaling envelope sessionId is missing.");
        }

        var normalized = raw.Trim().ToUpperInvariant();
        if (normalized.Length > CurrentPathSignalingWebSocketPolicy.MaxSessionIdLength ||
            normalized.Any(ch => ch < 0x20 || ch == 0x7F))
        {
            throw new InvalidDataException("Current-path signaling envelope sessionId is invalid.");
        }

        return normalized;
    }

    private static void ValidatePayloadForType(
        CurrentPathWebRtcSignalingMessageType type,
        CurrentPathWebRtcSignalingPayload? payload)
    {
        switch (type)
        {
            case CurrentPathWebRtcSignalingMessageType.Offer:
            case CurrentPathWebRtcSignalingMessageType.Answer:
                if (payload?.Sdp is null || payload.Sdp.Length == 0)
                {
                    throw new InvalidDataException("Current-path offer/answer signaling envelopes require non-empty SDP.");
                }

                break;
            case CurrentPathWebRtcSignalingMessageType.IceCandidate:
                if (payload?.Candidate is null || payload.Candidate.Length == 0)
                {
                    throw new InvalidDataException("Current-path ICE signaling envelopes require a non-empty candidate.");
                }

                break;
            case CurrentPathWebRtcSignalingMessageType.Join:
            case CurrentPathWebRtcSignalingMessageType.Leave:
                break;
            default:
                throw new InvalidDataException($"Unsupported current-path WebRTC signaling message type: {type}.");
        }
    }

    private static string RedactedOptional(string? value) =>
        string.IsNullOrEmpty(value) ? "null" : "<redacted>";

    private static string RedactedStableIdentifier(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "null";
        }

        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(value.Trim()));
        return "<sha256:" + Convert.ToHexString(digest.AsSpan(0, 6)).ToLowerInvariant() + ">";
    }
}

public sealed record CurrentPathSignalingServerFrame(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("error")] string? Error = null,
    [property: JsonPropertyName("sessionId")] string? SessionId = null,
    [property: JsonPropertyName("what")] string? What = null,
    [property: JsonPropertyName("role")] string? Role = null,
    [property: JsonPropertyName("clientId")] string? ClientId = null,
    [property: JsonPropertyName("reason")] string? Reason = null)
{
    public bool IsError =>
        string.Equals(Type, "error", StringComparison.Ordinal) && !string.IsNullOrWhiteSpace(Error);
}

public enum CurrentPathSignalingInboundMessageKind
{
    Envelope,
    ServerFrame,
    Unknown,
}

public sealed record CurrentPathSignalingInboundMessage(
    CurrentPathSignalingInboundMessageKind Kind,
    CurrentPathWebRtcSignalingEnvelope? Envelope,
    CurrentPathSignalingServerFrame? ServerFrame)
{
    public static CurrentPathSignalingInboundMessage FromEnvelope(CurrentPathWebRtcSignalingEnvelope envelope) =>
        new(CurrentPathSignalingInboundMessageKind.Envelope, envelope, null);

    public static CurrentPathSignalingInboundMessage FromServerFrame(CurrentPathSignalingServerFrame frame) =>
        new(CurrentPathSignalingInboundMessageKind.ServerFrame, null, frame);

    public static CurrentPathSignalingInboundMessage Unknown { get; } =
        new(CurrentPathSignalingInboundMessageKind.Unknown, null, null);
}

public static class CurrentPathSignalingFrameCodec
{
    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    public static string EncodeEnvelope(CurrentPathWebRtcSignalingEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        return JsonSerializer.Serialize(envelope, JsonOptions);
    }

    public static CurrentPathSignalingInboundMessage ParseInboundText(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new InvalidDataException("Current-path signaling text must not be empty.");
        }

        using var document = JsonDocument.Parse(text);
        if (LooksLikeWebRtcEnvelope(document.RootElement))
        {
            var envelope = JsonSerializer.Deserialize<CurrentPathWebRtcSignalingEnvelope>(text, JsonOptions)
                ?? throw new InvalidDataException("Current-path signaling envelope decoded to null.");
            return CurrentPathSignalingInboundMessage.FromEnvelope(envelope);
        }

        if (document.RootElement.ValueKind == JsonValueKind.Object &&
            document.RootElement.TryGetProperty("type", out var typeElement) &&
            typeElement.ValueKind == JsonValueKind.String)
        {
            var rawServerFrameType = typeElement.GetString() ?? string.Empty;
            if (rawServerFrameType is not ("bound" or "error"))
            {
                return CurrentPathSignalingInboundMessage.Unknown;
            }

            var frame = JsonSerializer.Deserialize<CurrentPathSignalingServerFrame>(text, JsonOptions)
                ?? throw new InvalidDataException("Current-path signaling server frame decoded to null.");
            return CurrentPathSignalingInboundMessage.FromServerFrame(frame);
        }

        return CurrentPathSignalingInboundMessage.Unknown;
    }

    public static CurrentPathWebRtcSignalingEnvelope DecodeEnvelope(string text)
    {
        var message = ParseInboundText(text);
        return message.Kind == CurrentPathSignalingInboundMessageKind.Envelope && message.Envelope is not null
            ? message.Envelope
            : throw new InvalidDataException("Current-path signaling text is not a WebRTC envelope.");
    }

    private static bool LooksLikeWebRtcEnvelope(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("sessionId", out var sessionId) ||
            !root.TryGetProperty("from", out var from) ||
            !root.TryGetProperty("type", out var type))
        {
            return false;
        }

        if (sessionId.ValueKind != JsonValueKind.String ||
            from.ValueKind != JsonValueKind.String ||
            type.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        var rawType = type.GetString() ?? string.Empty;
        return rawType is "join" or "offer" or "answer" or "iceCandidate" or "leave";
    }

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        };
        options.Converters.Add(new CurrentPathWebRtcSignalingMessageTypeJsonConverter());
        return options;
    }
}

public enum CurrentPathSignalingLifecyclePhase
{
    Idle,
    Connecting,
    SocketOpen,
    Bound,
    Closing,
    Closed,
    Failed,
}

public enum CurrentPathSignalingFailureClass
{
    AuthBindRejected,
    InvalidShardOrSessionMismatch,
    TokenExpired,
    TransientNetwork,
    TransientServer,
    ProtocolViolation,
}

public sealed record CurrentPathSignalingLifecycleEvent(
    CurrentPathSignalingLifecyclePhase Phase,
    int Generation,
    string? ServerFrameType = null,
    CurrentPathSignalingFailureClass? FailureClass = null,
    string? ErrorDescription = null,
    DateTimeOffset? OccurredAt = null);

public enum CurrentPathWebSocketReceiveKind
{
    Text,
    Binary,
    Close,
}

public sealed record CurrentPathWebSocketReceiveResult(
    CurrentPathWebSocketReceiveKind Kind,
    string? Text,
    int ByteCount,
    WebSocketCloseStatus? CloseStatus = null,
    string? CloseStatusDescription = null)
{
    public static CurrentPathWebSocketReceiveResult TextMessage(string text) =>
        new(CurrentPathWebSocketReceiveKind.Text, text, Encoding.UTF8.GetByteCount(text));

    public static CurrentPathWebSocketReceiveResult BinaryMessage(int byteCount) =>
        new(CurrentPathWebSocketReceiveKind.Binary, null, byteCount);

    public static CurrentPathWebSocketReceiveResult Closed(
        WebSocketCloseStatus closeStatus,
        string? closeStatusDescription = null) =>
        new(CurrentPathWebSocketReceiveKind.Close, null, 0, closeStatus, closeStatusDescription);
}

public interface ICurrentPathWebSocketTransport : IAsyncDisposable
{
    Task ConnectAsync(
        Uri uri,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken cancellationToken);

    Task SendTextAsync(string text, CancellationToken cancellationToken);

    Task<CurrentPathWebSocketReceiveResult> ReceiveAsync(
        int maxMessageBytes,
        CancellationToken cancellationToken);

    Task CloseAsync(CancellationToken cancellationToken);
}

public sealed class ClientWebSocketCurrentPathTransport : ICurrentPathWebSocketTransport
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly ClientWebSocket _webSocket = new();

    public async Task ConnectAsync(
        Uri uri,
        IReadOnlyDictionary<string, string> headers,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(uri);
        ArgumentNullException.ThrowIfNull(headers);
        foreach (var (name, value) in headers)
        {
            _webSocket.Options.SetRequestHeader(name, value);
        }

        await _webSocket.ConnectAsync(uri, cancellationToken).ConfigureAwait(false);
    }

    public async Task SendTextAsync(string text, CancellationToken cancellationToken)
    {
        if (_webSocket.State != WebSocketState.Open)
        {
            throw new InvalidOperationException($"Current-path WebSocket is not open: {_webSocket.State}.");
        }

        var data = StrictUtf8.GetBytes(text);
        await _webSocket.SendAsync(
                new ArraySegment<byte>(data),
                WebSocketMessageType.Text,
                endOfMessage: true,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<CurrentPathWebSocketReceiveResult> ReceiveAsync(
        int maxMessageBytes,
        CancellationToken cancellationToken)
    {
        if (maxMessageBytes <= 0)
        {
            throw new InvalidDataException("Current-path WebSocket max message bytes must be positive.");
        }

        var buffer = new byte[Math.Min(4096, maxMessageBytes)];
        using var stream = new MemoryStream();
        while (true)
        {
            var result = await _webSocket.ReceiveAsync(
                    new ArraySegment<byte>(buffer),
                    cancellationToken)
                .ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return CurrentPathWebSocketReceiveResult.Closed(
                    result.CloseStatus ?? WebSocketCloseStatus.Empty,
                    result.CloseStatusDescription);
            }

            if (result.MessageType != WebSocketMessageType.Text)
            {
                return CurrentPathWebSocketReceiveResult.BinaryMessage(result.Count);
            }

            if (stream.Length + result.Count > maxMessageBytes)
            {
                throw new InvalidDataException("Current-path WebSocket text message exceeded the configured byte limit.");
            }

            stream.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage)
            {
                continue;
            }

            try
            {
                return CurrentPathWebSocketReceiveResult.TextMessage(
                    StrictUtf8.GetString(stream.ToArray()));
            }
            catch (DecoderFallbackException ex)
            {
                throw new InvalidDataException("Current-path WebSocket text message is not valid UTF-8.", ex);
            }
        }
    }

    public async Task CloseAsync(CancellationToken cancellationToken)
    {
        if (_webSocket.State is WebSocketState.Open or WebSocketState.CloseReceived)
        {
            await _webSocket.CloseAsync(
                    WebSocketCloseStatus.NormalClosure,
                    "closed",
                    cancellationToken)
                .ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await CloseAsync(CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            _webSocket.Dispose();
        }
    }
}

public sealed class CurrentPathWebSocketSignalingClientOptions
{
    public const int DefaultMaxMessageBytes = 16 * 1024;

    public CurrentPathWebSocketSignalingClientOptions(
        string signalingServerOrigin,
        string wsPath,
        string sessionId,
        string sessionToken,
        string localDeviceId,
        string clientVersion = CurrentPathSignalServerClient.DefaultClientVersion,
        string protocolVersion = CurrentPathSignalServerClient.DefaultProtocolVersion,
        TimeSpan? connectTimeout = null,
        int maxMessageBytes = DefaultMaxMessageBytes)
    {
        var headers = CurrentPathSignalingWebSocketPolicy.BuildHeaderCredentials(
            sessionId,
            sessionToken,
            clientVersion,
            protocolVersion);
        WebSocketUri = CurrentPathSignalingWebSocketPolicy.BuildHeaderCredentialWebSocketUri(
            signalingServerOrigin,
            wsPath,
            sessionId,
            sessionToken,
            clientVersion,
            protocolVersion);
        Headers = headers;
        SessionId = headers[CurrentPathSignalingWebSocketPolicy.SessionIdHeader];
        LocalDeviceId = CurrentPathProtocolIdentityBinding.NormalizeDeviceId(localDeviceId);
        ClientVersion = clientVersion.Trim();
        ProtocolVersion = protocolVersion.Trim();
        ConnectTimeout = connectTimeout ?? TimeSpan.FromSeconds(30);
        if (ConnectTimeout <= TimeSpan.Zero)
        {
            throw new InvalidDataException("Current-path WebSocket connect timeout must be positive.");
        }

        if (maxMessageBytes <= 0 || maxMessageBytes > DefaultMaxMessageBytes)
        {
            throw new InvalidDataException($"Current-path WebSocket max message bytes must be between 1 and {DefaultMaxMessageBytes}.");
        }

        MaxMessageBytes = maxMessageBytes;
    }

    public Uri WebSocketUri { get; }

    public IReadOnlyDictionary<string, string> Headers { get; }

    public string SessionId { get; }

    public string LocalDeviceId { get; }

    public string ClientVersion { get; }

    public string ProtocolVersion { get; }

    public TimeSpan ConnectTimeout { get; }

    public int MaxMessageBytes { get; }
}

public sealed class CurrentPathWebSocketSignalingClient : IAsyncDisposable
{
    private const string RedactedServerError = "<redacted-server-error>";
    private readonly ICurrentPathWebSocketTransport _transport;
    private readonly CurrentPathWebSocketSignalingClientOptions _options;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private int _generation;

    public CurrentPathWebSocketSignalingClient(
        CurrentPathWebSocketSignalingClientOptions options)
        : this(new ClientWebSocketCurrentPathTransport(), options)
    {
    }

    public CurrentPathWebSocketSignalingClient(
        ICurrentPathWebSocketTransport transport,
        CurrentPathWebSocketSignalingClientOptions options)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public CurrentPathSignalingLifecyclePhase Phase { get; private set; } =
        CurrentPathSignalingLifecyclePhase.Idle;

    public bool IsBound => Phase == CurrentPathSignalingLifecyclePhase.Bound;

    public string? BoundRole { get; private set; }

    public string? BoundClientId { get; private set; }

    public event Action<CurrentPathSignalingLifecycleEvent>? LifecycleChanged;

    public async Task ConnectAndBindAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var generation = checked(++_generation);
        try
        {
            if (IsBound)
            {
                return;
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_options.ConnectTimeout);
            Emit(CurrentPathSignalingLifecyclePhase.Connecting, generation);
            try
            {
                await _transport.ConnectAsync(_options.WebSocketUri, _options.Headers, timeout.Token)
                    .ConfigureAwait(false);
                Emit(CurrentPathSignalingLifecyclePhase.SocketOpen, generation);
                while (true)
                {
                    var received = await _transport.ReceiveAsync(_options.MaxMessageBytes, timeout.Token)
                        .ConfigureAwait(false);
                    if (HandleBoundHandshakeMessage(received, generation))
                    {
                        return;
                    }
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    generation,
                    failureClass: CurrentPathSignalingFailureClass.TransientNetwork,
                    errorDescription: "<redacted-transport-error>");
                throw new CurrentPathWebSocketSignalingException(
                    "connect_timed_out",
                    CurrentPathSignalingFailureClass.TransientNetwork,
                    "Current-path WebSocket connect timed out.");
            }
            catch (Exception ex) when (ex is WebSocketException or IOException)
            {
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    generation,
                    failureClass: CurrentPathSignalingFailureClass.TransientNetwork,
                    errorDescription: "<redacted-transport-error>");
                throw new CurrentPathWebSocketSignalingException(
                    "transport_failed",
                    CurrentPathSignalingFailureClass.TransientNetwork,
                    "Current-path WebSocket transport failed.",
                    ex);
            }
            catch (JsonException ex)
            {
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    generation,
                    failureClass: CurrentPathSignalingFailureClass.ProtocolViolation,
                    errorDescription: "<redacted-protocol-error>");
                throw new CurrentPathWebSocketSignalingException(
                    "malformed_server_frame",
                    CurrentPathSignalingFailureClass.ProtocolViolation,
                    "Current-path WebSocket server frame is malformed.",
                    ex);
            }
            catch (InvalidDataException ex)
            {
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    generation,
                    failureClass: CurrentPathSignalingFailureClass.ProtocolViolation,
                    errorDescription: "<redacted-protocol-error>");
                throw new CurrentPathWebSocketSignalingException(
                    "protocol_violation",
                    CurrentPathSignalingFailureClass.ProtocolViolation,
                    ex.Message,
                    ex);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SendAsync(
        CurrentPathWebRtcSignalingEnvelope envelope,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        if (!IsBound)
        {
            throw new CurrentPathWebSocketSignalingException(
                "send_requires_bound",
                CurrentPathSignalingFailureClass.ProtocolViolation,
                "Current-path WebSocket must be bound before sending signaling envelopes.");
        }

        if (!string.Equals(envelope.SessionId, _options.SessionId, StringComparison.Ordinal) ||
            !string.Equals(envelope.From, _options.LocalDeviceId, StringComparison.Ordinal))
        {
            throw new CurrentPathWebSocketSignalingException(
                "envelope_scope_violation",
                CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                "Current-path WebSocket envelope scope does not match the bound session.");
        }

        await _transport.SendTextAsync(
                CurrentPathSignalingFrameCodec.EncodeEnvelope(envelope),
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<CurrentPathSignalingInboundMessage> ReceiveNextAsync(
        CancellationToken cancellationToken = default)
    {
        if (!IsBound)
        {
            throw new CurrentPathWebSocketSignalingException(
                "receive_requires_bound",
                CurrentPathSignalingFailureClass.ProtocolViolation,
                "Current-path WebSocket must be bound before receiving signaling envelopes.");
        }

        var received = await _transport.ReceiveAsync(_options.MaxMessageBytes, cancellationToken)
            .ConfigureAwait(false);
        if (received.Kind == CurrentPathWebSocketReceiveKind.Close)
        {
            Emit(
                CurrentPathSignalingLifecyclePhase.Closed,
                _generation,
                failureClass: CurrentPathSignalingFailureClass.TransientNetwork,
                errorDescription: "<redacted-transport-error>");
            throw new CurrentPathWebSocketSignalingException(
                "transport_closed",
                CurrentPathSignalingFailureClass.TransientNetwork,
                "Current-path WebSocket closed.");
        }

        if (received.Kind == CurrentPathWebSocketReceiveKind.Binary)
        {
            Emit(
                CurrentPathSignalingLifecyclePhase.Failed,
                _generation,
                failureClass: CurrentPathSignalingFailureClass.ProtocolViolation,
                errorDescription: "<redacted-protocol-error>");
            throw new CurrentPathWebSocketSignalingException(
                "binary_message_rejected",
                CurrentPathSignalingFailureClass.ProtocolViolation,
                "Current-path WebSocket signaling does not accept binary messages.");
        }

        var parsed = CurrentPathSignalingFrameCodec.ParseInboundText(received.Text ?? string.Empty);
        if (parsed.Kind == CurrentPathSignalingInboundMessageKind.Envelope && parsed.Envelope is not null)
        {
            if (!string.Equals(parsed.Envelope.SessionId, _options.SessionId, StringComparison.Ordinal))
            {
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    _generation,
                    failureClass: CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                    errorDescription: "<redacted-protocol-error>");
                throw new CurrentPathWebSocketSignalingException(
                    "inbound_session_scope_violation",
                    CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                    "Current-path inbound signaling envelope does not match the bound session.");
            }

            return parsed;
        }

        if (parsed.Kind == CurrentPathSignalingInboundMessageKind.ServerFrame && parsed.ServerFrame is not null)
        {
            HandleServerFrameAfterBound(parsed.ServerFrame);
            return parsed;
        }

        throw new CurrentPathWebSocketSignalingException(
            "unknown_message",
            CurrentPathSignalingFailureClass.ProtocolViolation,
            "Current-path WebSocket received an unknown signaling message.");
    }

    public async Task CloseAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (Phase is CurrentPathSignalingLifecyclePhase.Closed or CurrentPathSignalingLifecyclePhase.Idle)
            {
                return;
            }

            Emit(CurrentPathSignalingLifecyclePhase.Closing, _generation);
            await _transport.CloseAsync(cancellationToken).ConfigureAwait(false);
            Emit(CurrentPathSignalingLifecyclePhase.Closed, _generation);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await CloseAsync(CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            await _transport.DisposeAsync().ConfigureAwait(false);
            _gate.Dispose();
        }
    }

    private bool HandleBoundHandshakeMessage(
        CurrentPathWebSocketReceiveResult received,
        int generation)
    {
        if (received.Kind == CurrentPathWebSocketReceiveKind.Close)
        {
            var failureClass = ClassifyServerOrCloseReason(received.CloseStatusDescription);
            Emit(
                CurrentPathSignalingLifecyclePhase.Failed,
                generation,
                failureClass: failureClass,
                errorDescription: "<redacted-transport-error>");
            throw new CurrentPathWebSocketSignalingException(
                "closed_before_bound",
                failureClass,
                "Current-path WebSocket closed before server bind.");
        }

        if (received.Kind == CurrentPathWebSocketReceiveKind.Binary)
        {
            Emit(
                CurrentPathSignalingLifecyclePhase.Failed,
                generation,
                failureClass: CurrentPathSignalingFailureClass.ProtocolViolation,
                errorDescription: "<redacted-protocol-error>");
            throw new CurrentPathWebSocketSignalingException(
                "binary_message_rejected",
                CurrentPathSignalingFailureClass.ProtocolViolation,
                "Current-path WebSocket signaling does not accept binary messages.");
        }

        var parsed = CurrentPathSignalingFrameCodec.ParseInboundText(received.Text ?? string.Empty);
        if (parsed.Kind == CurrentPathSignalingInboundMessageKind.ServerFrame && parsed.ServerFrame is not null)
        {
            if (string.Equals(parsed.ServerFrame.Type, "bound", StringComparison.Ordinal))
            {
                var boundSessionId = CurrentPathWebRtcSignalingEnvelope.NormalizeSessionId(
                    parsed.ServerFrame.SessionId ?? string.Empty);
                if (!string.Equals(boundSessionId, _options.SessionId, StringComparison.Ordinal))
                {
                    Emit(
                        CurrentPathSignalingLifecyclePhase.Failed,
                        generation,
                        "bound",
                        CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                        "<redacted-protocol-error>");
                    throw new CurrentPathWebSocketSignalingException(
                        "bound_session_mismatch",
                        CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                        "Current-path WebSocket bound frame does not match the requested session.");
                }

                var role = parsed.ServerFrame.Role?.Trim();
                if (string.IsNullOrEmpty(role))
                {
                    throw new InvalidDataException("Current-path WebSocket bound frame is missing role.");
                }

                BoundRole = role;
                BoundClientId = string.IsNullOrWhiteSpace(parsed.ServerFrame.ClientId)
                    ? null
                    : parsed.ServerFrame.ClientId.Trim();
                Emit(CurrentPathSignalingLifecyclePhase.Bound, generation, "bound");
                return true;
            }

            if (parsed.ServerFrame.IsError)
            {
                var failureClass = ClassifyServerOrCloseReason(parsed.ServerFrame.Error ?? parsed.ServerFrame.Reason);
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    generation,
                    parsed.ServerFrame.Type,
                    failureClass,
                    RedactedServerError);
                throw new CurrentPathWebSocketSignalingException(
                    "server_rejected",
                    failureClass,
                    $"Current-path WebSocket server rejected bind: {RedactedServerError}.");
            }
        }

        Emit(
            CurrentPathSignalingLifecyclePhase.Failed,
            generation,
            failureClass: CurrentPathSignalingFailureClass.ProtocolViolation,
            errorDescription: "<redacted-protocol-error>");
        throw new CurrentPathWebSocketSignalingException(
            "unexpected_prebound_message",
            CurrentPathSignalingFailureClass.ProtocolViolation,
            "Current-path WebSocket received a business or unknown message before server bind.");
    }

    private void HandleServerFrameAfterBound(CurrentPathSignalingServerFrame frame)
    {
        if (frame.IsError)
        {
            var failureClass = ClassifyServerOrCloseReason(frame.Error ?? frame.Reason);
            Emit(
                CurrentPathSignalingLifecyclePhase.Failed,
                _generation,
                frame.Type,
                failureClass,
                RedactedServerError);
            throw new CurrentPathWebSocketSignalingException(
                "server_rejected",
                failureClass,
                $"Current-path WebSocket server rejected signaling message: {RedactedServerError}.");
        }

        if (!string.IsNullOrWhiteSpace(frame.SessionId))
        {
            var frameSessionId = CurrentPathWebRtcSignalingEnvelope.NormalizeSessionId(frame.SessionId);
            if (!string.Equals(frameSessionId, _options.SessionId, StringComparison.Ordinal))
            {
                Emit(
                    CurrentPathSignalingLifecyclePhase.Failed,
                    _generation,
                    frame.Type,
                    CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                    "<redacted-protocol-error>");
                throw new CurrentPathWebSocketSignalingException(
                    "server_frame_scope_violation",
                    CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch,
                    "Current-path WebSocket server frame does not match the bound session.");
            }
        }
    }

    private void Emit(
        CurrentPathSignalingLifecyclePhase phase,
        int generation,
        string? serverFrameType = null,
        CurrentPathSignalingFailureClass? failureClass = null,
        string? errorDescription = null)
    {
        Phase = phase;
        LifecycleChanged?.Invoke(new CurrentPathSignalingLifecycleEvent(
            phase,
            generation,
            serverFrameType,
            failureClass,
            errorDescription,
            DateTimeOffset.UtcNow));
    }

    public static CurrentPathSignalingFailureClass ClassifyServerOrCloseReason(string? reason)
    {
        var normalized = (reason ?? string.Empty).Trim().ToLowerInvariant();
        if (normalized.Contains("token", StringComparison.Ordinal) &&
            normalized.Contains("expired", StringComparison.Ordinal))
        {
            return CurrentPathSignalingFailureClass.TokenExpired;
        }

        if (normalized.Contains("auth", StringComparison.Ordinal) ||
            normalized.Contains("unauthorized", StringComparison.Ordinal) ||
            normalized.Contains("forbidden", StringComparison.Ordinal) ||
            normalized.Contains("bind_rejected", StringComparison.Ordinal))
        {
            return CurrentPathSignalingFailureClass.AuthBindRejected;
        }

        if (normalized.Contains("invalid shard", StringComparison.Ordinal) ||
            normalized.Contains("invalid session", StringComparison.Ordinal) ||
            normalized.Contains("session mismatch", StringComparison.Ordinal) ||
            normalized.Contains("scope_mismatch", StringComparison.Ordinal) ||
            normalized.Contains("scope_violation", StringComparison.Ordinal) ||
            normalized.Contains("unknown shard", StringComparison.Ordinal) ||
            normalized.Contains("room_full", StringComparison.Ordinal))
        {
            return CurrentPathSignalingFailureClass.InvalidShardOrSessionMismatch;
        }

        if (normalized.Contains("protocol", StringComparison.Ordinal) ||
            normalized.Contains("malformed", StringComparison.Ordinal) ||
            normalized.Contains("bad_json", StringComparison.Ordinal) ||
            normalized.Contains("bad_envelope", StringComparison.Ordinal))
        {
            return CurrentPathSignalingFailureClass.ProtocolViolation;
        }

        return CurrentPathSignalingFailureClass.TransientServer;
    }
}

public sealed class CurrentPathWebSocketSignalingException : Exception
{
    public CurrentPathWebSocketSignalingException(
        string errorCode,
        CurrentPathSignalingFailureClass failureClass,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
        FailureClass = failureClass;
    }

    public string ErrorCode { get; }

    public CurrentPathSignalingFailureClass FailureClass { get; }
}

public sealed class CurrentPathSignalServerException : Exception
{
    public CurrentPathSignalServerException(string message, HttpStatusCode statusCode)
        : base($"Current-path signal server rejected request ({(int)statusCode}): {message}")
    {
        StatusCode = statusCode;
        SanitizedBody = message;
    }

    public HttpStatusCode StatusCode { get; }

    public string SanitizedBody { get; }

    public static string SanitizeServerRejectedBody(ReadOnlySpan<byte> data)
    {
        var redactedSummary = $"<redacted-server-error-body> bytes={data.Length.ToString(CultureInfo.InvariantCulture)}";
        try
        {
            using var document = JsonDocument.Parse(data.ToArray());
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return redactedSummary;
            }

            var summary = new SortedDictionary<string, object>(StringComparer.Ordinal)
            {
                ["bodyBytes"] = data.Length,
            };
            AddKnownErrorCode(document.RootElement, summary, "code");
            AddKnownErrorCode(document.RootElement, summary, "error");
            AddRedactedMarker(document.RootElement, summary, "reason");
            AddRedactedMarker(document.RootElement, summary, "rejectReason");
            AddSafeFingerprint(document.RootElement, summary, "serverBuildFingerprint");
            if (summary.Count == 1)
            {
                return redactedSummary;
            }

            return JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = false });
        }
        catch (JsonException)
        {
            return redactedSummary;
        }
    }

    private static void AddKnownErrorCode(
        JsonElement root,
        IDictionary<string, object> summary,
        string key)
    {
        if (!root.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return;
        }

        var text = value.GetString()?.Trim() ?? string.Empty;
        if (IsKnownServerErrorCode(text))
        {
            summary[key] = text;
        }
        else if (!string.IsNullOrEmpty(text))
        {
            summary[key] = "<redacted-untrusted-error-code>";
        }
    }

    private static void AddRedactedMarker(
        JsonElement root,
        IDictionary<string, object> summary,
        string key)
    {
        if (root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String)
        {
            summary[key] = "<redacted>";
        }
    }

    private static void AddSafeFingerprint(
        JsonElement root,
        IDictionary<string, object> summary,
        string key)
    {
        if (!root.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return;
        }

        var text = value.GetString()?.Trim() ?? string.Empty;
        if (CurrentPathProtocolIdentityBinding.IsLowerHex(text, 64))
        {
            summary[key] = text;
        }
        else if (!string.IsNullOrEmpty(text))
        {
            summary[key] = "<redacted-untrusted-fingerprint>";
        }
    }

    private static bool IsKnownServerErrorCode(string value) =>
        value is
            "admission_expired" or
            "admission_required" or
            "auth_rejected" or
            "bad_envelope" or
            "bad_json" or
            "bind_rejected" or
            "forbidden" or
            "invalid_admission" or
            "invalid_request" or
            "invalid_session" or
            "missing_bearer_token" or
            "missing_tenant_id" or
            "not_found" or
            "rate_limited" or
            "room_full" or
            "scope_mismatch" or
            "scope_violation" or
            "server_error" or
            "session_token_expired" or
            "token_expired" or
            "unauthorized" or
            "unknown_shard";
}
