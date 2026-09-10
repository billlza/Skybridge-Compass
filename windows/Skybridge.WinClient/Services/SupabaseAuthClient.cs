using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  SupabaseAuthClient — REAL email/password sign-in against the project's Supabase
//  GoTrue (auth/v1) + PostgREST (rest/v1) endpoints, using the SAME client-safe
//  publishable apikey the Mac bundles. It is the Windows equivalent of the Mac account
//  identity fetch: it returns the real signed-in user (display name / NEBULA id / avatar)
//  so the sidebar account block stops showing a placeholder.
//
//  House idiom (mirrors WeatherClient): one static cached HttpClient for the whole app,
//  short per-request timeouts, and typed failure results at the network/JSON/auth
//  boundary. System.Text.Json with snake_case [JsonPropertyName] records (see
//  ISupabaseAuthClient.cs) handles the wire shape.
//
//  The apikey below is the publishable (anon) key — it is deliberately client-safe and is
//  exactly what the Mac app ships in its bundle; it grants only the anon-role surface
//  (sign-in + RLS-guarded reads), never service-role access.
// =====================================================================================

public sealed class SupabaseAuthClient : ISupabaseAuthClient
{
    private const string BaseUrl = "https://hloqytmhjludmuhwyyzb.supabase.co";

    // Publishable (client-safe) apikey — the same key the Mac app bundles. Sent as the
    // `apikey` header on every request; for authenticated calls an `Authorization: Bearer`
    // access token is sent alongside it.
    private const string PublishableKey = "sb_publishable_SonH4HoPQBQxHG_1KQZH-A_Om5mY6RR";

    // One cached client for the whole app (idiomatic; the project has no DI container — see
    // WeatherClient). 10 s ceiling guards the per-request attempts so a hung socket can
    // never wedge sign-in or hydration forever.
    private static readonly HttpClient HttpClient = CreateHttpClient();

    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _httpClient;
    private readonly string _baseUrl;
    private readonly string _publishableKey;

    public SupabaseAuthClient()
        : this(HttpClient, BaseUrl, PublishableKey)
    {
    }

    public SupabaseAuthClient(HttpClient httpClient, string baseUrl = BaseUrl, string publishableKey = PublishableKey)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _baseUrl = global::Skybridge.WinClient.Services.SessionAuthority.NormalizeSupabaseBaseUrl(baseUrl);
        _publishableKey = string.IsNullOrWhiteSpace(publishableKey)
            ? throw new ArgumentException("Publishable key is required.", nameof(publishableKey))
            : publishableKey;
        SessionAuthority = global::Skybridge.WinClient.Services.SessionAuthority.ForSupabaseProject(_baseUrl);
    }

    public SessionAuthority SessionAuthority { get; }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(12)
        };
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        return client;
    }

    public async Task<AuthClientResult<AuthToken>> SignInWithPasswordAsync(string email, string password)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(email) || string.IsNullOrEmpty(password))
            {
                return AuthClientResult<AuthToken>.Failed(AuthFailureKind.InvalidInput, "auth_input_missing");
            }

            var body = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["email"] = email,
                ["password"] = password
            });

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{_baseUrl}/auth/v1/token?grant_type=password")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
            request.Headers.TryAddWithoutValidation("apikey", _publishableKey);

            return await SendForTokenAsync(request, AuthFailureKind.InvalidCredentials)
                .ConfigureAwait(false);
        }
        catch (Exception ex) when (IsAuthBoundaryException(ex))
        {
            return TokenExceptionFailure(ex, "auth_sign_in_failed");
        }
    }

    public async Task<AuthClientResult<AuthToken>> RefreshAsync(string refreshToken)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(refreshToken))
            {
                return AuthClientResult<AuthToken>.Failed(AuthFailureKind.InvalidInput, "refresh_token_missing");
            }

            var body = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["refresh_token"] = refreshToken
            });

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{_baseUrl}/auth/v1/token?grant_type=refresh_token")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
            request.Headers.TryAddWithoutValidation("apikey", _publishableKey);

            return await SendForTokenAsync(request, AuthFailureKind.Unauthorized)
                .ConfigureAwait(false);
        }
        catch (Exception ex) when (IsAuthBoundaryException(ex))
        {
            return TokenExceptionFailure(ex, "auth_refresh_failed");
        }
    }

    public async Task<AuthClientResult<AuthUser>> GetUserAsync(string accessToken, string? userId = null)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(accessToken))
            {
                return AuthClientResult<AuthUser>.Failed(AuthFailureKind.InvalidInput, "access_token_missing");
            }

            using var cts = new CancellationTokenSource(RequestTimeout);

            using var request = new HttpRequestMessage(HttpMethod.Get, $"{_baseUrl}/auth/v1/user");
            request.Headers.TryAddWithoutValidation("apikey", _publishableKey);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await _httpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return AuthClientResult<AuthUser>.Failed(
                    MapHttpFailure(response.StatusCode, AuthFailureKind.Unauthorized),
                    "auth_user_rejected");
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
            var deserializedUser = await JsonSerializer
                .DeserializeAsync<AuthUser>(stream, JsonOptions, cts.Token)
                .ConfigureAwait(false);
            if (deserializedUser is not { } user)
            {
                return AuthClientResult<AuthUser>.Failed(AuthFailureKind.InvalidResponse, "auth_user_empty");
            }

            if (string.IsNullOrWhiteSpace(user.Id))
            {
                return AuthClientResult<AuthUser>.Failed(AuthFailureKind.InvalidResponse, "auth_user_subject_missing");
            }

            if (!string.IsNullOrWhiteSpace(userId)
                && !string.Equals(user.Id, userId, StringComparison.Ordinal))
            {
                return AuthClientResult<AuthUser>.Failed(AuthFailureKind.SubjectMismatch, "auth_user_subject_mismatch");
            }

            // If user_metadata is missing/empty, enrich from the user_profiles REST row.
            if (IsMetadataThin(user.UserMetadata))
            {
                var profile = await FetchProfileFallbackAsync(
                    accessToken,
                    user.Id).ConfigureAwait(false);
                if (profile is not null)
                {
                    return AuthClientResult<AuthUser>.Success(profile with
                    {
                        Id = user.Id ?? profile.Id,
                        Email = user.Email ?? profile.Email
                    });
                }
            }

            return AuthClientResult<AuthUser>.Success(user);
        }
        catch (Exception ex) when (IsAuthBoundaryException(ex))
        {
            return UserExceptionFailure(ex, "auth_user_failed");
        }
    }

    public async Task<AuthClientResult<AuthSignOutReceipt>> SignOutAsync(string accessToken)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(accessToken))
            {
                return AuthClientResult<AuthSignOutReceipt>.Failed(
                    AuthFailureKind.InvalidInput,
                    "access_token_missing");
            }

            using var cts = new CancellationTokenSource(RequestTimeout);

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{_baseUrl}/auth/v1/logout?scope=local");
            request.Headers.TryAddWithoutValidation("apikey", _publishableKey);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await _httpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return AuthClientResult<AuthSignOutReceipt>.Failed(
                    MapHttpFailure(response.StatusCode, AuthFailureKind.HttpFailure),
                    "auth_sign_out_rejected");
            }

            return AuthClientResult<AuthSignOutReceipt>.Success(new AuthSignOutReceipt(ServerRevoked: true));
        }
        catch (Exception ex) when (IsAuthBoundaryException(ex))
        {
            return SignOutExceptionFailure(ex, "auth_sign_out_failed");
        }
    }

    // ---- Internals ------------------------------------------------------------------

    private async Task<AuthClientResult<AuthToken>> SendForTokenAsync(
        HttpRequestMessage request,
        AuthFailureKind defaultFailureKind)
    {
        using var cts = new CancellationTokenSource(RequestTimeout);
        using var response = await _httpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            return AuthClientResult<AuthToken>.Failed(
                MapHttpFailure(response.StatusCode, defaultFailureKind),
                "auth_token_rejected");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
        var token = await JsonSerializer
            .DeserializeAsync<AuthToken>(stream, JsonOptions, cts.Token)
            .ConfigureAwait(false);

        if (token is null)
        {
            return AuthClientResult<AuthToken>.Failed(AuthFailureKind.InvalidResponse, "auth_token_empty");
        }

        // A 200 with no access_token is not a usable session.
        if (string.IsNullOrWhiteSpace(token.AccessToken))
        {
            return AuthClientResult<AuthToken>.Failed(
                AuthFailureKind.MissingAccessToken,
                "auth_token_missing_access_token");
        }

        if (string.IsNullOrWhiteSpace(token.RefreshToken))
        {
            return AuthClientResult<AuthToken>.Failed(
                AuthFailureKind.MissingRefreshToken,
                "auth_token_missing_refresh_token");
        }

        return AuthClientResult<AuthToken>.Success(token);
    }

    // GET {BASE}/rest/v1/user_profiles?select=full_name,nebula_id,avatar_url&id=eq.{userId}
    // Returns an AuthUser carrying just the profile metadata, or null on any failure.
    private async Task<AuthUser?> FetchProfileFallbackAsync(string accessToken, string? userId)
    {
        if (string.IsNullOrWhiteSpace(userId))
        {
            return null;
        }

        try
        {
            using var cts = new CancellationTokenSource(RequestTimeout);

            var url =
                $"{_baseUrl}/rest/v1/user_profiles" +
                $"?select=full_name,nebula_id,avatar_url&id=eq.{Uri.EscapeDataString(userId)}";

            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("apikey", _publishableKey);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await _httpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
            // PostgREST returns a JSON array; take the first row if present.
            var rows = await JsonSerializer
                .DeserializeAsync<List<UserProfileRow>>(stream, JsonOptions, cts.Token)
                .ConfigureAwait(false);

            if (rows is null || rows.Count == 0)
            {
                return null;
            }

            var row = rows[0];
            return new AuthUser
            {
                Id = userId,
                UserMetadata = new AuthUserMetadata
                {
                    FullName = row.FullName,
                    DisplayName = row.FullName,
                    NebulaId = row.NebulaId,
                    AvatarUrl = row.AvatarUrl
                }
            };
        }
        catch (Exception ex) when (IsAuthBoundaryException(ex))
        {
            return null;
        }
    }

    private static bool IsMetadataThin(AuthUserMetadata? metadata)
    {
        if (metadata is null)
        {
            return true;
        }

        return string.IsNullOrWhiteSpace(metadata.DisplayName)
            && string.IsNullOrWhiteSpace(metadata.FullName)
            && string.IsNullOrWhiteSpace(metadata.NebulaId)
            && string.IsNullOrWhiteSpace(metadata.AvatarUrl);
    }

    private static AuthFailureKind MapHttpFailure(HttpStatusCode statusCode, AuthFailureKind defaultFailureKind) =>
        statusCode switch
        {
            HttpStatusCode.BadRequest => defaultFailureKind,
            HttpStatusCode.Unauthorized => AuthFailureKind.Unauthorized,
            HttpStatusCode.Forbidden => AuthFailureKind.Forbidden,
            _ => AuthFailureKind.HttpFailure
        };

    private static AuthClientResult<AuthToken> TokenExceptionFailure(Exception ex, string code) =>
        AuthClientResult<AuthToken>.Failed(MapException(ex), code);

    private static AuthClientResult<AuthUser> UserExceptionFailure(Exception ex, string code) =>
        AuthClientResult<AuthUser>.Failed(MapException(ex), code);

    private static AuthClientResult<AuthSignOutReceipt> SignOutExceptionFailure(Exception ex, string code) =>
        AuthClientResult<AuthSignOutReceipt>.Failed(MapException(ex), code);

    private static AuthFailureKind MapException(Exception ex) =>
        ex switch
        {
            JsonException => AuthFailureKind.InvalidJson,
            TaskCanceledException => AuthFailureKind.Timeout,
            OperationCanceledException => AuthFailureKind.Timeout,
            HttpRequestException => AuthFailureKind.Network,
            IOException => AuthFailureKind.Network,
            _ => AuthFailureKind.InvalidResponse
        };

    private static bool IsAuthBoundaryException(Exception ex) =>
        ex is JsonException
            or TaskCanceledException
            or OperationCanceledException
            or HttpRequestException
            or IOException;
}
