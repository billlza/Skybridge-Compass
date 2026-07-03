using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Mac-compatible product-handshake key derivation and Finished MAC helpers.
/// This layer is intentionally crypto-provider agnostic: callers must supply the
/// real shared secret produced by MessageA/MessageB verification before it can
/// create an Established SBWC session.
/// </summary>
public static class WebRtcProductHandshakeSessionKeys
{
    public const int SharedSecretLength = 32;
    public const int TranscriptHashLength = 32;
    public const int NonceLength = 32;

    public static WebRtcAppSecureSessionKeys Derive(
        ReadOnlySpan<byte> sharedSecret,
        ushort suiteWireId,
        ReadOnlySpan<byte> transcriptA,
        ReadOnlySpan<byte> transcriptB,
        ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> serverNonce,
        WebRtcAppSecureRole role)
    {
        RequireLength(sharedSecret, SharedSecretLength, "WebRTC product handshake shared secret");
        RequireLength(transcriptA, TranscriptHashLength, "WebRTC product handshake transcriptA");
        RequireLength(transcriptB, TranscriptHashLength, "WebRTC product handshake transcriptB");
        RequireLength(clientNonce, NonceLength, "WebRTC product handshake client nonce");
        RequireLength(serverNonce, NonceLength, "WebRTC product handshake server nonce");
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);

        var kdfInfo = BuildKdfInfo(suiteWireId, transcriptA, transcriptB, clientNonce, serverNonce);
        var saltInput = Concat(Encoding.ASCII.GetBytes("SkyBridge-KDF-Salt-v1|"), kdfInfo);
        var salt = SHA256.HashData(saltInput);
        var i2rKey = HkdfSha256(
            sharedSecret,
            salt,
            Concat(kdfInfo, Encoding.ASCII.GetBytes("handshake|initiator_to_responder")),
            outputLength: 32);
        var r2iKey = HkdfSha256(
            sharedSecret,
            salt,
            Concat(kdfInfo, Encoding.ASCII.GetBytes("handshake|responder_to_initiator")),
            outputLength: 32);
        var transcriptHash = SHA256.HashData(Concat(transcriptA, transcriptB));

        return role switch
        {
            WebRtcAppSecureRole.Initiator => new WebRtcAppSecureSessionKeys(
                role,
                DeterministicSessionId(transcriptHash),
                transcriptHash,
                i2rKey,
                r2iKey),
            WebRtcAppSecureRole.Responder => new WebRtcAppSecureSessionKeys(
                role,
                DeterministicSessionId(transcriptHash),
                transcriptHash,
                r2iKey,
                i2rKey),
            _ => throw new InvalidDataException($"Unsupported WebRTC product handshake role '{role}'.")
        };
    }

    public static WebRtcProductHandshakeFinished CreateFinished(WebRtcAppSecureSessionKeys keys)
    {
        ArgumentNullException.ThrowIfNull(keys);
        var direction = keys.Role switch
        {
            WebRtcAppSecureRole.Initiator => WebRtcProductHandshakeFinishedDirection.InitiatorToResponder,
            WebRtcAppSecureRole.Responder => WebRtcProductHandshakeFinishedDirection.ResponderToInitiator,
            _ => throw new InvalidDataException($"Unsupported WebRTC secure role '{keys.Role}'.")
        };
        var mac = ComputeFinishedMac(keys.SendKey.Span, direction, keys.TranscriptHash.Span);
        return new WebRtcProductHandshakeFinished(direction, mac);
    }

    public static bool VerifyFinished(
        WebRtcProductHandshakeFinished finished,
        WebRtcAppSecureSessionKeys keys,
        WebRtcAppSecureRole expectingFrom)
    {
        ArgumentNullException.ThrowIfNull(finished);
        ArgumentNullException.ThrowIfNull(keys);
        var expectedDirection = expectingFrom switch
        {
            WebRtcAppSecureRole.Initiator => WebRtcProductHandshakeFinishedDirection.InitiatorToResponder,
            WebRtcAppSecureRole.Responder => WebRtcProductHandshakeFinishedDirection.ResponderToInitiator,
            _ => throw new InvalidDataException($"Unsupported WebRTC secure role '{expectingFrom}'.")
        };
        if (finished.Direction != expectedDirection || finished.Mac.Length != 32)
        {
            return false;
        }

        var expectedMac = ComputeFinishedMac(keys.ReceiveKey.Span, expectedDirection, keys.TranscriptHash.Span);
        return CryptographicOperations.FixedTimeEquals(expectedMac, finished.Mac.Span);
    }

    public static string DeterministicSessionId(ReadOnlySpan<byte> transcriptHash)
    {
        RequireLength(transcriptHash, TranscriptHashLength, "WebRTC product handshake transcript hash");
        var digest = SHA256.HashData(Concat(Encoding.ASCII.GetBytes("SkyBridge-SessionId-v1|"), transcriptHash));
        return "hs-" + Convert.ToHexString(digest.AsSpan(0, 16)).ToLowerInvariant();
    }

    private static byte[] ComputeFinishedMac(
        ReadOnlySpan<byte> baseKey,
        WebRtcProductHandshakeFinishedDirection direction,
        ReadOnlySpan<byte> transcriptHash)
    {
        RequireLength(baseKey, 32, "WebRTC product handshake Finished base key");
        RequireLength(transcriptHash, TranscriptHashLength, "WebRTC product handshake Finished transcript hash");
        var label = direction switch
        {
            WebRtcProductHandshakeFinishedDirection.InitiatorToResponder => "I2R",
            WebRtcProductHandshakeFinishedDirection.ResponderToInitiator => "R2I",
            _ => throw new InvalidDataException($"Unsupported WebRTC product handshake Finished direction '{direction}'.")
        };
        var macKey = HkdfSha256(
            baseKey,
            ReadOnlySpan<byte>.Empty,
            Concat(Encoding.ASCII.GetBytes($"SkyBridge-FINISHED|{label}|"), transcriptHash),
            outputLength: 32);
        var transcriptBytes = transcriptHash.ToArray();
        try
        {
            using var hmac = new HMACSHA256(macKey);
            return hmac.ComputeHash(transcriptBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(macKey);
            CryptographicOperations.ZeroMemory(transcriptBytes);
        }
    }

    private static byte[] BuildKdfInfo(
        ushort suiteWireId,
        ReadOnlySpan<byte> transcriptA,
        ReadOnlySpan<byte> transcriptB,
        ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> serverNonce)
    {
        var compositionLabel = SuiteKdfCompositionLabel(suiteWireId);
        using var output = new MemoryStream();
        output.Write(Encoding.ASCII.GetBytes("SkyBridge-KDF"));
        output.WriteByte(0x01);
        output.WriteByte((byte)(suiteWireId & 0xff));
        output.WriteByte((byte)(suiteWireId >> 8));
        output.Write(Encoding.ASCII.GetBytes(compositionLabel));
        output.Write(transcriptA);
        output.Write(transcriptB);
        output.Write(clientNonce);
        output.Write(serverNonce);
        return output.ToArray();
    }

    private static string SuiteKdfCompositionLabel(ushort suiteWireId)
    {
        WebRtcProductHandshakeCodec.RequireKnownSuite(suiteWireId);
        return suiteWireId == WebRtcProductHandshakeCodec.SuiteMlKem768Mldsa65ForwardSecure
            ? "v2-static+ephemeral"
            : "v1-single";
    }

    internal static byte[] HkdfSha256(
        ReadOnlySpan<byte> inputKeyMaterial,
        ReadOnlySpan<byte> salt,
        ReadOnlySpan<byte> info,
        int outputLength)
    {
        if (outputLength <= 0 || outputLength > 255 * 32)
        {
            throw new InvalidDataException("HKDF-SHA256 output length is outside the supported range.");
        }

        var saltKey = salt.IsEmpty ? new byte[32] : salt.ToArray();
        var pseudorandomKey = Array.Empty<byte>();
        var inputKeyMaterialBytes = inputKeyMaterial.ToArray();
        try
        {
            using var extract = new HMACSHA256(saltKey);
            pseudorandomKey = extract.ComputeHash(inputKeyMaterialBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(saltKey);
            CryptographicOperations.ZeroMemory(inputKeyMaterialBytes);
        }

        try
        {
            using var expand = new HMACSHA256(pseudorandomKey);
            var output = new byte[outputLength];
            var previous = Array.Empty<byte>();
            var offset = 0;
            byte counter = 1;

            while (offset < outputLength)
            {
                var blockInput = new byte[previous.Length + info.Length + 1];
                previous.CopyTo(blockInput, 0);
                info.CopyTo(blockInput.AsSpan(previous.Length));
                blockInput[^1] = counter;
                byte[] next;
                try
                {
                    next = expand.ComputeHash(blockInput);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(blockInput);
                }

                if (previous.Length > 0)
                {
                    CryptographicOperations.ZeroMemory(previous);
                }

                previous = next;
                var bytesToCopy = Math.Min(previous.Length, outputLength - offset);
                previous.AsSpan(0, bytesToCopy).CopyTo(output.AsSpan(offset));
                offset += bytesToCopy;
                counter++;
            }

            CryptographicOperations.ZeroMemory(previous);
            return output;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pseudorandomKey);
        }
    }

    private static void RequireLength(ReadOnlySpan<byte> value, int expectedLength, string label)
    {
        if (value.Length != expectedLength)
        {
            throw new InvalidDataException($"{label} must be exactly {expectedLength} bytes.");
        }
    }

    private static byte[] Concat(ReadOnlySpan<byte> first, ReadOnlySpan<byte> second)
    {
        var output = new byte[first.Length + second.Length];
        first.CopyTo(output);
        second.CopyTo(output.AsSpan(first.Length));
        return output;
    }
}
