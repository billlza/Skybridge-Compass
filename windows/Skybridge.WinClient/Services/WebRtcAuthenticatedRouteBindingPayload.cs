using System;
using System.Linq;
using System.Text.Json;

namespace Skybridge.WinClient.Services;

public sealed class WebRtcAuthenticatedRouteBindingException : InvalidOperationException
{
    public WebRtcAuthenticatedRouteBindingException(string message)
        : base(message)
    {
    }

    public WebRtcAuthenticatedRouteBindingException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed record WebRtcAuthenticatedRouteBindingPayload(
    int Version,
    string Kind,
    string ServiceType,
    string InstanceName,
    string HostName,
    ushort Port,
    string EndpointProvenance,
    string LocalDeviceId,
    string RemoteDeviceId,
    string RouteAuthorityProtocolPublicKeyFingerprint,
    string RemoteProtocolPublicKeyFingerprint,
    string SessionHashHex,
    string TranscriptPrefixHex,
    double SentAt,
    double ExpiresAt,
    byte[] Nonce);

public static class WebRtcAuthenticatedRouteBindingCodec
{
    public const string MessageType = "authenticatedRouteBinding";
    public const int CurrentVersion = 1;
    public const string ResolvedDnsSdEndpointProvenance = "resolved-dns-sd-endpoint";

    public static WebRtcAuthenticatedRouteBindingPayload Decode(ReadOnlySpan<byte> payload)
    {
        try
        {
            using var document = JsonDocument.Parse(payload.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new WebRtcAuthenticatedRouteBindingException(
                    "Authenticated route-binding AppControl payload must be a JSON object.");
            }

            if (root.EnumerateObject().Count() != 1 ||
                !root.TryGetProperty(MessageType, out var binding))
            {
                throw new WebRtcAuthenticatedRouteBindingException(
                    "Authenticated route-binding AppControl payload must have exactly one authenticatedRouteBinding object.");
            }

            if (binding.ValueKind != JsonValueKind.Object)
            {
                throw new WebRtcAuthenticatedRouteBindingException(
                    "authenticatedRouteBinding payload must be a JSON object.");
            }

            var sourceServiceType = RequireNonEmptyString(binding, "serviceType");
            if (!SkyBridgeProtocolConstants.TryCanonicalizeDnsSdServiceType(
                sourceServiceType,
                out var canonicalServiceType))
            {
                throw new WebRtcAuthenticatedRouteBindingException(
                    "Authenticated route-binding serviceType is not a recognized SkyBridge DNS-SD service.");
            }
            var sourceInstanceName = RequireNonEmptyString(binding, "instanceName");
            var canonicalInstanceName = SkyBridgeProtocolConstants.CanonicalizeDnsSdInstanceName(
                sourceInstanceName,
                sourceServiceType,
                canonicalServiceType);

            var decoded = new WebRtcAuthenticatedRouteBindingPayload(
                RequireInt(binding, "version"),
                RequireNonEmptyString(binding, "kind"),
                canonicalServiceType,
                canonicalInstanceName,
                RequireNonEmptyString(binding, "hostName"),
                RequirePort(binding),
                RequireNonEmptyString(binding, "endpointProvenance"),
                RequireNonEmptyString(binding, "localDeviceId"),
                RequireNonEmptyString(binding, "remoteDeviceId"),
                RequireLowerHex(binding, "routeAuthorityProtocolPublicKeyFingerprint", 64),
                RequireLowerHex(binding, "remoteProtocolPublicKeyFingerprint", 64),
                RequireLowerHex(binding, "sessionHashHex", 16),
                RequireLowerHex(binding, "transcriptPrefixHex", 16),
                RequireDouble(binding, "sentAt"),
                RequireDouble(binding, "expiresAt"),
                RequireNonce(binding));
            Validate(decoded);
            return decoded;
        }
        catch (JsonException ex)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding AppControl payload is malformed JSON.",
                ex);
        }
    }

    private static void Validate(WebRtcAuthenticatedRouteBindingPayload payload)
    {
        if (payload.Version != CurrentVersion)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                $"Authenticated route-binding version {payload.Version} is unsupported.");
        }

        if (!string.Equals(payload.Kind, "fileTransfer", StringComparison.Ordinal) &&
            !string.Equals(payload.Kind, "remoteDesktop", StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding kind must be fileTransfer or remoteDesktop.");
        }

        var expectedServiceType = payload.Kind switch
        {
            "fileTransfer" => SkyBridgeProtocolConstants.FileTransferDnsSdService,
            "remoteDesktop" => SkyBridgeProtocolConstants.RemoteDesktopDnsSdService,
            _ => throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding kind is unsupported.")
        };
        if (!string.Equals(payload.ServiceType, expectedServiceType, StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding serviceType does not match its action kind.");
        }

        if (!string.Equals(payload.EndpointProvenance, ResolvedDnsSdEndpointProvenance, StringComparison.Ordinal))
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding endpointProvenance must be resolved-dns-sd-endpoint.");
        }

        if (payload.ExpiresAt <= payload.SentAt)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding expiresAt must be later than sentAt.");
        }

        if (payload.Nonce.Length < 16)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding nonce must be at least 16 bytes.");
        }
    }

    private static int RequireInt(JsonElement obj, string propertyName)
    {
        if (!obj.TryGetProperty(propertyName, out var value) ||
            value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt32(out var parsed))
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                $"Authenticated route-binding {propertyName} must be an integer.");
        }

        return parsed;
    }

    private static double RequireDouble(JsonElement obj, string propertyName)
    {
        if (!obj.TryGetProperty(propertyName, out var value) ||
            value.ValueKind != JsonValueKind.Number ||
            !value.TryGetDouble(out var parsed) ||
            double.IsNaN(parsed) ||
            double.IsInfinity(parsed))
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                $"Authenticated route-binding {propertyName} must be a finite number.");
        }

        return parsed;
    }

    private static string RequireNonEmptyString(JsonElement obj, string propertyName)
    {
        if (!obj.TryGetProperty(propertyName, out var value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                $"Authenticated route-binding {propertyName} must be a string.");
        }

        var parsed = value.GetString()?.Trim() ?? "";
        if (parsed.Length == 0)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                $"Authenticated route-binding {propertyName} must not be empty.");
        }

        return parsed;
    }

    private static ushort RequirePort(JsonElement obj)
    {
        var port = RequireInt(obj, "port");
        if (port is < 1 or > ushort.MaxValue)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding port must be between 1 and 65535.");
        }

        return (ushort)port;
    }

    private static string RequireLowerHex(JsonElement obj, string propertyName, int length)
    {
        var parsed = RequireNonEmptyString(obj, propertyName);
        if (parsed.Length != length)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                $"Authenticated route-binding {propertyName} must be {length} lowercase hex characters.");
        }

        foreach (var c in parsed)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            {
                throw new WebRtcAuthenticatedRouteBindingException(
                    $"Authenticated route-binding {propertyName} must be lowercase hex.");
            }
        }

        return parsed;
    }

    private static byte[] RequireNonce(JsonElement obj)
    {
        if (!obj.TryGetProperty("nonce", out var value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding nonce must be a base64 string.");
        }

        try
        {
            return Convert.FromBase64String(value.GetString() ?? "");
        }
        catch (FormatException ex)
        {
            throw new WebRtcAuthenticatedRouteBindingException(
                "Authenticated route-binding nonce must be valid base64.",
                ex);
        }
    }
}
