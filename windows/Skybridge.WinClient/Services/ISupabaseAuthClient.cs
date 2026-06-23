using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  ISupabaseAuthClient — the account-identity seam the AccountSessionCoordinator owns.
//
//  This mirrors the Mac's Supabase email/password sign-in: the Windows app talks to the
//  same GoTrue (auth/v1) endpoints with the client-safe publishable apikey the Mac bundles,
//  so the sidebar account block can show the REAL signed-in user (display name, NEBULA id,
//  avatar) instead of a placeholder. Every method is async and degrades to a null/no-throw
//  result on failure so nothing can ever bubble an exception into the UI thread.
//
//  Contract types are plain System.Text.Json records with snake_case [JsonPropertyName]
//  attributes matching the GoTrue / PostgREST JSON wire shape exactly.
// =====================================================================================

public interface ISupabaseAuthClient
{
    // POST {BASE}/auth/v1/token?grant_type=password — exchanges email+password for a token
    // bundle (access/refresh + the embedded user with user_metadata). Returns null on any
    // failure (bad credentials, network, parse) so the dialog can show a generic error.
    Task<AuthToken?> SignInWithPasswordAsync(string email, string password);

    // POST {BASE}/auth/v1/token?grant_type=refresh_token — swaps a refresh token for a new
    // access token when the persisted JWT is near/at expiry. Returns null on failure.
    Task<AuthToken?> RefreshAsync(string refreshToken);

    // GET {BASE}/auth/v1/user — re-reads the current user (and its user_metadata) with a
    // live access token. Falls back to the user_profiles REST row if user_metadata is thin.
    // Returns null on failure.
    Task<AuthUser?> GetUserAsync(string accessToken, string? userId = null);

    // POST {BASE}/auth/v1/logout?scope=local — best-effort server-side token revoke. Never
    // throws; a failure here does not block the local sign-out (store clear) that follows.
    Task SignOutAsync(string accessToken);
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
