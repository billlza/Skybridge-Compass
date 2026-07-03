using System;
using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

public enum WebRtcProductSignatureAlgorithm : byte
{
    Ed25519 = 0x01,
    MlDsa65 = 0x02,
    P256Ecdsa = 0x03,
}

public sealed class WebRtcProductProtocolIdentityPublicKey
{
    private const int Ed25519PublicKeyLength = 32;
    private const int MlDsa65PublicKeyLength = 1952;
    private const int P256UncompressedPublicKeyLength = 65;

    public WebRtcProductProtocolIdentityPublicKey(
        WebRtcProductSignatureAlgorithm algorithm,
        ReadOnlyMemory<byte> publicKey,
        ReadOnlyMemory<byte>? secureEnclavePublicKey = null)
    {
        ValidatePublicKey(algorithm, publicKey.Span);
        Algorithm = algorithm;
        PublicKey = publicKey.ToArray();
        SecureEnclavePublicKey = secureEnclavePublicKey.HasValue && !secureEnclavePublicKey.Value.IsEmpty
            ? secureEnclavePublicKey.Value.ToArray()
            : null;
    }

    public WebRtcProductSignatureAlgorithm Algorithm { get; }

    public ReadOnlyMemory<byte> PublicKey { get; }

    public ReadOnlyMemory<byte>? SecureEnclavePublicKey { get; }

    public string AuthoritativeFingerprint => ComputeAuthoritativeFingerprint(Algorithm, PublicKey.Span);

    public byte[] Encode()
    {
        using var output = new MemoryStream();
        output.WriteByte((byte)Algorithm);
        WebRtcProductHandshakeCodec.WriteUInt16LE(output, checked((ushort)PublicKey.Length));
        output.Write(PublicKey.Span);
        if (SecureEnclavePublicKey.HasValue)
        {
            output.WriteByte(0x01);
            WebRtcProductHandshakeCodec.WriteUInt16LE(
                output,
                checked((ushort)SecureEnclavePublicKey.Value.Length));
            output.Write(SecureEnclavePublicKey.Value.Span);
        }
        else
        {
            output.WriteByte(0x00);
        }

        return output.ToArray();
    }

    public static WebRtcProductProtocolIdentityPublicKey DecodeWithLegacyFallback(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length >= 4 && bytes[0] is >= 0x01 and <= 0x03)
        {
            try
            {
                return DecodeNewFormat(bytes);
            }
            catch (WebRtcProductHandshakeCodecException)
            {
                // Match the Mac wire contract: failed new-format parsing may still be a
                // legacy P-256 key, but only the strict 65-byte X9.63 shape is accepted below.
            }
        }

        if (bytes.Length == P256UncompressedPublicKeyLength && bytes[0] == 0x04)
        {
            return new WebRtcProductProtocolIdentityPublicKey(
                WebRtcProductSignatureAlgorithm.P256Ecdsa,
                bytes.ToArray());
        }

        throw new WebRtcProductHandshakeCodecException(
            "IdentityPublicKeys not decodable: expected new format or legacy P-256 uncompressed public key.");
    }

    public static string ComputeAuthoritativeFingerprint(
        WebRtcProductSignatureAlgorithm algorithm,
        ReadOnlySpan<byte> publicKey)
    {
        ValidateProtocolSigningAlgorithm(algorithm);
        ValidatePublicKey(algorithm, publicKey);
        var algorithmTag = Encoding.UTF8.GetBytes(AlgorithmRawValue(algorithm));
        using var payload = new MemoryStream();
        Span<byte> tagLength = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(tagLength, checked((ushort)algorithmTag.Length));
        payload.Write(tagLength);
        payload.Write(algorithmTag);
        Span<byte> keyLength = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(keyLength, checked((uint)publicKey.Length));
        payload.Write(keyLength);
        payload.Write(publicKey);
        return Convert.ToHexString(SHA256.HashData(payload.ToArray())).ToLowerInvariant();
    }

    public static string AlgorithmRawValue(WebRtcProductSignatureAlgorithm algorithm) =>
        algorithm switch
        {
            WebRtcProductSignatureAlgorithm.Ed25519 => "Ed25519",
            WebRtcProductSignatureAlgorithm.MlDsa65 => "ML-DSA-65",
            WebRtcProductSignatureAlgorithm.P256Ecdsa => "P-256-ECDSA",
            _ => throw new WebRtcProductHandshakeCodecException(
                $"Unsupported WebRTC product identity algorithm byte=0x{(byte)algorithm:X2}.")
        };

    private static WebRtcProductProtocolIdentityPublicKey DecodeNewFormat(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 4)
        {
            throw new WebRtcProductHandshakeCodecException("IdentityPublicKeys too short.");
        }

        var offset = 0;
        var algorithm = bytes[offset++] switch
        {
            0x01 => WebRtcProductSignatureAlgorithm.Ed25519,
            0x02 => WebRtcProductSignatureAlgorithm.MlDsa65,
            0x03 => WebRtcProductSignatureAlgorithm.P256Ecdsa,
            var value => throw new WebRtcProductHandshakeCodecException(
                $"Unknown signature algorithm: {value}.")
        };

        EnsureRemaining(bytes, offset, 2, "IdentityPublicKeys protocol public key length");
        var keyLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.Slice(offset, 2));
        offset += 2;
        EnsureRemaining(bytes, offset, keyLength, "IdentityPublicKeys protocol public key");
        var publicKey = bytes.Slice(offset, keyLength).ToArray();
        offset += keyLength;

        byte[]? secureEnclavePublicKey = null;
        if (offset < bytes.Length)
        {
            var hasSecureEnclaveKey = bytes[offset++];
            switch (hasSecureEnclaveKey)
            {
                case 0x00:
                    if (offset != bytes.Length)
                    {
                        throw new WebRtcProductHandshakeCodecException("IdentityPublicKeys trailing bytes.");
                    }
                    break;
                case 0x01:
                    EnsureRemaining(bytes, offset, 2, "IdentityPublicKeys Secure Enclave public key length");
                    var secureEnclaveKeyLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.Slice(offset, 2));
                    offset += 2;
                    EnsureRemaining(bytes, offset, secureEnclaveKeyLength, "IdentityPublicKeys Secure Enclave public key");
                    secureEnclavePublicKey = bytes.Slice(offset, secureEnclaveKeyLength).ToArray();
                    offset += secureEnclaveKeyLength;
                    if (offset != bytes.Length)
                    {
                        throw new WebRtcProductHandshakeCodecException("IdentityPublicKeys trailing bytes.");
                    }
                    break;
                default:
                    throw new WebRtcProductHandshakeCodecException(
                        "IdentityPublicKeys Secure Enclave key marker must be 0 or 1.");
            }
        }

        return new WebRtcProductProtocolIdentityPublicKey(algorithm, publicKey, secureEnclavePublicKey);
    }

    private static void ValidateProtocolSigningAlgorithm(WebRtcProductSignatureAlgorithm algorithm)
    {
        if (algorithm == WebRtcProductSignatureAlgorithm.P256Ecdsa)
        {
            throw new WebRtcProductHandshakeCodecException(
                "P-256 identity keys are legacy-only and cannot be used as protocol signing keys.");
        }
    }

    private static void ValidatePublicKey(WebRtcProductSignatureAlgorithm algorithm, ReadOnlySpan<byte> publicKey)
    {
        switch (algorithm)
        {
            case WebRtcProductSignatureAlgorithm.Ed25519:
                RequireLength(publicKey, Ed25519PublicKeyLength, "Ed25519 protocol public key");
                break;
            case WebRtcProductSignatureAlgorithm.MlDsa65:
                RequireLength(publicKey, MlDsa65PublicKeyLength, "ML-DSA-65 protocol public key");
                break;
            case WebRtcProductSignatureAlgorithm.P256Ecdsa:
                if (publicKey.Length != P256UncompressedPublicKeyLength || publicKey[0] != 0x04)
                {
                    throw new WebRtcProductHandshakeCodecException(
                        "legacy P-256 public key must be 65-byte uncompressed X9.63 form.");
                }
                break;
            default:
                throw new WebRtcProductHandshakeCodecException(
                    $"Unsupported WebRTC product identity algorithm byte=0x{(byte)algorithm:X2}.");
        }
    }

    private static void RequireLength(ReadOnlySpan<byte> bytes, int expectedLength, string label)
    {
        if (bytes.Length != expectedLength)
        {
            throw new WebRtcProductHandshakeCodecException(
                $"{label} must be exactly {expectedLength} bytes.");
        }
    }

    private static void EnsureRemaining(ReadOnlySpan<byte> bytes, int offset, int count, string label)
    {
        if (count < 0 || offset + count > bytes.Length)
        {
            throw new WebRtcProductHandshakeCodecException($"{label} truncated.");
        }
    }
}
