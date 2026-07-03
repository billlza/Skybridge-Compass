namespace Skybridge.WinClient.Services;

internal static class CrossNetworkConnectionCodePolicy
{
    public const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    public const int LegacyConnectionCodeLength = 6;
    public const int PreferredConnectionCodeLength = 8;
    public const int MaximumConnectionCodeLength = 16;
    public const string SupportedLengthDescription = "6 or 8-16";

    public static string Sanitize(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return string.Empty;
        }

        var normalized = new char[MaximumConnectionCodeLength];
        var count = 0;
        foreach (var current in raw.ToUpperInvariant())
        {
            if (Alphabet.IndexOf(current) < 0)
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

    public static bool IsSupportedLength(int length) =>
        length == LegacyConnectionCodeLength ||
        length >= PreferredConnectionCodeLength && length <= MaximumConnectionCodeLength;

    public static bool TryNormalize(string? raw, out string code)
    {
        code = Sanitize(raw);
        return IsSupportedLength(code.Length);
    }

    public static string BuildInvalidMessage(string subject) =>
        $"{subject} must be {SupportedLengthDescription} characters from {Alphabet}.";
}
