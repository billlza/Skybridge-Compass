using System;
using System.IO;
using System.Linq;
using System.Net;

namespace Skybridge.WinClient.Services;

/// <summary>Pure product identity normalization shared by discovery and authenticated transports.</summary>
internal static class ProductDeviceIdentity
{
    internal static string CanonicalDeviceId(string deviceId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);
        var normalized = deviceId.Trim().ToLowerInvariant();
        if (normalized.StartsWith("id:", StringComparison.Ordinal)) { normalized = normalized[3..]; }
        if (normalized.Length is < 8 or > 128 || IPAddress.TryParse(normalized, out _) ||
            normalized.Any(value => !((value >= 'a' && value <= 'z') || (value >= '0' && value <= '9') || value is '-' or '_' or '.')))
        {
            throw new InvalidDataException("Remote-control identity must be a stable device ID, not an endpoint alias.");
        }
        return "id:" + normalized;
    }
}
