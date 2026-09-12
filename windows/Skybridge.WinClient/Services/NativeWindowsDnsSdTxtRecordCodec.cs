using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Skybridge.WinClient.Services;

internal static class NativeWindowsDnsSdTxtRecordCodec
{
    internal const int MaxTxtRecordBytes = 4096;
    internal const int MaxTxtKeyBytes = 64;
    internal const int MaxTxtValueBytes = 1024;
    internal const int MaxTxtProperties = 64;

    public static bool TrySerialize(
        IReadOnlyList<KeyValuePair<string, string>> properties,
        out string txtRecord,
        out string error)
    {
        ArgumentNullException.ThrowIfNull(properties);

        txtRecord = "";
        error = "";
        if (properties.Count == 0)
        {
            return true;
        }

        if (properties.Count > MaxTxtProperties)
        {
            error = $"DNS-SD TXT property count exceeds {MaxTxtProperties}.";
            return false;
        }

        var seenKeys = new HashSet<string>(StringComparer.Ordinal);
        var parts = new List<string>(properties.Count);
        foreach (var property in properties)
        {
            var key = property.Key ?? "";
            var trimmedKey = key.Trim();
            if (key.Length == 0)
            {
                error = "DNS-SD TXT key is empty.";
                return false;
            }

            if (!StringComparer.Ordinal.Equals(key, trimmedKey))
            {
                error = $"DNS-SD TXT key '{trimmedKey}' contains leading or trailing whitespace.";
                return false;
            }

            if (Encoding.UTF8.GetByteCount(key) > MaxTxtKeyBytes)
            {
                error = $"DNS-SD TXT key '{key}' exceeds {MaxTxtKeyBytes} bytes.";
                return false;
            }

            if (ContainsTxtKeySeparatorOrControl(key))
            {
                error = $"DNS-SD TXT key '{key}' contains a separator or control character.";
                return false;
            }

            if (!seenKeys.Add(key))
            {
                error = $"DNS-SD TXT key '{key}' is duplicated.";
                return false;
            }

            var value = property.Value ?? "";
            if (Encoding.UTF8.GetByteCount(value) > MaxTxtValueBytes)
            {
                error = $"DNS-SD TXT value for '{key}' exceeds {MaxTxtValueBytes} bytes.";
                return false;
            }

            if (ContainsTxtValueSeparatorOrControl(value))
            {
                error = $"DNS-SD TXT value for '{key}' contains a separator or control character.";
                return false;
            }

            parts.Add($"{key}={value}");
        }

        var serialized = string.Join(";", parts);
        if (Encoding.UTF8.GetByteCount(serialized) > MaxTxtRecordBytes)
        {
            error = $"DNS-SD TXT record exceeds {MaxTxtRecordBytes} bytes.";
            return false;
        }

        txtRecord = serialized;
        return true;
    }

    private static bool ContainsTxtKeySeparatorOrControl(string value) =>
        value.Any(character => (character is ';' or '=') || char.IsControl(character));

    private static bool ContainsTxtValueSeparatorOrControl(string value) =>
        value.Any(character => character == ';' || char.IsControl(character));
}
