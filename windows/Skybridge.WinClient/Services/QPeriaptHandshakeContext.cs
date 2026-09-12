using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Skybridge.WinClient.Services;

internal static class QPeriaptHandshakeContext
{
    internal static byte[] Encode(byte version, ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> recipientPublicKey, WebRtcProductHandshakePolicy policy,
        IReadOnlyList<ushort> offeredSuites, WebRtcProductCryptoCapabilities capabilities,
        ReadOnlySpan<byte> identityPublicKey, ReadOnlySpan<byte> extensions)
    {
        if (clientNonce.Length != 32 || recipientPublicKey.Length != QPeriaptKeyEncoding.PublicLength)
        { throw new WebRtcProductHandshakeCodecException("Invalid Q-Periapt pre-KEM version, nonce, or recipient key."); }
        if (offeredSuites.Count is < 1 or > 8 || offeredSuites.Distinct().Count() != offeredSuites.Count ||
            !offeredSuites.Contains(WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound) ||
            offeredSuites.Any(suite => !WebRtcProductHandshakeCodec.IsKnownSuite(suite) || suite == WebRtcProductHandshakeCodec.SuiteQPeriaptContextBound))
        { throw new WebRtcProductHandshakeCodecException("Non-canonical Q-Periapt pre-KEM suite offer."); }
        using var output = new MemoryStream();
        Field(output, "skybridge/qperiapt/abi2/message-a-kem/v1"u8);
        output.WriteByte(version);
        Span<byte> suiteBytes = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(suiteBytes, WebRtcProductHandshakeCodec.SuiteQPeriaptPolicyBound);
        output.Write(suiteBytes);
        Field(output, clientNonce); Field(output, policy.Encode());
        var suites = new byte[offeredSuites.Count * 2];
        for (var index = 0; index < offeredSuites.Count; index++)
        { BinaryPrimitives.WriteUInt16BigEndian(suites.AsSpan(index * 2, 2), offeredSuites[index]); }
        Field(output, suites); Field(output, capabilities.Encode()); Field(output, identityPublicKey);
        Field(output, extensions); Field(output, recipientPublicKey);
        return output.ToArray();
    }

    private static void Field(Stream output, ReadOnlySpan<byte> bytes)
    {
        if (output.Length + 4 + bytes.Length > QPeriaptNativeClient.MaximumContextLength)
        { throw new WebRtcProductHandshakeCodecException("Q-Periapt pre-KEM context exceeds 65536 bytes."); }
        Span<byte> length = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(length, checked((uint)bytes.Length));
        output.Write(length); output.Write(bytes);
    }
}

internal static class QPeriaptPeerPlatform
{
    internal const string KemCapability = "Q-Periapt-ABI2-PolicyBound";
    internal const string ProviderType = "Q-Periapt-ContextBound";
    private const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking;
    private static readonly Regex WordSpacing = new(@"[ \t\r\n\f\v]+", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex Windows = new(@"\AWindows 10\.0\.([1-9][0-9]*)\z", Options);
    private static readonly Regex Apple = new(@"\A(?:ios|macos|mac\s+os) ([0-9]{1,3})(?:\.[0-9]{1,3}){0,2}\z", Options);
    private static readonly Regex Android = new(@"\AAndroid ([0-9]{1,3})(?:\.[0-9]{1,3}){0,2} (?:API\s*([0-9]{1,3})|\(\s*API\s*([0-9]{1,3})\s*\))\z", Options);
    private static readonly Regex Ubuntu = new(@"\AUbuntu ([1-9][0-9]{0,2})\.([0-9]{2})(?:\.(0|[1-9][0-9]{0,2}))?\z", Options);

    internal static string LocalVersion()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041) || !MLDsa.IsSupported || !MLKem.IsSupported)
        { throw new PlatformNotSupportedException("Q-Periapt product admission requires supported Windows and native ML-DSA-65/ML-KEM-768."); }
        var version = Environment.OSVersion.Version;
        var text = FormattableString.Invariant($"Windows {version.Major}.{version.Minor}.{version.Build}");
        if (!IsEligible(text)) { throw new PlatformNotSupportedException("The Windows kernel version is outside the Q-Periapt product contract."); }
        return text;
    }

    internal static bool IsEligible(string? version)
    {
        if (string.IsNullOrWhiteSpace(version) || version.Length > 128 || version.Any(character => !char.IsAscii(character))) { return false; }
        var value = WordSpacing.Replace(version.Trim(), " ");
        var windows = Windows.Match(value);
        if (windows.Success) { return Integer(windows.Groups[1].Value, out var build) && build >= 19041; }
        var apple = Apple.Match(value);
        if (apple.Success) { return Integer(apple.Groups[1].Value, out var major) && major >= 26; }
        var android = Android.Match(value);
        if (android.Success)
        {
            var api = android.Groups[2].Success ? android.Groups[2].Value : android.Groups[3].Value;
            return Integer(android.Groups[1].Value, out var release) && release >= 16 && Integer(api, out var level) && level >= 36;
        }
        var ubuntu = Ubuntu.Match(value);
        return ubuntu.Success && Integer(ubuntu.Groups[1].Value, out var year) &&
            Integer(ubuntu.Groups[2].Value, out var month) && month is >= 1 and <= 12 &&
            (!ubuntu.Groups[3].Success || Integer(ubuntu.Groups[3].Value, out _)) && (year > 24 || year == 24 && month >= 4);
    }

    internal static void RequireCapabilities(WebRtcProductCryptoCapabilities capabilities, QPeriaptRuntimeSession session)
    {
        if (!capabilities.PqcAvailable || capabilities.ProviderType != ProviderType || !IsEligible(capabilities.PlatformVersion) ||
            !capabilities.SupportedKem.Contains(KemCapability, StringComparer.Ordinal) ||
            !capabilities.SupportedSignature.Contains("ML-DSA-65", StringComparer.Ordinal) ||
            !capabilities.SupportedAead.Contains("AES-256-GCM", StringComparer.Ordinal) ||
            !capabilities.SupportedAuthProfiles.Contains(session.AuthProfile, StringComparer.Ordinal))
        { throw new WebRtcProductHandshakeCodecException("Q-Periapt peer capabilities require the exact policy identity, algorithms, provider, and supported platform."); }
    }

    private static bool Integer(string value, out int parsed) => int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed);
}
