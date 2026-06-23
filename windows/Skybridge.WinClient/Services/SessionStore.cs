using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  SessionStore — at-rest persistence of the signed-in account session so the sidebar
//  account block stays signed in across app launches (matching the Mac, which keeps the
//  Supabase session in the keychain).
//
//  The tokens are protected with Windows DPAPI (ProtectedData) scoped to the CURRENT USER:
//  the ciphertext can only be decrypted by the same Windows user on this machine, so a copy
//  of session.bin is useless to anyone else. The file lives under
//  %LOCALAPPDATA%\SkyBridge\session.bin.
//
//  Every method is defensive: Save swallows write/crypto failures (sign-in still succeeds
//  in-memory even if persistence fails), and Load returns null on ANY failure (missing
//  file, corrupt blob, crypto error, schema drift) so a bad/foreign blob never crashes the
//  app — it just behaves as "signed out".
// =====================================================================================

public sealed class SessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly string _directory;
    private readonly string _filePath;

    public SessionStore()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _directory = Path.Combine(localAppData, "SkyBridge");
        _filePath = Path.Combine(_directory, "session.bin");
    }

    public void Save(PersistedSession session)
    {
        try
        {
            Directory.CreateDirectory(_directory);

            var json = JsonSerializer.SerializeToUtf8Bytes(session, JsonOptions);
            var protectedBytes = ProtectedData.Protect(
                json,
                optionalEntropy: null,
                scope: DataProtectionScope.CurrentUser);

            File.WriteAllBytes(_filePath, protectedBytes);
        }
        catch (Exception)
        {
            // Persistence is best-effort: a failed write must not break an otherwise-good
            // in-memory sign-in. The user simply won't be remembered across launches.
        }
    }

    public PersistedSession? Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return null;
            }

            var protectedBytes = File.ReadAllBytes(_filePath);
            if (protectedBytes.Length == 0)
            {
                return null;
            }

            var json = ProtectedData.Unprotect(
                protectedBytes,
                optionalEntropy: null,
                scope: DataProtectionScope.CurrentUser);

            return JsonSerializer.Deserialize<PersistedSession>(
                Encoding.UTF8.GetString(json),
                JsonOptions);
        }
        catch (Exception)
        {
            // Corrupt blob, crypto failure (e.g. copied from another machine/user), schema
            // drift — treat as "no persisted session" rather than crashing.
            return null;
        }
    }

    public void Clear()
    {
        try
        {
            if (File.Exists(_filePath))
            {
                File.Delete(_filePath);
            }
        }
        catch (Exception)
        {
            // Nothing actionable if the delete fails; the next Save overwrites it anyway.
        }
    }
}

// The persisted identity + tokens. Kept deliberately small: enough to silently refresh and
// re-show the account block without a network round-trip on launch.
public sealed record PersistedSession
{
    [JsonPropertyName("accessToken")]
    public string? AccessToken { get; init; }

    [JsonPropertyName("refreshToken")]
    public string? RefreshToken { get; init; }

    [JsonPropertyName("userId")]
    public string? UserId { get; init; }

    [JsonPropertyName("nebulaId")]
    public string? NebulaId { get; init; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; init; }

    [JsonPropertyName("avatarUrl")]
    public string? AvatarUrl { get; init; }

    [JsonPropertyName("issuedAtUnix")]
    public long IssuedAtUnix { get; init; }
}
