using System;
using System.Collections.Generic;
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
//  short per-request timeouts, and EVERY public method wrapped so it returns a
//  result-or-null and NEVER throws into the UI. System.Text.Json with snake_case
//  [JsonPropertyName] records (see ISupabaseAuthClient.cs) handles the wire shape.
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

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(12)
        };
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        return client;
    }

    public async Task<AuthToken?> SignInWithPasswordAsync(string email, string password)
    {
        try
        {
            var body = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["email"] = email,
                ["password"] = password
            });

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{BaseUrl}/auth/v1/token?grant_type=password")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
            request.Headers.TryAddWithoutValidation("apikey", PublishableKey);

            return await SendForTokenAsync(request).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Bad credentials, network, parse — surface as null so the dialog shows a
            // generic, non-leaky error and the UI never sees an exception.
            return null;
        }
    }

    public async Task<AuthToken?> RefreshAsync(string refreshToken)
    {
        try
        {
            var body = JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["refresh_token"] = refreshToken
            });

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{BaseUrl}/auth/v1/token?grant_type=refresh_token")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
            request.Headers.TryAddWithoutValidation("apikey", PublishableKey);

            return await SendForTokenAsync(request).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public async Task<AuthUser?> GetUserAsync(string accessToken, string? userId = null)
    {
        try
        {
            using var cts = new CancellationTokenSource(RequestTimeout);

            using var request = new HttpRequestMessage(HttpMethod.Get, $"{BaseUrl}/auth/v1/user");
            request.Headers.TryAddWithoutValidation("apikey", PublishableKey);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await HttpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return await FetchProfileFallbackAsync(accessToken, userId).ConfigureAwait(false);
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
            var user = await JsonSerializer
                .DeserializeAsync<AuthUser>(stream, JsonOptions, cts.Token)
                .ConfigureAwait(false);

            // If user_metadata is missing/empty, enrich from the user_profiles REST row.
            if (user is null || IsMetadataThin(user.UserMetadata))
            {
                var profile = await FetchProfileFallbackAsync(
                    accessToken,
                    userId ?? user?.Id).ConfigureAwait(false);
                if (profile is not null)
                {
                    return profile with
                    {
                        Id = user?.Id ?? profile.Id,
                        Email = user?.Email ?? profile.Email
                    };
                }
            }

            return user;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public async Task SignOutAsync(string accessToken)
    {
        try
        {
            using var cts = new CancellationTokenSource(RequestTimeout);

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{BaseUrl}/auth/v1/logout?scope=local");
            request.Headers.TryAddWithoutValidation("apikey", PublishableKey);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await HttpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
            _ = response.IsSuccessStatusCode; // best-effort: ignore outcome
        }
        catch (Exception)
        {
            // Best-effort: a failed server revoke must not block the local sign-out.
        }
    }

    // ---- Internals ------------------------------------------------------------------

    private static async Task<AuthToken?> SendForTokenAsync(HttpRequestMessage request)
    {
        using var cts = new CancellationTokenSource(RequestTimeout);
        using var response = await HttpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
        var token = await JsonSerializer
            .DeserializeAsync<AuthToken>(stream, JsonOptions, cts.Token)
            .ConfigureAwait(false);

        // A 200 with no access_token is not a usable session — treat as failure.
        return string.IsNullOrWhiteSpace(token?.AccessToken) ? null : token;
    }

    // GET {BASE}/rest/v1/user_profiles?select=full_name,nebula_id,avatar_url&id=eq.{userId}
    // Returns an AuthUser carrying just the profile metadata, or null on any failure.
    private static async Task<AuthUser?> FetchProfileFallbackAsync(string accessToken, string? userId)
    {
        if (string.IsNullOrWhiteSpace(userId))
        {
            return null;
        }

        try
        {
            using var cts = new CancellationTokenSource(RequestTimeout);

            var url =
                $"{BaseUrl}/rest/v1/user_profiles" +
                $"?select=full_name,nebula_id,avatar_url&id=eq.{Uri.EscapeDataString(userId)}";

            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("apikey", PublishableKey);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await HttpClient.SendAsync(request, cts.Token).ConfigureAwait(false);
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
        catch (Exception)
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
}
