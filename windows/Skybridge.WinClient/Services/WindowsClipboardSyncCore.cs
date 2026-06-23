using System;
using System.Security.Cryptography;

namespace Skybridge.WinClient.Services;

// WindowsClipboardSyncCore
//
// Pure, OS-free logic for Windows clipboard sync. Mirrors the macOS
// `ClipboardSyncService` envelope/dedup/loop-suppression behaviour
// (Sources/SkyBridgeCore/Clipboard/ClipboardSyncService.swift) without
// touching the real OS clipboard, WinUI, or Win32 so it can be unit-tested
// inside a plain `net10.0` console smoke project.
//
// Responsibilities:
//   * payload framing  (1-byte kind || content)  -> ClipboardPayload
//   * AES-256-GCM seal/open envelope             (nonce(12) || ciphertext || tag(16))
//   * content-hash dedup + last-applied loop suppression  -> ClipboardLoopGuard
//
// The matching Win32 monitor + clipboard apply lives in
// WindowsClipboardSyncService.cs, which delegates all crypto/framing/dedup
// decisions here.

/// <summary>The kind byte that prefixes a framed clipboard payload.</summary>
internal enum ClipboardItemKind : byte
{
    Text = 0,
    ImagePng = 1,
}

/// <summary>
/// A decoded clipboard item: a kind plus its raw content bytes (UTF-8 for text,
/// PNG bytes for images). This is the cleartext that rides inside the AES-GCM
/// envelope on <c>DataPlaneChannel.Clipboard</c>.
/// </summary>
internal readonly struct ClipboardPayload : IEquatable<ClipboardPayload>
{
    public ClipboardItemKind Kind { get; }
    public ReadOnlyMemory<byte> Content { get; }

    public ClipboardPayload(ClipboardItemKind kind, ReadOnlyMemory<byte> content)
    {
        Kind = kind;
        Content = content;
    }

    public static ClipboardPayload Text(string text) =>
        new(ClipboardItemKind.Text, System.Text.Encoding.UTF8.GetBytes(text ?? string.Empty));

    public static ClipboardPayload ImagePng(ReadOnlyMemory<byte> pngBytes) =>
        new(ClipboardItemKind.ImagePng, pngBytes);

    /// <summary>Decode the content as UTF-8 text (only meaningful for <see cref="ClipboardItemKind.Text"/>).</summary>
    public string AsText() => System.Text.Encoding.UTF8.GetString(Content.Span);

    /// <summary>
    /// Frame this payload as <c>[kind:1][content:N]</c>. This is what gets sealed.
    /// </summary>
    public byte[] Frame()
    {
        var content = Content.Span;
        var framed = new byte[1 + content.Length];
        framed[0] = (byte)Kind;
        content.CopyTo(framed.AsSpan(1));
        return framed;
    }

    /// <summary>
    /// Parse a framed <c>[kind:1][content:N]</c> buffer back into a payload.
    /// Throws <see cref="FormatException"/> on an empty or unknown-kind buffer.
    /// </summary>
    public static ClipboardPayload Unframe(ReadOnlySpan<byte> framed)
    {
        if (framed.Length < 1)
        {
            throw new FormatException("Clipboard frame is empty.");
        }

        var kindByte = framed[0];
        if (kindByte != (byte)ClipboardItemKind.Text && kindByte != (byte)ClipboardItemKind.ImagePng)
        {
            throw new FormatException($"Unknown clipboard item kind: {kindByte}.");
        }

        // Copy out of the source span so the returned payload owns its bytes.
        return new ClipboardPayload((ClipboardItemKind)kindByte, framed[1..].ToArray());
    }

    public bool Equals(ClipboardPayload other) =>
        Kind == other.Kind && Content.Span.SequenceEqual(other.Content.Span);

    public override bool Equals(object? obj) => obj is ClipboardPayload other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(Kind, Content.Length);
}

/// <summary>
/// Provides the AES-256 session key used to seal/open clipboard envelopes.
///
/// KEY-INJECTION POINT: the production implementation is
/// <see cref="SessionDerivedClipboardKeyProvider"/>, which derives a distinct
/// 32-byte key per P2P session from REAL per-session secret material (the WebRTC
/// session id + the shared pairing/connection secret) via HKDF-SHA256. The
/// composition root builds it through <see cref="ClipboardKeyProviders"/>.
///
/// Fail closed: an implementation MUST throw from <see cref="CurrentKey"/> if no
/// session key is available, so the service refuses to send rather than emit
/// cleartext or fall back to a non-secret development key.
/// </summary>
internal interface IClipboardSessionKeyProvider
{
    /// <summary>
    /// Returns the current 32-byte (AES-256) session key. Called per seal/open so
    /// rekeys are picked up without restarting the monitor. Must never return null;
    /// throw if no key is available so we fail closed rather than send cleartext.
    /// </summary>
    byte[] CurrentKey();
}

/// <summary>
/// Inputs that bind a clipboard key to ONE specific P2P session. All of these are
/// observed identically by both endpoints of the verified WebRTC session, so two
/// peers that feed the SAME inputs into <see cref="ClipboardKeyDerivation"/> derive
/// the SAME 32-byte key (the cross-platform contract Goal D's live test depends on).
///
/// Field roles in the HKDF (see <see cref="ClipboardKeyDerivation"/>):
///   * <see cref="SharedPairingSecret"/> — the HKDF input keying material (IKM): the
///     shared pairing/connection secret both peers possess. This must be non-public
///     secret material, not the public pairing envelope or peer public key.
///   * <see cref="SessionId"/> — the HKDF salt: a per-session, both-sides-observable
///     identifier (the WebRTC proof's transportSecretFingerprintHex), so a NEW
///     session with the SAME pairing secret still derives DISTINCT key material.
/// </summary>
internal readonly struct ClipboardSessionBinding
{
    public string SharedPairingSecret { get; }
    public string SessionId { get; }

    public ClipboardSessionBinding(string sharedPairingSecret, string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sharedPairingSecret))
        {
            throw new ArgumentException("Clipboard session binding requires a non-empty shared pairing secret.", nameof(sharedPairingSecret));
        }

        if (string.IsNullOrWhiteSpace(sessionId))
        {
            throw new ArgumentException("Clipboard session binding requires a non-empty session id.", nameof(sessionId));
        }

        SharedPairingSecret = sharedPairingSecret;
        SessionId = sessionId;
    }
}

/// <summary>
/// The exact HKDF-SHA256 derivation of the 32-byte clipboard key. This is the
/// CONTRACT both platforms must implement identically for live Win↔Mac sync:
///
///     IKM  = UTF-8 bytes of the shared pairing/connection secret
///     salt = UTF-8 bytes of the per-session id (WebRTC transportSecretFingerprintHex)
///     info = UTF-8 bytes of "skybridge-clipboard-key-v1"  (fixed domain string)
///     key  = HKDF-SHA256(IKM, salt, info, L = 32)
///
/// HKDF (RFC 5869) is HMAC-SHA256 extract-then-expand; .NET's
/// <c>HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, salt, info)</c>
/// implements exactly that. The Apple side derives the same key with CryptoKit's
/// <c>HKDF&lt;SHA256&gt;.deriveKey(inputKeyMaterial:salt:info:outputByteCount:32)</c>
/// fed the SAME three byte strings.
/// </summary>
internal static class ClipboardKeyDerivation
{
    /// <summary>The HKDF <c>info</c> domain-separation string. Frozen; bump the suffix to rotate.</summary>
    public const string Info = "skybridge-clipboard-key-v1";

    public static byte[] DeriveKey(ClipboardSessionBinding binding)
    {
        var ikm = System.Text.Encoding.UTF8.GetBytes(binding.SharedPairingSecret);
        var salt = System.Text.Encoding.UTF8.GetBytes(binding.SessionId);
        var info = System.Text.Encoding.UTF8.GetBytes(Info);
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, ClipboardEnvelope.KeySize, salt, info);
    }
}

/// <summary>
/// PRODUCTION key provider. Derives the 32-byte clipboard key from real per-session
/// secret material via <see cref="ClipboardKeyDerivation"/> (HKDF-SHA256). The key is
/// computed once at construction (the binding is fixed for the session's lifetime;
/// a rekey constructs a new provider, mirroring how the monitor is restarted).
///
/// Distinct sessions (distinct <see cref="ClipboardSessionBinding.SessionId"/> and/or
/// shared secret) yield distinct keys, so a captured envelope from one session never
/// opens under another session's key.
/// </summary>
internal sealed class SessionDerivedClipboardKeyProvider : IClipboardSessionKeyProvider
{
    private readonly byte[] _key;

    public SessionDerivedClipboardKeyProvider(ClipboardSessionBinding binding)
    {
        _key = ClipboardKeyDerivation.DeriveKey(binding);
    }

    public byte[] CurrentKey() => _key;
}

/// <summary>
/// The only sanctioned way to construct a clipboard key provider for the RUNTIME.
/// The release path returns ONLY <see cref="SessionDerivedClipboardKeyProvider"/>;
/// there is no development-key fallback compiled into release. If a caller cannot
/// supply real session material, it gets no provider and the service fails closed
/// (it never sends).
/// </summary>
internal static class ClipboardKeyProviders
{
    /// <summary>
    /// Build the real session-derived provider for an active P2P session. Throws if
    /// the session material is missing/blank — callers MUST treat that as "no key"
    /// and not start clipboard sync (fail closed; never substitute a placeholder).
    /// </summary>
    public static IClipboardSessionKeyProvider CreateForSession(string sharedPairingSecret, string sessionId) =>
        new SessionDerivedClipboardKeyProvider(new ClipboardSessionBinding(sharedPairingSecret, sessionId));
}

#if DEBUG
/// <summary>
/// TEST-ONLY key provider, compiled ONLY under <c>DEBUG</c> (never present in a
/// Release build). Derives a deterministic 32-byte key from a caller-supplied seed
/// via SHA-256 so the OS-free smoke / unit tests can exercise the seal/open
/// round-trip, dedup, and loop-suppression without standing up a real WebRTC
/// session.
///
/// It is NOT reachable from any production code path: the runtime composition root
/// builds providers exclusively through <see cref="ClipboardKeyProviders"/>, which
/// returns only <see cref="SessionDerivedClipboardKeyProvider"/>. This type is named
/// for tests and excluded from Release so it cannot be wired by accident.
/// </summary>
internal sealed class TestOnlyDeterministicClipboardKeyProvider : IClipboardSessionKeyProvider
{
    private readonly byte[] _key;

    public TestOnlyDeterministicClipboardKeyProvider(string seed = "skybridge.clipboard.test-key.v1")
    {
        _key = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(seed));
    }

    public TestOnlyDeterministicClipboardKeyProvider(ReadOnlySpan<byte> rawSeed)
    {
        _key = SHA256.HashData(rawSeed);
    }

    public byte[] CurrentKey() => _key;
}
#endif

/// <summary>
/// AES-256-GCM envelope, mirroring the macOS ClipboardSyncService /
/// SessionSecrets.seal shape: a random 12-byte nonce, then ciphertext, then the
/// 16-byte GCM tag, all concatenated into one buffer:
///
///     [nonce:12][ciphertext:N][tag:16]
///
/// This is the same layout CryptoKit's <c>AES.GCM.SealedBox.combined</c> produces
/// (nonce || ciphertext || tag), so a future Apple peer that opens with
/// <c>AES.GCM.SealedBox(combined:)</c> and the same session key is wire-compatible
/// with what this seals (and vice versa), once the shared session key is wired.
/// </summary>
internal static class ClipboardEnvelope
{
    public const int NonceSize = 12;   // AES-GCM standard nonce
    public const int TagSize = 16;     // AES-GCM 128-bit tag
    public const int KeySize = 32;     // AES-256

    /// <summary>
    /// Seal the (already framed) cleartext into a <c>[nonce][ciphertext][tag]</c> envelope.
    /// </summary>
    /// <exception cref="ArgumentException">If the key is not 32 bytes.</exception>
    public static byte[] Seal(ReadOnlySpan<byte> cleartext, ReadOnlySpan<byte> key)
    {
        if (key.Length != KeySize)
        {
            throw new ArgumentException($"Clipboard session key must be {KeySize} bytes (AES-256), got {key.Length}.", nameof(key));
        }

        var envelope = new byte[NonceSize + cleartext.Length + TagSize];
        var nonce = envelope.AsSpan(0, NonceSize);
        var ciphertext = envelope.AsSpan(NonceSize, cleartext.Length);
        var tag = envelope.AsSpan(NonceSize + cleartext.Length, TagSize);

        RandomNumberGenerator.Fill(nonce);

        using var gcm = new AesGcm(key, TagSize);
        gcm.Encrypt(nonce, cleartext, ciphertext, tag);
        return envelope;
    }

    /// <summary>
    /// Open a <c>[nonce][ciphertext][tag]</c> envelope back into cleartext.
    /// Throws <see cref="CryptographicException"/> on tag-verify failure (tamper /
    /// wrong key) and <see cref="FormatException"/> on a too-short envelope.
    /// </summary>
    public static byte[] Open(ReadOnlySpan<byte> envelope, ReadOnlySpan<byte> key)
    {
        if (key.Length != KeySize)
        {
            throw new ArgumentException($"Clipboard session key must be {KeySize} bytes (AES-256), got {key.Length}.", nameof(key));
        }

        if (envelope.Length < NonceSize + TagSize)
        {
            throw new FormatException("Clipboard envelope is too short to contain a nonce and tag.");
        }

        var nonce = envelope[..NonceSize];
        var cipherLength = envelope.Length - NonceSize - TagSize;
        var ciphertext = envelope.Slice(NonceSize, cipherLength);
        var tag = envelope.Slice(NonceSize + cipherLength, TagSize);

        var cleartext = new byte[cipherLength];
        using var gcm = new AesGcm(key, TagSize);
        gcm.Decrypt(nonce, ciphertext, tag, cleartext); // throws CryptographicException on bad tag
        return cleartext;
    }
}

/// <summary>
/// Dedup + loop-suppression, mirroring the macOS service's
/// <c>lastContentHash</c> / <c>applyRemoteContent</c> dance:
///
///   * A local change is only broadcast if its content hash differs from the last
///     hash we either sent or applied. (changeCount dedup is done in the monitor;
///     this is the content-level dedup that survives identical re-copies.)
///   * Before applying a received item to the OS clipboard, the monitor calls
///     <see cref="MarkApplied"/> so the very next WM_CLIPBOARDUPDATE that the apply
///     itself triggers is recognised as our own echo and suppressed.
///
/// Thread-safety: the monitor confines all calls to its dedicated STA pump thread,
/// but a lock is taken anyway so a future caller on another thread is safe.
/// </summary>
internal sealed class ClipboardLoopGuard
{
    private readonly object _gate = new();
    private byte[]? _lastHash;

    /// <summary>SHA-256 of the framed payload, used as the dedup key.</summary>
    public static byte[] HashOf(ReadOnlySpan<byte> framedPayload) => SHA256.HashData(framedPayload);

    /// <summary>
    /// Should this locally-observed framed payload be broadcast? Returns false (and
    /// does NOT update state) if it matches the last sent/applied hash — that means
    /// it is either a duplicate copy or the echo of an item we just applied.
    /// On true, records the hash so the next identical change is suppressed.
    /// </summary>
    public bool ShouldBroadcast(ReadOnlySpan<byte> framedPayload)
    {
        var hash = HashOf(framedPayload);
        lock (_gate)
        {
            if (_lastHash is not null && _lastHash.AsSpan().SequenceEqual(hash))
            {
                return false;
            }

            _lastHash = hash;
            return true;
        }
    }

    /// <summary>
    /// Should this received framed payload be applied to the OS clipboard? Returns
    /// false if it matches the last sent/applied hash (we already have it). On true,
    /// the caller should immediately call <see cref="MarkApplied"/> with the SAME
    /// framed bytes right before writing the OS clipboard.
    /// </summary>
    public bool ShouldApply(ReadOnlySpan<byte> framedPayload)
    {
        var hash = HashOf(framedPayload);
        lock (_gate)
        {
            return _lastHash is null || !_lastHash.AsSpan().SequenceEqual(hash);
        }
    }

    /// <summary>
    /// Record a framed payload as the last-applied item so the OS clipboard write it
    /// is about to cause is recognised as our own echo and not re-broadcast.
    /// </summary>
    public void MarkApplied(ReadOnlySpan<byte> framedPayload)
    {
        var hash = HashOf(framedPayload);
        lock (_gate)
        {
            _lastHash = hash;
        }
    }

    /// <summary>Reset state (e.g. on session rekey or disable).</summary>
    public void Reset()
    {
        lock (_gate)
        {
            _lastHash = null;
        }
    }
}

/// <summary>
/// The end-to-end pure pipeline: frame -> dedup -> seal on the send side, and
/// open -> unframe -> dedup on the receive side. The Win32 service is a thin shell
/// around this plus the OS clipboard read/write. Kept here (OS-free) so the smoke
/// project can exercise the whole codec without a clipboard or a data plane.
/// </summary>
internal sealed class ClipboardSyncCodec
{
    private readonly IClipboardSessionKeyProvider _keyProvider;
    private readonly ClipboardLoopGuard _guard;

    public ClipboardSyncCodec(IClipboardSessionKeyProvider keyProvider, ClipboardLoopGuard? guard = null)
    {
        _keyProvider = keyProvider ?? throw new ArgumentNullException(nameof(keyProvider));
        _guard = guard ?? new ClipboardLoopGuard();
    }

    public ClipboardLoopGuard Guard => _guard;

    /// <summary>
    /// Build the encrypted envelope to send for a locally observed clipboard item,
    /// or <c>null</c> if it should be suppressed (duplicate / our own echo).
    /// </summary>
    public byte[]? TryBuildOutboundEnvelope(ClipboardPayload payload)
    {
        var framed = payload.Frame();
        if (!_guard.ShouldBroadcast(framed))
        {
            return null;
        }

        return ClipboardEnvelope.Seal(framed, _keyProvider.CurrentKey());
    }

    /// <summary>
    /// Decrypt + unframe a received envelope into a payload to apply, or <c>null</c>
    /// if it should be suppressed. On a returned payload the caller MUST mark the
    /// framed bytes applied (via <see cref="ClipboardLoopGuard.MarkApplied"/>)
    /// immediately before writing the OS clipboard — <see cref="MarkInboundApplied"/>
    /// is provided for that.
    /// </summary>
    public ClipboardPayload? TryDecodeInbound(ReadOnlySpan<byte> envelope)
    {
        var framed = ClipboardEnvelope.Open(envelope, _keyProvider.CurrentKey());
        if (!_guard.ShouldApply(framed))
        {
            return null;
        }

        return ClipboardPayload.Unframe(framed);
    }

    /// <summary>Mark a to-be-applied payload as last-applied so its echo is suppressed.</summary>
    public void MarkInboundApplied(ClipboardPayload payload) => _guard.MarkApplied(payload.Frame());
}
