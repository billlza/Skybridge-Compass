using System;

namespace Skybridge.WinClient.Services;

/// <summary>Existing WebRTC key facade over the shared product handshake derivation.</summary>
public static class WebRtcProductHandshakeSessionKeys
{
    public const int SharedSecretLength = ProductHandshakeKeyDerivation.SharedSecretLength;
    public const int TranscriptHashLength = ProductHandshakeKeyDerivation.TranscriptHashLength;
    public const int NonceLength = ProductHandshakeKeyDerivation.NonceLength;

    public static WebRtcAppSecureSessionKeys Derive(
        ReadOnlySpan<byte> sharedSecret, ushort suiteWireId, ReadOnlySpan<byte> transcriptA,
        ReadOnlySpan<byte> transcriptB, ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> serverNonce,
        WebRtcAppSecureRole role)
    {
        using var keys = ProductHandshakeKeyDerivation.Derive(sharedSecret, suiteWireId, transcriptA,
            transcriptB, clientNonce, serverNonce, ToProductRole(role));
        return ToWebRtcKeys(keys);
    }

    internal static WebRtcAppSecureSessionKeys ToWebRtcKeys(ProductSessionKeys keys) =>
        new(keys.Role == ProductHandshakeRole.Initiator ? WebRtcAppSecureRole.Initiator : WebRtcAppSecureRole.Responder,
            keys.SessionId, keys.TranscriptHash, keys.SendKey, keys.ReceiveKey);

    public static WebRtcProductHandshakeFinished CreateFinished(WebRtcAppSecureSessionKeys keys)
    {
        using var productKeys = ToProductKeys(keys);
        return ProductHandshakeKeyDerivation.CreateFinished(productKeys);
    }

    public static bool VerifyFinished(WebRtcProductHandshakeFinished finished,
        WebRtcAppSecureSessionKeys keys, WebRtcAppSecureRole expectingFrom)
    {
        using var productKeys = ToProductKeys(keys);
        return ProductHandshakeKeyDerivation.VerifyFinished(finished, productKeys, ToProductRole(expectingFrom));
    }

    public static string DeterministicSessionId(ReadOnlySpan<byte> transcriptHash) =>
        ProductHandshakeKeyDerivation.DeterministicSessionId(transcriptHash);

    internal static byte[] HkdfSha256(ReadOnlySpan<byte> inputKeyMaterial, ReadOnlySpan<byte> salt,
        ReadOnlySpan<byte> info, int outputLength) =>
        ProductHandshakeKeyDerivation.HkdfSha256(inputKeyMaterial, salt, info, outputLength);

    private static ProductSessionKeys ToProductKeys(WebRtcAppSecureSessionKeys keys) =>
        new(ToProductRole(keys.Role), keys.SessionId, keys.TranscriptHash, keys.SendKey, keys.ReceiveKey);

    private static ProductHandshakeRole ToProductRole(WebRtcAppSecureRole role) => role switch
    {
        WebRtcAppSecureRole.Initiator => ProductHandshakeRole.Initiator,
        WebRtcAppSecureRole.Responder => ProductHandshakeRole.Responder,
        _ => throw new System.IO.InvalidDataException("Invalid WebRTC secure role.")
    };
}
