using System;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
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
//  Missing state is the only quiet signed-out case. Corruption, crypto failure, invalid
//  schema, IO failure, save failure, and clear failure are typed results so the account
//  coordinator can fail closed instead of masking a broken persistence boundary.
// =====================================================================================

public interface ISessionStore
{
    SessionStoreLoadResult Load();

    SessionStoreWriteResult Save(PersistedSession session);

    SessionStoreWriteResult Clear();
}

public sealed class DpapiSessionProtector : ISessionProtector
{
    public byte[] Protect(byte[] bytes)
    {
        if (!IsWindowsDpapiSupported())
        {
            throw new PlatformNotSupportedException("SkyBridge Windows session protection requires Windows DPAPI.");
        }

        return ProtectedData.Protect(bytes, optionalEntropy: null, scope: DataProtectionScope.CurrentUser);
    }

    public byte[] Unprotect(byte[] bytes)
    {
        if (!IsWindowsDpapiSupported())
        {
            throw new PlatformNotSupportedException("SkyBridge Windows session protection requires Windows DPAPI.");
        }

        return ProtectedData.Unprotect(bytes, optionalEntropy: null, scope: DataProtectionScope.CurrentUser);
    }

    [SupportedOSPlatformGuard("windows")]
    private static bool IsWindowsDpapiSupported() => OperatingSystem.IsWindows();
}

public sealed class SessionStore : ISessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly string _directory;
    private readonly string _filePath;
    private readonly ISessionProtector _protector;
    private readonly ISessionFileCommitter _fileCommitter;

    public SessionStore(string? directory = null, ISessionProtector? protector = null)
        : this(
            directory ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SkyBridge"),
            protector ?? new DpapiSessionProtector(),
            AtomicSessionFileCommitter.Instance)
    {
    }

    internal SessionStore(
        string directory,
        ISessionProtector protector,
        ISessionFileCommitter fileCommitter)
    {
        _directory = string.IsNullOrWhiteSpace(directory)
            ? throw new ArgumentException("Session directory is required.", nameof(directory))
            : Path.GetFullPath(directory);
        _filePath = Path.Combine(_directory, "session.bin");
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
        _fileCommitter = fileCommitter ?? throw new ArgumentNullException(nameof(fileCommitter));
    }

    public SessionStoreWriteResult Save(PersistedSession session)
    {
        var validation = Validate(session);
        if (validation != PersistedSessionValidation.Valid)
        {
            return WriteValidationFailure(validation);
        }

        string? temporaryPath = null;
        SessionStoreWriteResult? result = null;
        try
        {
            Directory.CreateDirectory(_directory);

            var json = JsonSerializer.SerializeToUtf8Bytes(session, JsonOptions);
            var protectedBytes = _protector.Protect(json);
            temporaryPath = Path.Combine(
                _directory,
                $".session.bin.{Guid.NewGuid():N}.tmp");

            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                FileOptions.WriteThrough))
            {
                stream.Write(protectedBytes);
                stream.Flush(flushToDisk: true);
            }

            _fileCommitter.Commit(temporaryPath, _filePath);
            temporaryPath = null;
            result = SessionStoreWriteResult.Saved();
        }
        catch (CryptographicException)
        {
            result = SessionStoreWriteResult.CryptoFailure();
        }
        catch (PlatformNotSupportedException)
        {
            result = SessionStoreWriteResult.CryptoFailure();
        }
        catch (IOException)
        {
            result = SessionStoreWriteResult.IoFailure();
        }
        catch (UnauthorizedAccessException)
        {
            result = SessionStoreWriteResult.IoFailure();
        }
        finally
        {
            if (!TryDeleteTemporaryFileAfterFailedCommit(temporaryPath))
            {
                result = SessionStoreWriteResult.IoFailure();
            }
        }

        return result
            ?? throw new InvalidOperationException("Session save completed without a typed result.");
    }

    public SessionStoreLoadResult Load()
    {
        try
        {
            var protectedBytes = File.ReadAllBytes(_filePath);
            if (protectedBytes.Length == 0)
            {
                return SessionStoreLoadResult.EmptyFile();
            }

            var json = _protector.Unprotect(protectedBytes);
            var session = JsonSerializer.Deserialize<PersistedSession>(
                Encoding.UTF8.GetString(json),
                JsonOptions);

            return Validate(session) switch
            {
                PersistedSessionValidation.Valid => SessionStoreLoadResult.Loaded(session!),
                PersistedSessionValidation.SchemaMismatch => SessionStoreLoadResult.SchemaMismatch(),
                PersistedSessionValidation.AuthorityMismatch => SessionStoreLoadResult.AuthorityMismatch(),
                PersistedSessionValidation.SubjectMismatch => SessionStoreLoadResult.SubjectMismatch(),
                _ => SessionStoreLoadResult.InvalidSession()
            };
        }
        catch (CryptographicException)
        {
            return SessionStoreLoadResult.DecryptFailed();
        }
        catch (PlatformNotSupportedException)
        {
            return SessionStoreLoadResult.DecryptFailed();
        }
        catch (FileNotFoundException)
        {
            return SessionStoreLoadResult.Missing();
        }
        catch (DirectoryNotFoundException)
        {
            return SessionStoreLoadResult.Missing();
        }
        catch (JsonException)
        {
            return SessionStoreLoadResult.InvalidJson();
        }
        catch (IOException)
        {
            return SessionStoreLoadResult.IoFailure();
        }
        catch (UnauthorizedAccessException)
        {
            return SessionStoreLoadResult.IoFailure();
        }
    }

    public SessionStoreWriteResult Clear()
    {
        try
        {
            // File.Delete is already idempotent for a missing file. Calling it directly keeps
            // ACL and IO failures observable; File.Exists would collapse those failures to false.
            File.Delete(_filePath);
            return SessionStoreWriteResult.Cleared();
        }
        catch (FileNotFoundException)
        {
            return SessionStoreWriteResult.Cleared();
        }
        catch (DirectoryNotFoundException)
        {
            return SessionStoreWriteResult.Cleared();
        }
        catch (IOException)
        {
            return SessionStoreWriteResult.IoFailure();
        }
        catch (UnauthorizedAccessException)
        {
            return SessionStoreWriteResult.IoFailure();
        }
    }

    private static PersistedSessionValidation Validate(PersistedSession? session)
    {
        if (session is null)
        {
            return PersistedSessionValidation.InvalidSession;
        }

        if (session.SchemaVersion != PersistedSession.CurrentSchemaVersion)
        {
            return PersistedSessionValidation.SchemaMismatch;
        }

        if (session.Authority is null || !session.Authority.IsWellFormed())
        {
            return PersistedSessionValidation.AuthorityMismatch;
        }

        if (string.IsNullOrWhiteSpace(session.Subject)
            || session.Subject.Length > 2048
            || session.Subject.Any(char.IsControl))
        {
            return PersistedSessionValidation.SubjectMismatch;
        }

        if (string.IsNullOrWhiteSpace(session.RefreshToken) || session.IssuedAtUnix < 0)
        {
            return PersistedSessionValidation.InvalidSession;
        }

        if (!SessionJwtValidator.TryValidate(
                session.AccessToken,
                session.Authority,
                session.Subject,
                requireUnexpired: false,
                out _,
                out var tokenError))
        {
            if (tokenError.StartsWith("auth_authority_", StringComparison.Ordinal))
            {
                return PersistedSessionValidation.AuthorityMismatch;
            }

            return tokenError is "auth_subject_missing" or "auth_subject_mismatch"
                ? PersistedSessionValidation.SubjectMismatch
                : PersistedSessionValidation.InvalidSession;
        }

        return PersistedSessionValidation.Valid;
    }

    private static SessionStoreWriteResult WriteValidationFailure(PersistedSessionValidation validation) =>
        validation switch
        {
            PersistedSessionValidation.SchemaMismatch => SessionStoreWriteResult.SchemaMismatch(),
            PersistedSessionValidation.AuthorityMismatch => SessionStoreWriteResult.AuthorityMismatch(),
            PersistedSessionValidation.SubjectMismatch => SessionStoreWriteResult.SubjectMismatch(),
            _ => SessionStoreWriteResult.InvalidSession()
        };

    private static bool TryDeleteTemporaryFileAfterFailedCommit(string? temporaryPath)
    {
        if (string.IsNullOrWhiteSpace(temporaryPath))
        {
            return true;
        }

        try
        {
            File.Delete(temporaryPath);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private enum PersistedSessionValidation
    {
        Valid,
        SchemaMismatch,
        AuthorityMismatch,
        SubjectMismatch,
        InvalidSession
    }

}

public enum SessionStoreLoadStatus
{
    Loaded,
    Missing,
    EmptyFile,
    DecryptFailed,
    InvalidJson,
    SchemaMismatch,
    AuthorityMismatch,
    SubjectMismatch,
    InvalidSession,
    IoFailure
}

public sealed record SessionStoreLoadResult(SessionStoreLoadStatus Status, PersistedSession? Session)
{
    public bool Succeeded => Status == SessionStoreLoadStatus.Loaded && Session is not null;

    public bool IsQuietSignedOut => Status == SessionStoreLoadStatus.Missing;

    public static SessionStoreLoadResult Loaded(PersistedSession session) =>
        new(SessionStoreLoadStatus.Loaded, session);

    public static SessionStoreLoadResult Missing() => new(SessionStoreLoadStatus.Missing, null);

    public static SessionStoreLoadResult EmptyFile() => new(SessionStoreLoadStatus.EmptyFile, null);

    public static SessionStoreLoadResult DecryptFailed() => new(SessionStoreLoadStatus.DecryptFailed, null);

    public static SessionStoreLoadResult InvalidJson() => new(SessionStoreLoadStatus.InvalidJson, null);

    public static SessionStoreLoadResult SchemaMismatch() => new(SessionStoreLoadStatus.SchemaMismatch, null);

    public static SessionStoreLoadResult AuthorityMismatch() => new(SessionStoreLoadStatus.AuthorityMismatch, null);

    public static SessionStoreLoadResult SubjectMismatch() => new(SessionStoreLoadStatus.SubjectMismatch, null);

    public static SessionStoreLoadResult InvalidSession() => new(SessionStoreLoadStatus.InvalidSession, null);

    public static SessionStoreLoadResult IoFailure() => new(SessionStoreLoadStatus.IoFailure, null);
}

public enum SessionStoreWriteStatus
{
    Saved,
    Cleared,
    InvalidSession,
    SchemaMismatch,
    AuthorityMismatch,
    SubjectMismatch,
    CryptoFailure,
    IoFailure
}

public sealed record SessionStoreWriteResult(SessionStoreWriteStatus Status)
{
    public bool Succeeded =>
        Status is SessionStoreWriteStatus.Saved or SessionStoreWriteStatus.Cleared;

    public static SessionStoreWriteResult Saved() => new(SessionStoreWriteStatus.Saved);

    public static SessionStoreWriteResult Cleared() => new(SessionStoreWriteStatus.Cleared);

    public static SessionStoreWriteResult InvalidSession() => new(SessionStoreWriteStatus.InvalidSession);

    public static SessionStoreWriteResult SchemaMismatch() => new(SessionStoreWriteStatus.SchemaMismatch);

    public static SessionStoreWriteResult AuthorityMismatch() => new(SessionStoreWriteStatus.AuthorityMismatch);

    public static SessionStoreWriteResult SubjectMismatch() => new(SessionStoreWriteStatus.SubjectMismatch);

    public static SessionStoreWriteResult CryptoFailure() => new(SessionStoreWriteStatus.CryptoFailure);

    public static SessionStoreWriteResult IoFailure() => new(SessionStoreWriteStatus.IoFailure);
}

// The persisted identity + tokens. Kept deliberately small: enough to refresh and then
// re-show the account block only after the live Supabase authority accepts the session.
public sealed record PersistedSession
{
    public const int CurrentSchemaVersion = 1;

    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("authority")]
    public SessionAuthority? Authority { get; init; }

    [JsonPropertyName("subject")]
    public string? Subject { get; init; }

    [JsonPropertyName("accessToken")]
    public string? AccessToken { get; init; }

    [JsonPropertyName("refreshToken")]
    public string? RefreshToken { get; init; }

    [JsonPropertyName("nebulaId")]
    public string? NebulaId { get; init; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; init; }

    [JsonPropertyName("avatarUrl")]
    public string? AvatarUrl { get; init; }

    [JsonPropertyName("issuedAtUnix")]
    public long IssuedAtUnix { get; init; }
}
