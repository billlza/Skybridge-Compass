using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

public enum WebRtcProductHandshakeFinishedDirection : byte
{
    ResponderToInitiator = 0x01,
    InitiatorToResponder = 0x02,
}

public sealed class WebRtcProductHandshakeCodecException : Exception
{
    public WebRtcProductHandshakeCodecException(string message)
        : base(message)
    {
    }

    public WebRtcProductHandshakeCodecException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class WebRtcProductHandshakeKeyShare
{
    public WebRtcProductHandshakeKeyShare(ushort suiteWireId, ReadOnlyMemory<byte> shareBytes)
    {
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
        WebRtcProductHandshakeCodec.ValidateKeyShareLength(suiteWireId, shareBytes.Length);
        SuiteWireId = suiteWireId;
        ShareBytes = shareBytes.ToArray();
    }

    public ushort SuiteWireId { get; }

    public ReadOnlyMemory<byte> ShareBytes { get; }
}

public sealed class WebRtcProductCryptoCapabilities
{
    public WebRtcProductCryptoCapabilities(
        IReadOnlyList<string> supportedKem,
        IReadOnlyList<string> supportedSignature,
        IReadOnlyList<string> supportedAuthProfiles,
        IReadOnlyList<string> supportedAead,
        bool pqcAvailable,
        string platformVersion,
        string providerType)
    {
        SupportedKem = CopyStrings(supportedKem, nameof(supportedKem));
        SupportedSignature = CopyStrings(supportedSignature, nameof(supportedSignature));
        SupportedAuthProfiles = CopyStrings(supportedAuthProfiles, nameof(supportedAuthProfiles));
        SupportedAead = CopyStrings(supportedAead, nameof(supportedAead));
        PqcAvailable = pqcAvailable;
        PlatformVersion = RequireNonNull(platformVersion, nameof(platformVersion));
        ProviderType = RequireProviderType(providerType);
    }

    public IReadOnlyList<string> SupportedKem { get; }

    public IReadOnlyList<string> SupportedSignature { get; }

    public IReadOnlyList<string> SupportedAuthProfiles { get; }

    public IReadOnlyList<string> SupportedAead { get; }

    public bool PqcAvailable { get; }

    public string PlatformVersion { get; }

    public string ProviderType { get; }

    public byte[] Encode()
    {
        using var output = new MemoryStream();
        DeterministicEncoding.WriteStringArray(output, SupportedKem);
        DeterministicEncoding.WriteStringArray(output, SupportedSignature);
        DeterministicEncoding.WriteStringArray(output, SupportedAuthProfiles);
        DeterministicEncoding.WriteStringArray(output, SupportedAead);
        output.WriteByte(PqcAvailable ? (byte)0x01 : (byte)0x00);
        DeterministicEncoding.WriteString(output, PlatformVersion);
        DeterministicEncoding.WriteString(output, ProviderType);
        return output.ToArray();
    }

    public static WebRtcProductCryptoCapabilities Decode(ReadOnlySpan<byte> bytes)
    {
        var reader = new DeterministicEncoding.Reader(bytes);
        var capabilities = new WebRtcProductCryptoCapabilities(
            reader.ReadStringArray(),
            reader.ReadStringArray(),
            reader.ReadStringArray(),
            reader.ReadStringArray(),
            reader.ReadBoolean(),
            reader.ReadString(),
            reader.ReadString());
        reader.RequireAtEnd("CryptoCapabilities");
        return capabilities;
    }

    private static IReadOnlyList<string> CopyStrings(IReadOnlyList<string> values, string parameterName)
    {
        ArgumentNullException.ThrowIfNull(values, parameterName);
        var copy = new string[values.Count];
        for (var index = 0; index < values.Count; index++)
        {
            copy[index] = RequireNonNull(values[index], parameterName);
        }

        return Array.AsReadOnly(copy);
    }

    private static string RequireNonNull(string value, string parameterName) =>
        value ?? throw new ArgumentNullException(parameterName);

    private static string RequireProviderType(string providerType)
    {
        providerType = RequireNonNull(providerType, nameof(providerType));
        return providerType switch
        {
            "Q-Periapt-ContextBound" => providerType,
            "CryptoKit-PQC" => providerType,
            "liboqs" => providerType,
            "SwiftCrypto" => providerType,
            "CryptoKit-Classic" => providerType,
            _ => throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product handshake providerType='{providerType}'.")
        };
    }
}

public sealed class WebRtcProductHandshakePolicy
{
    public WebRtcProductHandshakePolicy(
        bool requirePqc,
        bool allowClassicFallback,
        string minimumTier,
        bool requireSecureEnclavePoP)
    {
        RequirePqc = requirePqc;
        AllowClassicFallback = requirePqc ? false : allowClassicFallback;
        MinimumTier = RequireMinimumTier(minimumTier);
        RequireSecureEnclavePoP = requireSecureEnclavePoP;
    }

    public static WebRtcProductHandshakePolicy Default { get; } =
        new(requirePqc: false, allowClassicFallback: true, minimumTier: "classic", requireSecureEnclavePoP: false);

    public bool RequirePqc { get; }

    public bool AllowClassicFallback { get; }

    public string MinimumTier { get; }

    public bool RequireSecureEnclavePoP { get; }

    public byte[] Encode()
    {
        using var output = new MemoryStream();
        output.WriteByte(RequirePqc ? (byte)0x01 : (byte)0x00);
        output.WriteByte(AllowClassicFallback ? (byte)0x01 : (byte)0x00);
        DeterministicEncoding.WriteString(output, MinimumTier);
        output.WriteByte(RequireSecureEnclavePoP ? (byte)0x01 : (byte)0x00);
        return output.ToArray();
    }

    public static WebRtcProductHandshakePolicy Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty)
        {
            return Default;
        }

        var reader = new DeterministicEncoding.Reader(bytes);
        var policy = new WebRtcProductHandshakePolicy(
            reader.ReadBoolean(),
            reader.ReadBoolean(),
            reader.ReadString(),
            reader.IsAtEnd ? false : reader.ReadBoolean());
        reader.RequireAtEnd("HandshakePolicy");
        return policy;
    }

    private static string RequireMinimumTier(string minimumTier)
    {
        ArgumentNullException.ThrowIfNull(minimumTier);
        return minimumTier switch
        {
            "qperiaptPQC" => minimumTier,
            "nativePQC" => minimumTier,
            "liboqsPQC" => minimumTier,
            "classic" => minimumTier,
            _ => throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product handshake minimumTier='{minimumTier}'.")
        };
    }
}

public sealed class WebRtcProductHpkeSealedBox
{
    public WebRtcProductHpkeSealedBox(
        ushort suiteWireId,
        ReadOnlyMemory<byte> encapsulatedKey,
        ReadOnlyMemory<byte> nonce,
        ReadOnlyMemory<byte> ciphertext,
        ReadOnlyMemory<byte> tag)
    {
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
        ValidateSealedBoxParts(encapsulatedKey.Length, nonce.Length, ciphertext.Length, tag.Length);
        SuiteWireId = suiteWireId;
        EncapsulatedKey = encapsulatedKey.ToArray();
        Nonce = nonce.ToArray();
        Ciphertext = ciphertext.ToArray();
        Tag = tag.ToArray();
    }

    public ushort SuiteWireId { get; }

    public ReadOnlyMemory<byte> EncapsulatedKey { get; }

    public ReadOnlyMemory<byte> Nonce { get; }

    public ReadOnlyMemory<byte> Ciphertext { get; }

    public ReadOnlyMemory<byte> Tag { get; }

    public byte[] Encode(ushort selectedSuiteWireId)
    {
        if (selectedSuiteWireId != SuiteWireId)
        {
            throw new WebRtcProductHandshakeCodecException(
                "HPKE sealed-box suite does not match the selected handshake suite.");
        }

        using var output = new MemoryStream();
        output.Write(WebRtcProductHandshakeCodec.HpkeMagicBytes);
        output.WriteByte(Nonce.Length == WebRtcProductHandshakeCodec.HpkeNonceLength &&
            Tag.Length == WebRtcProductHandshakeCodec.HpkeTagLength
                ? (byte)1
                : (byte)2);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, SuiteWireId);
        output.WriteByte(0);
        output.WriteByte(0);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)EncapsulatedKey.Length));
        output.WriteByte(checked((byte)Nonce.Length));
        output.WriteByte(checked((byte)Tag.Length));
        WebRtcProductHandshakeCodec.WriteUInt32LE(output, checked((uint)Ciphertext.Length));
        output.Write(EncapsulatedKey.Span);
        output.Write(Nonce.Span);
        output.Write(Ciphertext.Span);
        output.Write(Tag.Span);
        return output.ToArray();
    }

    public static WebRtcProductHpkeSealedBox Decode(ReadOnlySpan<byte> combined)
    {
        if (combined.Length < WebRtcProductHandshakeCodec.HpkeHeaderLength)
        {
            throw new WebRtcProductHandshakeCodecException("HPKE sealed box is too short.");
        }

        if (!combined[..4].SequenceEqual(WebRtcProductHandshakeCodec.HpkeMagicBytes))
        {
            throw new WebRtcProductHandshakeCodecException("HPKE sealed box magic mismatch.");
        }

        var version = combined[4];
        if (version is not 1 and not 2)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported HPKE sealed box version={version}.");
        }

        var suiteWireId = WebRtcProductHandshakeCodec.ReadUInt16LE(combined[5..7]);
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
        var encLen = WebRtcProductHandshakeCodec.ReadUInt16LE(combined[9..11]);
        var nonceLen = combined[11];
        var tagLen = combined[12];
        var ctLen = WebRtcProductHandshakeCodec.ReadUInt32LE(combined[13..17]);
        ValidateSealedBoxHeader(version, encLen, nonceLen, ctLen, tagLen);

        var expectedLength = checked(WebRtcProductHandshakeCodec.HpkeHeaderLength + encLen + nonceLen + (int)ctLen + tagLen);
        if (combined.Length != expectedLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"HPKE sealed box length mismatch expected={expectedLength} actual={combined.Length}.");
        }

        var offset = WebRtcProductHandshakeCodec.HpkeHeaderLength;
        var encapsulatedKey = combined.Slice(offset, encLen).ToArray();
        offset += encLen;
        var nonce = combined.Slice(offset, nonceLen).ToArray();
        offset += nonceLen;
        var ciphertext = combined.Slice(offset, checked((int)ctLen)).ToArray();
        offset += checked((int)ctLen);
        var tag = combined.Slice(offset, tagLen).ToArray();
        return new WebRtcProductHpkeSealedBox(suiteWireId, encapsulatedKey, nonce, ciphertext, tag);
    }

    private static void ValidateSealedBoxHeader(byte version, int encLen, int nonceLen, uint ctLen, int tagLen)
    {
        if (encLen > WebRtcProductHandshakeCodec.HpkeMaxEncapsulatedKeyLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"HPKE sealed box encapsulated key exceeds {WebRtcProductHandshakeCodec.HpkeMaxEncapsulatedKeyLength} bytes.");
        }

        if (version == 1)
        {
            if (nonceLen != WebRtcProductHandshakeCodec.HpkeNonceLength)
            {
                throw new WebRtcProductHandshakeCodecException("HPKE v1 sealed box nonce length mismatch.");
            }

            if (tagLen != WebRtcProductHandshakeCodec.HpkeTagLength)
            {
                throw new WebRtcProductHandshakeCodecException("HPKE v1 sealed box tag length mismatch.");
            }
        }
        else
        {
            if (nonceLen is not 0 and not WebRtcProductHandshakeCodec.HpkeNonceLength)
            {
                throw new WebRtcProductHandshakeCodecException("HPKE v2 sealed box nonce length mismatch.");
            }

            if (tagLen is not 0 and not WebRtcProductHandshakeCodec.HpkeTagLength)
            {
                throw new WebRtcProductHandshakeCodecException("HPKE v2 sealed box tag length mismatch.");
            }
        }

        if (ctLen > WebRtcProductHandshakeCodec.HpkeMaxHandshakeCiphertextLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"HPKE sealed box ciphertext exceeds {WebRtcProductHandshakeCodec.HpkeMaxHandshakeCiphertextLength} bytes.");
        }
    }

    private static void ValidateSealedBoxParts(int encLen, int nonceLen, int ctLen, int tagLen)
    {
        if (encLen > WebRtcProductHandshakeCodec.HpkeMaxEncapsulatedKeyLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"HPKE sealed box encapsulated key exceeds {WebRtcProductHandshakeCodec.HpkeMaxEncapsulatedKeyLength} bytes.");
        }

        if (nonceLen is not 0 and not WebRtcProductHandshakeCodec.HpkeNonceLength)
        {
            throw new WebRtcProductHandshakeCodecException("HPKE sealed box nonce length mismatch.");
        }

        if (tagLen is not 0 and not WebRtcProductHandshakeCodec.HpkeTagLength)
        {
            throw new WebRtcProductHandshakeCodecException("HPKE sealed box tag length mismatch.");
        }

        if (ctLen > WebRtcProductHandshakeCodec.HpkeMaxHandshakeCiphertextLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"HPKE sealed box ciphertext exceeds {WebRtcProductHandshakeCodec.HpkeMaxHandshakeCiphertextLength} bytes.");
        }
    }
}

public sealed class WebRtcProductHandshakeMessageA
{
    public WebRtcProductHandshakeMessageA(
        IReadOnlyList<ushort> supportedSuiteWireIds,
        IReadOnlyList<WebRtcProductHandshakeKeyShare> keyShares,
        ReadOnlyMemory<byte> clientNonce,
        WebRtcProductCryptoCapabilities capabilities,
        WebRtcProductHandshakePolicy policy,
        ReadOnlyMemory<byte> identityPublicKey,
        ReadOnlyMemory<byte> extensionsRaw,
        ReadOnlyMemory<byte> signature,
        ReadOnlyMemory<byte>? secureEnclaveSignature = null,
        ReadOnlyMemory<byte>? initiatorContribution = null,
        byte version = WebRtcProductHandshakeCodec.ProtocolVersion)
    {
        if (version != WebRtcProductHandshakeCodec.ProtocolVersion)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product handshake MessageA version={version}.");
        }

        Version = version;
        SupportedSuiteWireIds = ValidateSupportedSuites(supportedSuiteWireIds);
        KeyShares = ValidateKeyShares(keyShares, SupportedSuiteWireIds);
        ClientNonce = RequireLength(clientNonce, WebRtcProductHandshakeCodec.NonceLength, "MessageA client nonce").ToArray();
        Capabilities = capabilities ?? throw new ArgumentNullException(nameof(capabilities));
        Policy = policy ?? throw new ArgumentNullException(nameof(policy));
        IdentityPublicKey = RequireNonEmpty(identityPublicKey, "MessageA identity public key").ToArray();
        ExtensionsRaw = ValidateExtensions(extensionsRaw.Span).ToArray();
        Signature = RequireNonEmpty(signature, "MessageA signature").ToArray();
        SecureEnclaveSignature = secureEnclaveSignature.HasValue && !secureEnclaveSignature.Value.IsEmpty
            ? secureEnclaveSignature.Value.ToArray()
            : null;
        InitiatorContribution = ValidateInitiatorContribution(
                SupportedSuiteWireIds,
                initiatorContribution.HasValue ? initiatorContribution.Value.Span : ReadOnlySpan<byte>.Empty)
            .ToArray();
    }

    public byte Version { get; }

    public IReadOnlyList<ushort> SupportedSuiteWireIds { get; }

    public IReadOnlyList<WebRtcProductHandshakeKeyShare> KeyShares { get; }

    public ReadOnlyMemory<byte> ClientNonce { get; }

    public WebRtcProductCryptoCapabilities Capabilities { get; }

    public WebRtcProductHandshakePolicy Policy { get; }

    public ReadOnlyMemory<byte> IdentityPublicKey { get; }

    public ReadOnlyMemory<byte> ExtensionsRaw { get; }

    public ReadOnlyMemory<byte> Signature { get; }

    public ReadOnlyMemory<byte>? SecureEnclaveSignature { get; }

    public ReadOnlyMemory<byte> InitiatorContribution { get; }

    public bool UsesV2InitiatorContribution => WebRtcProductHandshakeCodec.RequiresV2EphemeralContribution(SupportedSuiteWireIds);

    public byte[] EncodeWithoutSignature()
    {
        using var output = new MemoryStream();
        output.WriteByte(Version);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)SupportedSuiteWireIds.Count));
        foreach (var suiteWireId in SupportedSuiteWireIds)
        {
            WebRtcProductHandshakeCodec.WriteUInt16LE(output, suiteWireId);
        }

        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)KeyShares.Count));
        foreach (var keyShare in KeyShares)
        {
            WebRtcProductHandshakeCodec.WriteUInt16LE(output, keyShare.SuiteWireId);
            WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)keyShare.ShareBytes.Length));
            output.Write(keyShare.ShareBytes.Span);
        }

        output.Write(ClientNonce.Span);
        var capabilitiesData = Capabilities.Encode();
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)capabilitiesData.Length));
        output.Write(capabilitiesData);
        var policyData = Policy.Encode();
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)policyData.Length));
        output.Write(policyData);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)IdentityPublicKey.Length));
        output.Write(IdentityPublicKey.Span);
        if (UsesV2InitiatorContribution)
        {
            WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)InitiatorContribution.Length));
            output.Write(InitiatorContribution.Span);
        }

        if (!ExtensionsRaw.IsEmpty)
        {
            output.Write(WebRtcProductHandshakeCodec.MessageAExtensionsMagicBytes);
            WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)ExtensionsRaw.Length));
            output.Write(ExtensionsRaw.Span);
        }

        return output.ToArray();
    }

    public byte[] Encode()
    {
        using var output = new MemoryStream();
        var body = EncodeWithoutSignature();
        output.Write(body);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)Signature.Length));
        output.Write(Signature.Span);
        var seSignature = SecureEnclaveSignature.HasValue ? SecureEnclaveSignature.Value.Span : ReadOnlySpan<byte>.Empty;
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)seSignature.Length));
        output.Write(seSignature);
        return output.ToArray();
    }

    public byte[] SignaturePreimage()
    {
        using var output = new MemoryStream();
        output.Write(WebRtcProductHandshakeCodec.MessageASignatureDomainBytes);
        output.Write(EncodeWithoutSignature());
        return output.ToArray();
    }

    public static WebRtcProductHandshakeMessageA Decode(ReadOnlySpan<byte> frame)
    {
        var data = WebRtcProductHandshakeCodec.UnwrapHandshakePadding(frame);
        if (data.Length < 5)
        {
            throw new WebRtcProductHandshakeCodecException("MessageA is too short.");
        }

        if (data.Length > WebRtcProductHandshakeCodec.MaxMessageALength)
        {
            throw new WebRtcProductHandshakeCodecException("MessageA exceeds maximum length.");
        }

        var reader = new WireReader(data);
        var version = reader.ReadByte("MessageA version");
        if (version != WebRtcProductHandshakeCodec.ProtocolVersion)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported MessageA version={version}.");
        }

        var supportedCount = reader.ReadUInt16LE("MessageA supported suite count");
        if (supportedCount == 0 || supportedCount > WebRtcProductHandshakeCodec.MaxSupportedSuites)
        {
            throw new WebRtcProductHandshakeCodecException("Invalid MessageA supported suite count.");
        }

        var supportedSuites = new ushort[supportedCount];
        for (var index = 0; index < supportedSuites.Length; index++)
        {
            var suiteWireId = reader.ReadUInt16LE("MessageA supported suite");
            WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
            supportedSuites[index] = suiteWireId;
        }

        var keyShareCount = reader.ReadUInt16LE("MessageA keyShare count");
        if (keyShareCount > WebRtcProductHandshakeCodec.MaxKeyShareCount || keyShareCount > supportedCount)
        {
            throw new WebRtcProductHandshakeCodecException("Invalid MessageA keyShare count.");
        }

        var keyShares = new WebRtcProductHandshakeKeyShare[keyShareCount];
        var seenSuites = new HashSet<ushort>();
        for (var index = 0; index < keyShares.Length; index++)
        {
            var suiteWireId = reader.ReadUInt16LE("MessageA keyShare suite");
            var shareLength = reader.ReadUInt16LE("MessageA keyShare length");
            WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
            if (!seenSuites.Add(suiteWireId))
            {
                throw new WebRtcProductHandshakeCodecException("Duplicate MessageA keyShare suite.");
            }

            var shareBytes = reader.ReadBytes(shareLength, "MessageA keyShare");
            keyShares[index] = new WebRtcProductHandshakeKeyShare(suiteWireId, shareBytes.ToArray());
        }

        ValidateKeyShareOrder(supportedSuites, keyShares);
        var clientNonce = reader.ReadBytes(WebRtcProductHandshakeCodec.NonceLength, "MessageA client nonce");
        var capabilitiesData = reader.ReadLengthPrefixedUInt16("MessageA capabilities");
        var capabilities = WebRtcProductCryptoCapabilities.Decode(capabilitiesData);
        var policyData = reader.ReadLengthPrefixedUInt16("MessageA policy");
        var policy = WebRtcProductHandshakePolicy.Decode(policyData);
        var identityPublicKey = reader.ReadLengthPrefixedUInt16("MessageA identity public key");
        var initiatorContribution = ReadOnlySpan<byte>.Empty;
        if (WebRtcProductHandshakeCodec.RequiresV2EphemeralContribution(supportedSuites))
        {
            initiatorContribution = reader.ReadLengthPrefixedUInt16("MessageA v2 initiator contribution");
            _ = ValidateInitiatorContribution(supportedSuites, initiatorContribution);
        }

        var extensionsRaw = ReadOnlySpan<byte>.Empty;
        if (reader.Remaining >= WebRtcProductHandshakeCodec.MessageAExtensionsMagicBytes.Length + 2 &&
            reader.Peek(WebRtcProductHandshakeCodec.MessageAExtensionsMagicBytes.Length)
                .SequenceEqual(WebRtcProductHandshakeCodec.MessageAExtensionsMagicBytes))
        {
            reader.Skip(WebRtcProductHandshakeCodec.MessageAExtensionsMagicBytes.Length, "MessageA extensions magic");
            extensionsRaw = reader.ReadLengthPrefixedUInt16("MessageA extensions");
            _ = ValidateExtensions(extensionsRaw);
        }

        var signature = reader.ReadLengthPrefixedUInt16("MessageA signature");
        var secureEnclaveSignature = ReadOnlySpan<byte>.Empty;
        if (!reader.IsAtEnd)
        {
            secureEnclaveSignature = reader.ReadLengthPrefixedUInt16("MessageA Secure Enclave signature");
        }

        reader.RequireAtEnd("MessageA");
        return new WebRtcProductHandshakeMessageA(
            supportedSuites,
            keyShares,
            clientNonce.ToArray(),
            capabilities,
            policy,
            identityPublicKey.ToArray(),
            extensionsRaw.ToArray(),
            signature.ToArray(),
            secureEnclaveSignature.IsEmpty ? null : secureEnclaveSignature.ToArray(),
            initiatorContribution.IsEmpty ? null : initiatorContribution.ToArray(),
            version);
    }

    private static IReadOnlyList<ushort> ValidateSupportedSuites(IReadOnlyList<ushort> supportedSuiteWireIds)
    {
        ArgumentNullException.ThrowIfNull(supportedSuiteWireIds);
        if (supportedSuiteWireIds.Count is 0 or > WebRtcProductHandshakeCodec.MaxSupportedSuites)
        {
            throw new WebRtcProductHandshakeCodecException("Invalid MessageA supported suite count.");
        }

        var copy = new ushort[supportedSuiteWireIds.Count];
        for (var index = 0; index < supportedSuiteWireIds.Count; index++)
        {
            WebRtcProductHandshakeCodec.RequireKnownSuite(supportedSuiteWireIds[index]);
            copy[index] = supportedSuiteWireIds[index];
        }

        return Array.AsReadOnly(copy);
    }

    private static IReadOnlyList<WebRtcProductHandshakeKeyShare> ValidateKeyShares(
        IReadOnlyList<WebRtcProductHandshakeKeyShare> keyShares,
        IReadOnlyList<ushort> supportedSuiteWireIds)
    {
        ArgumentNullException.ThrowIfNull(keyShares);
        if (keyShares.Count > WebRtcProductHandshakeCodec.MaxKeyShareCount ||
            keyShares.Count > supportedSuiteWireIds.Count)
        {
            throw new WebRtcProductHandshakeCodecException("Invalid MessageA keyShare count.");
        }

        var copy = new WebRtcProductHandshakeKeyShare[keyShares.Count];
        var seen = new HashSet<ushort>();
        for (var index = 0; index < keyShares.Count; index++)
        {
            var keyShare = keyShares[index] ?? throw new ArgumentNullException(nameof(keyShares));
            if (!seen.Add(keyShare.SuiteWireId))
            {
                throw new WebRtcProductHandshakeCodecException("Duplicate MessageA keyShare suite.");
            }

            copy[index] = keyShare;
        }

        ValidateKeyShareOrder(supportedSuiteWireIds, copy);
        return Array.AsReadOnly(copy);
    }

    private static void ValidateKeyShareOrder(
        IReadOnlyList<ushort> supportedSuites,
        IReadOnlyList<WebRtcProductHandshakeKeyShare> keyShares)
    {
        var lastIndex = -1;
        foreach (var keyShare in keyShares)
        {
            var currentIndex = IndexOf(supportedSuites, keyShare.SuiteWireId);
            if (currentIndex < 0)
            {
                throw new WebRtcProductHandshakeCodecException("MessageA keyShare suite is not in supportedSuites.");
            }

            if (currentIndex < lastIndex)
            {
                throw new WebRtcProductHandshakeCodecException("MessageA keyShares are out of order.");
            }

            lastIndex = currentIndex;
        }
    }

    private static int IndexOf(IReadOnlyList<ushort> suites, ushort suiteWireId)
    {
        for (var index = 0; index < suites.Count; index++)
        {
            if (suites[index] == suiteWireId)
            {
                return index;
            }
        }

        return -1;
    }

    private static ReadOnlySpan<byte> RequireLength(ReadOnlyMemory<byte> bytes, int expectedLength, string fieldName)
    {
        if (bytes.Length != expectedLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"{fieldName} must be exactly {expectedLength} bytes.");
        }

        return bytes.Span;
    }

    private static ReadOnlySpan<byte> RequireNonEmpty(ReadOnlyMemory<byte> bytes, string fieldName)
    {
        if (bytes.IsEmpty)
        {
            throw new WebRtcProductHandshakeCodecException($"{fieldName} must not be empty.");
        }

        return bytes.Span;
    }

    private static ReadOnlySpan<byte> ValidateInitiatorContribution(
        IReadOnlyList<ushort> supportedSuites,
        ReadOnlySpan<byte> initiatorContribution)
    {
        if (!WebRtcProductHandshakeCodec.RequiresV2EphemeralContribution(supportedSuites))
        {
            if (!initiatorContribution.IsEmpty)
            {
                throw new WebRtcProductHandshakeCodecException(
                    "MessageA v2 initiator contribution is only valid when an FS suite is offered.");
            }

            return ReadOnlySpan<byte>.Empty;
        }

        if (initiatorContribution.IsEmpty || initiatorContribution.Length == WebRtcProductHandshakeCodec.V2InitiatorContributionLength)
        {
            return initiatorContribution;
        }

        throw new WebRtcProductHandshakeCodecException("MessageA v2 initiator contribution length mismatch.");
    }

    private static ReadOnlySpan<byte> ValidateExtensions(ReadOnlySpan<byte> extensionsRaw)
    {
        var reader = new WireReader(extensionsRaw);
        while (!reader.IsAtEnd)
        {
            _ = reader.ReadUInt16LE("MessageA extension type");
            var length = reader.ReadUInt16LE("MessageA extension length");
            _ = reader.ReadBytes(length, "MessageA extension value");
        }

        return extensionsRaw;
    }
}

public sealed class WebRtcProductHandshakeMessageB
{
    public WebRtcProductHandshakeMessageB(
        ushort selectedSuiteWireId,
        ReadOnlyMemory<byte> responderShare,
        ReadOnlyMemory<byte> serverNonce,
        WebRtcProductHpkeSealedBox encryptedPayload,
        ReadOnlyMemory<byte> identityPublicKey,
        ReadOnlyMemory<byte> signature,
        ReadOnlyMemory<byte>? secureEnclaveSignature = null,
        byte version = WebRtcProductHandshakeCodec.ProtocolVersion)
    {
        if (version != WebRtcProductHandshakeCodec.ProtocolVersion)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product handshake MessageB version={version}.");
        }

        WebRtcProductHandshakeCodec.RequireKnownSuite(selectedSuiteWireId);
        WebRtcProductHandshakeCodec.ValidateResponderShareLength(selectedSuiteWireId, responderShare.Length);
        Version = version;
        SelectedSuiteWireId = selectedSuiteWireId;
        ResponderShare = responderShare.ToArray();
        ServerNonce = RequireLength(serverNonce, WebRtcProductHandshakeCodec.NonceLength, "MessageB server nonce").ToArray();
        EncryptedPayload = encryptedPayload ?? throw new ArgumentNullException(nameof(encryptedPayload));
        if (EncryptedPayload.SuiteWireId != selectedSuiteWireId)
        {
            throw new WebRtcProductHandshakeCodecException("MessageB HPKE payload suite does not match selected suite.");
        }

        IdentityPublicKey = RequireNonEmpty(identityPublicKey, "MessageB identity public key").ToArray();
        Signature = RequireNonEmpty(signature, "MessageB signature").ToArray();
        SecureEnclaveSignature = secureEnclaveSignature.HasValue && !secureEnclaveSignature.Value.IsEmpty
            ? secureEnclaveSignature.Value.ToArray()
            : null;
    }

    public byte Version { get; }

    public ushort SelectedSuiteWireId { get; }

    public ReadOnlyMemory<byte> ResponderShare { get; }

    public ReadOnlyMemory<byte> ServerNonce { get; }

    public WebRtcProductHpkeSealedBox EncryptedPayload { get; }

    public ReadOnlyMemory<byte> IdentityPublicKey { get; }

    public ReadOnlyMemory<byte> Signature { get; }

    public ReadOnlyMemory<byte>? SecureEnclaveSignature { get; }

    public byte[] EncodeWithoutSignature()
    {
        using var output = new MemoryStream();
        output.WriteByte(Version);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, SelectedSuiteWireId);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)ResponderShare.Length));
        output.Write(ResponderShare.Span);
        output.Write(ServerNonce.Span);
        var payload = EncryptedPayload.Encode(SelectedSuiteWireId);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)payload.Length));
        output.Write(payload);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)IdentityPublicKey.Length));
        output.Write(IdentityPublicKey.Span);
        return output.ToArray();
    }

    public byte[] Encode()
    {
        using var output = new MemoryStream();
        output.Write(EncodeWithoutSignature());
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)Signature.Length));
        output.Write(Signature.Span);
        var seSignature = SecureEnclaveSignature.HasValue ? SecureEnclaveSignature.Value.Span : ReadOnlySpan<byte>.Empty;
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)seSignature.Length));
        output.Write(seSignature);
        return output.ToArray();
    }

    public byte[] SignaturePreimage(ReadOnlySpan<byte> transcriptHashA)
    {
        if (transcriptHashA.Length != WebRtcProductHandshakeCodec.TranscriptHashLength)
        {
            throw new WebRtcProductHandshakeCodecException("MessageB transcriptHashA must be exactly 32 bytes.");
        }

        using var output = new MemoryStream();
        output.Write(WebRtcProductHandshakeCodec.MessageBSignatureDomainBytes);
        output.Write(transcriptHashA);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, SelectedSuiteWireId);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)ResponderShare.Length));
        output.Write(ResponderShare.Span);
        output.Write(ServerNonce.Span);
        output.Write(SHA256.HashData(EncryptedPayload.Encode(SelectedSuiteWireId)));
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)IdentityPublicKey.Length));
        output.Write(IdentityPublicKey.Span);
        return output.ToArray();
    }

    public static WebRtcProductHandshakeMessageB Decode(ReadOnlySpan<byte> frame)
    {
        var data = WebRtcProductHandshakeCodec.UnwrapHandshakePadding(frame);
        if (data.Length < 5)
        {
            throw new WebRtcProductHandshakeCodecException("MessageB is too short.");
        }

        if (data.Length > WebRtcProductHandshakeCodec.MaxMessageBLength)
        {
            throw new WebRtcProductHandshakeCodecException("MessageB exceeds maximum length.");
        }

        var reader = new WireReader(data);
        var version = reader.ReadByte("MessageB version");
        if (version != WebRtcProductHandshakeCodec.ProtocolVersion)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported MessageB version={version}.");
        }

        var selectedSuiteWireId = reader.ReadUInt16LE("MessageB selected suite");
        WebRtcProductHandshakeCodec.RequireKnownSuite(selectedSuiteWireId);
        var responderShare = reader.ReadLengthPrefixedUInt16("MessageB responder share");
        WebRtcProductHandshakeCodec.ValidateResponderShareLength(selectedSuiteWireId, responderShare.Length);
        var serverNonce = reader.ReadBytes(WebRtcProductHandshakeCodec.NonceLength, "MessageB server nonce");
        var payload = reader.ReadLengthPrefixedUInt16("MessageB encrypted payload");
        var sealedBox = WebRtcProductHpkeSealedBox.Decode(payload);
        if (sealedBox.SuiteWireId != selectedSuiteWireId)
        {
            throw new WebRtcProductHandshakeCodecException("MessageB HPKE payload suite does not match selected suite.");
        }

        var identityPublicKey = reader.ReadLengthPrefixedUInt16("MessageB identity public key");
        var signature = reader.ReadLengthPrefixedUInt16("MessageB signature");
        var secureEnclaveSignature = ReadOnlySpan<byte>.Empty;
        if (!reader.IsAtEnd)
        {
            secureEnclaveSignature = reader.ReadLengthPrefixedUInt16("MessageB Secure Enclave signature");
        }

        reader.RequireAtEnd("MessageB");
        return new WebRtcProductHandshakeMessageB(
            selectedSuiteWireId,
            responderShare.ToArray(),
            serverNonce.ToArray(),
            sealedBox,
            identityPublicKey.ToArray(),
            signature.ToArray(),
            secureEnclaveSignature.IsEmpty ? null : secureEnclaveSignature.ToArray(),
            version);
    }

    private static ReadOnlySpan<byte> RequireLength(ReadOnlyMemory<byte> bytes, int expectedLength, string fieldName)
    {
        if (bytes.Length != expectedLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"{fieldName} must be exactly {expectedLength} bytes.");
        }

        return bytes.Span;
    }

    private static ReadOnlySpan<byte> RequireNonEmpty(ReadOnlyMemory<byte> bytes, string fieldName)
    {
        if (bytes.IsEmpty)
        {
            throw new WebRtcProductHandshakeCodecException($"{fieldName} must not be empty.");
        }

        return bytes.Span;
    }
}

public sealed class WebRtcProductHandshakeFinished
{
    public WebRtcProductHandshakeFinished(
        WebRtcProductHandshakeFinishedDirection direction,
        ReadOnlyMemory<byte> mac,
        byte version = WebRtcProductHandshakeCodec.ProtocolVersion)
    {
        if (version != WebRtcProductHandshakeCodec.ProtocolVersion)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product handshake Finished version={version}.");
        }

        if (mac.Length != WebRtcProductHandshakeCodec.FinishedMacLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Finished MAC must be exactly {WebRtcProductHandshakeCodec.FinishedMacLength} bytes.");
        }

        Version = version;
        Direction = direction;
        Mac = mac.ToArray();
    }

    public byte Version { get; }

    public WebRtcProductHandshakeFinishedDirection Direction { get; }

    public ReadOnlyMemory<byte> Mac { get; }

    public byte[] Encode()
    {
        using var output = new MemoryStream();
        output.Write(WebRtcProductHandshakeCodec.FinishedMagicBytes);
        output.WriteByte(Version);
        output.WriteByte((byte)Direction);
        output.Write(Mac.Span);
        return output.ToArray();
    }

    public static WebRtcProductHandshakeFinished Decode(ReadOnlySpan<byte> frame)
    {
        var data = WebRtcProductHandshakeCodec.UnwrapHandshakePadding(frame);
        if (data.Length != WebRtcProductHandshakeCodec.FinishedEncodedLength)
        {
            throw new WebRtcProductHandshakeCodecException("Finished length mismatch.");
        }

        if (!data[..4].SequenceEqual(WebRtcProductHandshakeCodec.FinishedMagicBytes))
        {
            throw new WebRtcProductHandshakeCodecException("Finished magic mismatch.");
        }

        var version = data[4];
        if (version != WebRtcProductHandshakeCodec.ProtocolVersion)
        {
            throw new WebRtcProductHandshakeCodecException($"Unsupported Finished version={version}.");
        }

        if (!Enum.IsDefined(typeof(WebRtcProductHandshakeFinishedDirection), data[5]))
        {
            throw new WebRtcProductHandshakeCodecException("Finished direction invalid.");
        }

        return new WebRtcProductHandshakeFinished(
            (WebRtcProductHandshakeFinishedDirection)data[5],
            data.AsSpan(6, WebRtcProductHandshakeCodec.FinishedMacLength).ToArray(),
            version);
    }
}

public static class WebRtcProductHandshakeCodec
{
    public const byte ProtocolVersion = 1;
    public const int NonceLength = 32;
    public const int TranscriptHashLength = 32;
    public const int MaxMessageALength = 8192;
    public const int MaxMessageBLength = 16384;
    public const ushort MaxSupportedSuites = 8;
    public const ushort MaxKeyShareCount = 2;
    public const int V2InitiatorContributionLength = 32;
    public const int FinishedMacLength = 32;
    public const int FinishedEncodedLength = 4 + 1 + 1 + FinishedMacLength;
    public const int HpkeHeaderLength = 17;
    public const int HpkeMaxEncapsulatedKeyLength = 4096;
    public const int HpkeNonceLength = 12;
    public const int HpkeTagLength = 16;
    public const int HpkeMaxHandshakeCiphertextLength = 64 * 1024;

    public const ushort SuiteXWingMldsa65 = 0x0001;
    public const ushort SuiteQPeriaptContextBound = 0x0011;
    public const ushort SuiteMlKem768Mldsa65 = 0x0101;
    public const ushort SuiteMlKem768Mldsa65ForwardSecure = 0x0102;
    public const ushort SuiteX25519Ed25519 = 0x1001;
    public const ushort SuiteP256Ecdsa = 0x1002;

    public static ReadOnlySpan<byte> HandshakePaddingMagicBytes => "SBP1"u8;
    public static ReadOnlySpan<byte> MessageAExtensionsMagicBytes => "SOA1"u8;
    public static ReadOnlySpan<byte> FinishedMagicBytes => "FIN1"u8;
    public static ReadOnlySpan<byte> HpkeMagicBytes => "HPKE"u8;
    public static ReadOnlySpan<byte> MessageASignatureDomainBytes => "SkyBridge-A"u8;
    public static ReadOnlySpan<byte> MessageBSignatureDomainBytes => "SkyBridge-B"u8;

    public static byte[] UnwrapHandshakePadding(ReadOnlySpan<byte> frame)
    {
        if (frame.Length < 8 || !frame[..4].SequenceEqual(HandshakePaddingMagicBytes))
        {
            return frame.ToArray();
        }

        var actualLength = BinaryPrimitives.ReadUInt32BigEndian(frame.Slice(4, 4));
        if (actualLength > frame.Length - 8)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"SBP1 actual length exceeds padded frame bytes actual={actualLength} available={frame.Length - 8}.");
        }

        return frame.Slice(8, checked((int)actualLength)).ToArray();
    }

    public static byte[] WrapHandshakePadding(ReadOnlySpan<byte> payload, int totalLength)
    {
        var minimumLength = 8 + payload.Length;
        if (totalLength < minimumLength)
        {
            throw new WebRtcProductHandshakeCodecException("SBP1 total length is smaller than header plus payload.");
        }

        using var output = new MemoryStream(totalLength);
        output.Write(HandshakePaddingMagicBytes);
        Span<byte> lengthBytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(lengthBytes, checked((uint)payload.Length));
        output.Write(lengthBytes);
        output.Write(payload);
        var paddingLength = totalLength - minimumLength;
        if (paddingLength > 0)
        {
            output.Write(RandomNumberGenerator.GetBytes(paddingLength));
        }

        return output.ToArray();
    }

    public static WebRtcProductHandshakeMessageA DecodeMessageA(ReadOnlySpan<byte> frame) =>
        WebRtcProductHandshakeMessageA.Decode(frame);

    public static WebRtcProductHandshakeMessageB DecodeMessageB(ReadOnlySpan<byte> frame) =>
        WebRtcProductHandshakeMessageB.Decode(frame);

    public static WebRtcProductHandshakeFinished DecodeFinished(ReadOnlySpan<byte> frame) =>
        WebRtcProductHandshakeFinished.Decode(frame);

    public static bool IsKnownSuite(ushort suiteWireId) =>
        suiteWireId is SuiteXWingMldsa65
            or SuiteQPeriaptContextBound
            or SuiteMlKem768Mldsa65
            or SuiteMlKem768Mldsa65ForwardSecure
            or SuiteX25519Ed25519
            or SuiteP256Ecdsa;

    public static void RequireKnownSuite(ushort suiteWireId)
    {
        if (!IsKnownSuite(suiteWireId))
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product handshake suite wireId=0x{suiteWireId:X4}.");
        }
    }

    public static bool RequiresV2EphemeralContribution(IReadOnlyList<ushort> suiteWireIds)
    {
        ArgumentNullException.ThrowIfNull(suiteWireIds);
        for (var index = 0; index < suiteWireIds.Count; index++)
        {
            if (suiteWireIds[index] == SuiteMlKem768Mldsa65ForwardSecure)
            {
                return true;
            }
        }

        return false;
    }

    public static int? ExpectedKeyShareLength(ushort suiteWireId) =>
        suiteWireId switch
        {
            SuiteQPeriaptContextBound => 1120,
            SuiteXWingMldsa65 => 1120,
            SuiteMlKem768Mldsa65 => 1088,
            SuiteMlKem768Mldsa65ForwardSecure => 1088,
            SuiteX25519Ed25519 => 32,
            SuiteP256Ecdsa => 65,
            _ => null
        };

    public static int? ExpectedResponderShareLength(ushort suiteWireId) =>
        suiteWireId switch
        {
            SuiteMlKem768Mldsa65ForwardSecure => 32,
            SuiteQPeriaptContextBound => 0,
            SuiteXWingMldsa65 => 0,
            SuiteMlKem768Mldsa65 => 0,
            _ => ExpectedKeyShareLength(suiteWireId)
        };

    public static void ValidateKeyShareLength(ushort suiteWireId, int length)
    {
        if (ExpectedKeyShareLength(suiteWireId) is { } expected && length != expected)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"MessageA keyShare length mismatch wireId=0x{suiteWireId:X4} expected={expected} actual={length}.");
        }
    }

    public static void ValidateResponderShareLength(ushort suiteWireId, int length)
    {
        if (ExpectedResponderShareLength(suiteWireId) is { } expected && length != expected)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"MessageB responder share length mismatch wireId=0x{suiteWireId:X4} expected={expected} actual={length}.");
        }
    }

    public static ushort ReadUInt16LE(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 2)
        {
            throw new ArgumentException("UInt16LE read requires exactly 2 bytes.", nameof(bytes));
        }

        return BinaryPrimitives.ReadUInt16LittleEndian(bytes);
    }

    public static uint ReadUInt32LE(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 4)
        {
            throw new ArgumentException("UInt32LE read requires exactly 4 bytes.", nameof(bytes));
        }

        return BinaryPrimitives.ReadUInt32LittleEndian(bytes);
    }

    public static void WriteUInt16LE(Stream stream, ushort value)
    {
        Span<byte> bytes = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(bytes, value);
        stream.Write(bytes);
    }

    public static void WriteUInt32LE(Stream stream, uint value)
    {
        Span<byte> bytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, value);
        stream.Write(bytes);
    }
}

internal ref struct WireReader
{
    private readonly ReadOnlySpan<byte> _data;
    private int _offset;

    public WireReader(ReadOnlySpan<byte> data)
    {
        _data = data;
        _offset = 0;
    }

    public bool IsAtEnd => _offset == _data.Length;

    public int Remaining => _data.Length - _offset;

    public byte ReadByte(string fieldName)
    {
        EnsureRemaining(1, fieldName);
        return _data[_offset++];
    }

    public ushort ReadUInt16LE(string fieldName)
    {
        EnsureRemaining(2, fieldName);
        var value = BinaryPrimitives.ReadUInt16LittleEndian(_data.Slice(_offset, 2));
        _offset += 2;
        return value;
    }

    public ReadOnlySpan<byte> ReadLengthPrefixedUInt16(string fieldName)
    {
        var length = ReadUInt16LE(fieldName + " length");
        return ReadBytes(length, fieldName);
    }

    public ReadOnlySpan<byte> ReadBytes(int length, string fieldName)
    {
        EnsureRemaining(length, fieldName);
        var bytes = _data.Slice(_offset, length);
        _offset += length;
        return bytes;
    }

    public ReadOnlySpan<byte> Peek(int length)
    {
        EnsureRemaining(length, "peek");
        return _data.Slice(_offset, length);
    }

    public void Skip(int length, string fieldName)
    {
        EnsureRemaining(length, fieldName);
        _offset += length;
    }

    public void RequireAtEnd(string frameName)
    {
        if (!IsAtEnd)
        {
            throw new WebRtcProductHandshakeCodecException($"{frameName} trailing bytes.");
        }
    }

    private void EnsureRemaining(int count, string fieldName)
    {
        if (count < 0 || _offset + count > _data.Length)
        {
            throw new WebRtcProductHandshakeCodecException($"{fieldName} truncated.");
        }
    }
}

internal static class DeterministicEncoding
{
    private const int MaxArrayElements = 64;
    private const int MaxStringBytes = 4096;
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static void WriteString(Stream stream, string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var bytes = StrictUtf8.GetBytes(value);
        if (bytes.Length > MaxStringBytes)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Deterministic string exceeds {MaxStringBytes} bytes.");
        }

        WebRtcProductHandshakeCodec.WriteUInt32LE(stream, checked((uint)bytes.Length));
        stream.Write(bytes);
    }

    public static void WriteStringArray(Stream stream, IReadOnlyList<string> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        if (values.Count > MaxArrayElements)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"Deterministic string array exceeds {MaxArrayElements} elements.");
        }

        WebRtcProductHandshakeCodec.WriteUInt32LE(stream, checked((uint)values.Count));
        for (var index = 0; index < values.Count; index++)
        {
            WriteString(stream, values[index]);
        }
    }

    public ref struct Reader
    {
        private readonly ReadOnlySpan<byte> _data;
        private int _offset;

        public Reader(ReadOnlySpan<byte> data)
        {
            _data = data;
            _offset = 0;
        }

        public bool IsAtEnd => _offset == _data.Length;

        public bool ReadBoolean()
        {
            var value = ReadByte("deterministic bool");
            return value switch
            {
                0x00 => false,
                0x01 => true,
                _ => throw new WebRtcProductHandshakeCodecException("Deterministic bool must be encoded as 0 or 1.")
            };
        }

        public string ReadString()
        {
            var length = ReadUInt32("deterministic string length");
            if (length > MaxStringBytes)
            {
                throw new WebRtcProductHandshakeCodecException(
                    $"Deterministic string exceeds {MaxStringBytes} bytes.");
            }

            var bytes = ReadBytes(checked((int)length), "deterministic string");
            try
            {
                return StrictUtf8.GetString(bytes);
            }
            catch (DecoderFallbackException ex)
            {
                throw new WebRtcProductHandshakeCodecException("Deterministic string contains invalid UTF-8.", ex);
            }
        }

        public IReadOnlyList<string> ReadStringArray()
        {
            var count = ReadUInt32("deterministic string array count");
            if (count > MaxArrayElements)
            {
                throw new WebRtcProductHandshakeCodecException(
                    $"Deterministic string array exceeds {MaxArrayElements} elements.");
            }

            var values = new string[checked((int)count)];
            for (var index = 0; index < values.Length; index++)
            {
                values[index] = ReadString();
            }

            return Array.AsReadOnly(values);
        }

        public void RequireAtEnd(string containerName)
        {
            if (!IsAtEnd)
            {
                throw new WebRtcProductHandshakeCodecException($"{containerName} trailing bytes.");
            }
        }

        private byte ReadByte(string fieldName)
        {
            EnsureRemaining(1, fieldName);
            return _data[_offset++];
        }

        private uint ReadUInt32(string fieldName)
        {
            EnsureRemaining(4, fieldName);
            var value = BinaryPrimitives.ReadUInt32LittleEndian(_data.Slice(_offset, 4));
            _offset += 4;
            return value;
        }

        private ReadOnlySpan<byte> ReadBytes(int count, string fieldName)
        {
            EnsureRemaining(count, fieldName);
            var bytes = _data.Slice(_offset, count);
            _offset += count;
            return bytes;
        }

        private void EnsureRemaining(int count, string fieldName)
        {
            if (count < 0 || _offset + count > _data.Length)
            {
                throw new WebRtcProductHandshakeCodecException($"{fieldName} truncated.");
            }
        }
    }
}
