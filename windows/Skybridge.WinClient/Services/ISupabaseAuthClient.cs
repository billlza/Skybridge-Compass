using System;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  ISupabaseAuthClient — the account-identity seam the AccountSessionCoordinator owns.
//
//  This mirrors the Mac's Supabase email/password sign-in: the Windows app talks to the
//  same GoTrue (auth/v1) endpoints with the client-safe publishable apikey the Mac bundles,
//  so the sidebar account block can show the REAL signed-in user (display name, NEBULA id,
//  avatar) instead of a placeholder. Every method is async and returns a typed result so
//  authentication failure, revocation, network failure, and malformed server data remain
//  distinguishable at the account lifecycle boundary.
//
//  Contract types are plain System.Text.Json records with snake_case [JsonPropertyName]
//  attributes matching the GoTrue / PostgREST JSON wire shape exactly.
// =====================================================================================

public interface ISupabaseAuthClient
{
    // Exact JWT authority accepted by this client. The coordinator persists this value
    // beside the subject and refuses sessions from another Supabase project/audience/role.
    SessionAuthority SessionAuthority { get; }

    // POST {BASE}/auth/v1/token?grant_type=password — exchanges email+password for a token
    // bundle (access/refresh + the embedded user with user_metadata).
    Task<AuthClientResult<AuthToken>> SignInWithPasswordAsync(string email, string password);

    // POST {BASE}/auth/v1/token?grant_type=refresh_token — swaps a refresh token for a new
    // access token when the persisted JWT is near/at expiry.
    Task<AuthClientResult<AuthToken>> RefreshAsync(string refreshToken);

    // GET {BASE}/auth/v1/user — re-reads the current user (and its user_metadata) with a
    // live access token. Falls back to the user_profiles REST row if user_metadata is thin.
    Task<AuthClientResult<AuthUser>> GetUserAsync(string accessToken, string? userId = null);

    // POST {BASE}/auth/v1/logout?scope=local — server-side token revoke. Local sign-out can
    // still proceed after a failure, but the failure is observable to the coordinator.
    Task<AuthClientResult<AuthSignOutReceipt>> SignOutAsync(string accessToken);
}

public enum AuthFailureKind
{
    InvalidInput,
    InvalidCredentials,
    Unauthorized,
    Forbidden,
    HttpFailure,
    Timeout,
    Network,
    InvalidJson,
    InvalidResponse,
    MissingAccessToken,
    MissingRefreshToken,
    SubjectMismatch
}

public sealed record AuthClientFailure(AuthFailureKind Kind, string Code)
{
    public static AuthClientFailure Create(AuthFailureKind kind, string code) => new(kind, code);
}

public sealed record AuthClientResult<T>
    where T : class
{
    private AuthClientResult(T? value, AuthClientFailure? failure)
    {
        Value = value;
        Failure = failure;
    }

    public T? Value { get; }

    public AuthClientFailure? Failure { get; }

    public bool Succeeded => Failure is null;

    public static AuthClientResult<T> Success(T value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return new(value, null);
    }

    public static AuthClientResult<T> Failed(AuthFailureKind kind, string code) =>
        new(default, AuthClientFailure.Create(kind, code));
}

public sealed record AuthSignOutReceipt(bool ServerRevoked);

public sealed record SessionAuthority(
    [property: JsonPropertyName("issuer")] string Issuer,
    [property: JsonPropertyName("audience")] string Audience,
    [property: JsonPropertyName("role")] string Role)
{
    public static SessionAuthority ForSupabaseProject(string baseUrl)
    {
        var normalizedBaseUrl = NormalizeSupabaseBaseUrl(baseUrl);
        return new SessionAuthority(
            $"{normalizedBaseUrl}/auth/v1",
            "authenticated",
            "authenticated");
    }

    internal static string NormalizeSupabaseBaseUrl(string baseUrl)
    {
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            throw new ArgumentException("Supabase base URL is required.", nameof(baseUrl));
        }

        var normalized = baseUrl.TrimEnd('/');
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(uri.Host)
            || !string.IsNullOrEmpty(uri.UserInfo)
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new ArgumentException("Supabase base URL must be an HTTPS origin without credentials, query, or fragment.", nameof(baseUrl));
        }

        return normalized;
    }

    internal bool IsWellFormed()
    {
        if (!Uri.TryCreate(Issuer, UriKind.Absolute, out var issuer)
            || issuer.Scheme != Uri.UriSchemeHttps
            || !string.IsNullOrEmpty(issuer.UserInfo)
            || !string.IsNullOrEmpty(issuer.Query)
            || !string.IsNullOrEmpty(issuer.Fragment)
            || !issuer.AbsolutePath.EndsWith("/auth/v1", StringComparison.Ordinal))
        {
            return false;
        }

        return IsBoundedVisibleValue(Audience) && IsBoundedVisibleValue(Role);
    }

    private static bool IsBoundedVisibleValue(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Length <= 128
        && !value.Any(char.IsControl);
}

internal sealed record ValidatedSessionToken(
    string Issuer,
    string Subject,
    long ExpiresAtUnix,
    string Role,
    string Audience);

// This validator binds unverified JWT claims to the exact Supabase authority and subject.
// It does not pretend to verify the JWT signature: AccountSessionCoordinator must always call
// /auth/v1/user with the token before publishing or persisting an authenticated identity.
internal static class SessionJwtValidator
{
    private const int MaxEncodedJwtChars = 64 * 1024;
    private const int MaxEncodedPayloadChars = 32 * 1024;
    private const long MaxUnixSeconds = 253402300799;

    public static bool TryValidate(
        string? jwt,
        SessionAuthority authority,
        string? expectedSubject,
        bool requireUnexpired,
        out ValidatedSessionToken? token,
        out string errorCode)
    {
        token = null;
        errorCode = string.Empty;

        if (!authority.IsWellFormed())
        {
            errorCode = "auth_authority_invalid";
            return false;
        }

        if (string.IsNullOrWhiteSpace(jwt))
        {
            errorCode = "auth_token_missing";
            return false;
        }

        if (jwt.Length > MaxEncodedJwtChars)
        {
            errorCode = "auth_token_too_large";
            return false;
        }

        var segments = jwt.Split('.');
        if (segments.Length != 3
            || segments.Any(string.IsNullOrWhiteSpace)
            || segments[1].Length > MaxEncodedPayloadChars)
        {
            errorCode = "auth_token_malformed";
            return false;
        }

        try
        {
            var payloadBytes = Base64UrlDecode(segments[1]);
            using var document = JsonDocument.Parse(payloadBytes);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                errorCode = "auth_token_payload_invalid";
                return false;
            }

            if (!TryReadRequiredString(root, "iss", out var issuer)
                || !string.Equals(issuer, authority.Issuer, StringComparison.Ordinal))
            {
                errorCode = "auth_authority_issuer_mismatch";
                return false;
            }

            if (!TryReadRequiredString(root, "sub", out var subject))
            {
                errorCode = "auth_subject_missing";
                return false;
            }

            if (!string.IsNullOrWhiteSpace(expectedSubject)
                && !string.Equals(subject, expectedSubject, StringComparison.Ordinal))
            {
                errorCode = "auth_subject_mismatch";
                return false;
            }

            if (!root.TryGetProperty("exp", out var expElement)
                || !expElement.TryGetInt64(out var expiresAtUnix)
                || expiresAtUnix <= 0
                || expiresAtUnix > MaxUnixSeconds)
            {
                errorCode = "auth_exp_invalid";
                return false;
            }

            if (requireUnexpired && expiresAtUnix <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
            {
                errorCode = "auth_token_expired";
                return false;
            }

            if (!TryReadRequiredString(root, "role", out var role)
                || !string.Equals(role, authority.Role, StringComparison.Ordinal))
            {
                errorCode = "auth_authority_role_mismatch";
                return false;
            }

            if (!TryReadRequiredString(root, "aud", out var audience)
                || !string.Equals(audience, authority.Audience, StringComparison.Ordinal))
            {
                errorCode = "auth_authority_audience_mismatch";
                return false;
            }

            token = new ValidatedSessionToken(issuer, subject, expiresAtUnix, role, audience);
            return true;
        }
        catch (FormatException)
        {
            errorCode = "auth_token_base64_invalid";
            return false;
        }
        catch (JsonException)
        {
            errorCode = "auth_token_json_invalid";
            return false;
        }
    }

    private static bool TryReadRequiredString(JsonElement root, string propertyName, out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(propertyName, out var element)
            || element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = element.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value) && value.Length <= 2048 && !value.Any(char.IsControl);
    }

    private static byte[] Base64UrlDecode(string segment)
    {
        var normalized = segment.Replace('-', '+').Replace('_', '/');
        normalized = (normalized.Length % 4) switch
        {
            0 => normalized,
            2 => normalized + "==",
            3 => normalized + "=",
            _ => throw new FormatException("Invalid base64url length.")
        };

        return Convert.FromBase64String(normalized);
    }
}

// ---- Wire records (snake_case GoTrue/PostgREST shapes) -------------------------------

public sealed record AuthToken
{
    [JsonPropertyName("access_token")]
    public string? AccessToken { get; init; }

    [JsonPropertyName("refresh_token")]
    public string? RefreshToken { get; init; }

    [JsonPropertyName("expires_in")]
    public long ExpiresIn { get; init; }

    [JsonPropertyName("token_type")]
    public string? TokenType { get; init; }

    [JsonPropertyName("user")]
    public AuthUser? User { get; init; }
}

public sealed record AuthUser
{
    [JsonPropertyName("id")]
    public string? Id { get; init; }

    [JsonPropertyName("email")]
    public string? Email { get; init; }

    [JsonPropertyName("user_metadata")]
    public AuthUserMetadata? UserMetadata { get; init; }
}

public sealed record AuthUserMetadata
{
    [JsonPropertyName("display_name")]
    public string? DisplayName { get; init; }

    [JsonPropertyName("nebula_id")]
    public string? NebulaId { get; init; }

    [JsonPropertyName("full_name")]
    public string? FullName { get; init; }

    [JsonPropertyName("avatar_url")]
    public string? AvatarUrl { get; init; }

    // Optional contact fields surfaced in the user-profile overlay (邮箱 / 手机号). GoTrue
    // stores phone in user_metadata for OTP sign-ups; email usually lives on the top-level
    // AuthUser.Email but can also appear here. Both degrade to "未绑定" in the overlay when
    // empty — never fabricated.
    [JsonPropertyName("email")]
    public string? Email { get; init; }

    [JsonPropertyName("phone")]
    public string? Phone { get; init; }
}

// PostgREST row from the public user_profiles table — the fallback identity source when
// user_metadata is empty (e.g. a profile populated by a DB trigger rather than at sign-up).
public sealed record UserProfileRow
{
    [JsonPropertyName("full_name")]
    public string? FullName { get; init; }

    [JsonPropertyName("nebula_id")]
    public string? NebulaId { get; init; }

    [JsonPropertyName("avatar_url")]
    public string? AvatarUrl { get; init; }
}
