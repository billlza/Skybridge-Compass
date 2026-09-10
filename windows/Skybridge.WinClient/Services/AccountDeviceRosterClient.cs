using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  AccountDeviceRosterClient — "which devices are on this account".
//
//  WHY THIS EXISTS
//  Device Discovery until now could only answer "what is on this LAN", because it is built
//  on DNS-SD. mDNS does not cross a subnet, so two machines signed into the same account on
//  a wired VLAN and a wireless VLAN — which is the normal shape of an office or an internet
//  cafe — can never see each other, no matter how the browse path is tuned. The account is
//  the one thing that already spans both.
//
//  THIS IS NOT A NEW BACKEND CONTRACT. The signaling server has carried a per-user device
//  registry all along (Server/skybridge-signaling/sql/security_v5.sql):
//
//      create table public.registered_devices (
//          tenant_id uuid, user_id uuid, device_id text,
//          device_name text default 'Unknown Device',
//          protocol_signing_algorithm text, protocol_public_key_fingerprint text,
//          status text check (status in ('pending','active','frozen','revoked')),
//          registered_at timestamptz, last_seen_at timestamptz, ...)
//
//  and Server/skybridge-signaling/lib/registry_store.js already reads it two ways: with the
//  service-role key from the server, or with the anon key plus a USER ACCESS TOKEN. This
//  client is the second path — the one no SkyBridge client had ever implemented.
//
//  FAIL-CLOSED, AND NEVER INVENTED
//  Every failure produces an empty roster carrying the reason. There is no partial list, no
//  cached last-known-good passed off as current, and no derived "online" boolean: `Status`
//  and `LastSeenAt` are reported exactly as the server stores them, and how stale is too
//  stale is a presentation decision, not something this client should silently decide. A
//  device the caller cannot prove is registered must not appear as if it were.
// =====================================================================================

/// <summary>Why a roster load produced no devices. <see cref="None"/> means the account
/// genuinely has none registered, which is different from every other value here.</summary>
public enum AccountDeviceRosterFailure
{
    None = 0,
    NotSignedIn,
    Unauthorized,
    Network,
    MalformedResponse,
    ServerError
}

/// <summary>One row of <c>registered_devices</c>, reported as stored.</summary>
public sealed record AccountDeviceEntry(
    string DeviceId,
    string DeviceName,
    string Status,
    DateTimeOffset? LastSeenAt,
    string? KeyFingerprint);

/// <summary>Result of one roster read. <see cref="Devices"/> is empty whenever
/// <see cref="Failure"/> is anything other than <see cref="AccountDeviceRosterFailure.None"/>.</summary>
public sealed record AccountDeviceRosterSnapshot(
    IReadOnlyList<AccountDeviceEntry> Devices,
    AccountDeviceRosterFailure Failure)
{
    public static AccountDeviceRosterSnapshot Empty(AccountDeviceRosterFailure failure) =>
        new(Array.Empty<AccountDeviceEntry>(), failure);

    public bool Trusted => Failure == AccountDeviceRosterFailure.None;
}

/// <summary>The signed-in identity a roster read is performed as. Both halves are required:
/// the user id scopes the query, the access token authorizes it.</summary>
public readonly record struct AccountDeviceRosterRequest(string? UserId, string? AccessToken);

public interface IAccountDeviceRosterClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(AccountDeviceRosterSnapshot snapshot);

    Task<AccountDeviceRosterSnapshot> LoadAsync(
        AccountDeviceRosterRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class AccountDeviceRosterClient : IAccountDeviceRosterClient
{
    // The columns this client is willing to consume. Selecting explicitly (rather than *)
    // keeps a schema addition on the server from silently changing what the client parses.
    private const string SelectedColumns =
        "device_id,device_name,status,last_seen_at,protocol_public_key_fingerprint";

    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(8);

    private readonly HttpClient _httpClient;
    private readonly string _baseUrl;
    private readonly string _publishableKey;

    public AccountDeviceRosterClient(HttpClient httpClient, string baseUrl, string publishableKey)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _baseUrl = SessionAuthority.NormalizeSupabaseBaseUrl(baseUrl);
        _publishableKey = string.IsNullOrWhiteSpace(publishableKey)
            ? throw new ArgumentException("A publishable key is required.", nameof(publishableKey))
            : publishableKey.Trim();
    }

    public string BuildInitialStatus() => "Account devices not loaded";

    public string BuildPendingStatus() => "Loading account devices…";

    public string BuildCompletedStatus(AccountDeviceRosterSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);

        return snapshot.Failure switch
        {
            AccountDeviceRosterFailure.None when snapshot.Devices.Count == 0 =>
                "No devices registered on this account",
            AccountDeviceRosterFailure.None =>
                $"{snapshot.Devices.Count} device(s) on this account",
            AccountDeviceRosterFailure.NotSignedIn => "Sign in to list account devices",
            AccountDeviceRosterFailure.Unauthorized => "Account devices unavailable · session rejected",
            AccountDeviceRosterFailure.Network => "Account devices unavailable · network",
            AccountDeviceRosterFailure.MalformedResponse => "Account devices unavailable · unreadable response",
            _ => "Account devices unavailable"
        };
    }

    public async Task<AccountDeviceRosterSnapshot> LoadAsync(
        AccountDeviceRosterRequest request,
        CancellationToken cancellationToken = default)
    {
        var userId = request.UserId?.Trim();
        var accessToken = request.AccessToken?.Trim();

        // Both halves must be present. Querying without a token would return the anon view,
        // which is not this user's roster, so treat a half-identity as not signed in rather
        // than issuing a request whose result would be meaningless.
        if (string.IsNullOrEmpty(userId) || string.IsNullOrEmpty(accessToken))
        {
            return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.NotSignedIn);
        }

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(RequestTimeout);

            var uri =
                $"{_baseUrl}/rest/v1/registered_devices" +
                $"?user_id=eq.{Uri.EscapeDataString(userId)}" +
                $"&select={SelectedColumns}" +
                "&order=last_seen_at.desc.nullslast";

            using var httpRequest = new HttpRequestMessage(HttpMethod.Get, uri);
            httpRequest.Headers.TryAddWithoutValidation("apikey", _publishableKey);
            httpRequest.Headers.TryAddWithoutValidation("Authorization", $"Bearer {accessToken}");
            httpRequest.Headers.TryAddWithoutValidation("Accept", "application/json");

            using var response = await _httpClient
                .SendAsync(httpRequest, HttpCompletionOption.ResponseContentRead, cts.Token)
                .ConfigureAwait(false);

            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.Unauthorized);
            }

            if (!response.IsSuccessStatusCode)
            {
                return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.ServerError);
            }

            var body = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            return Parse(body);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.Network);
        }
        catch (JsonException)
        {
            return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.MalformedResponse);
        }
    }

    private static AccountDeviceRosterSnapshot Parse(string body)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(body);
        }
        catch (JsonException)
        {
            return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.MalformedResponse);
        }

        using (document)
        {
            // PostgREST returns a JSON array for a collection read. Anything else means we are
            // not talking to the endpoint we think we are (a proxy error page, an RPC shape),
            // and guessing at it would be how a fabricated device list gets in.
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.MalformedResponse);
            }

            var devices = new List<AccountDeviceEntry>();
            foreach (var element in document.RootElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object)
                {
                    return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.MalformedResponse);
                }

                var deviceId = ReadString(element, "device_id");
                var status = ReadString(element, "status");

                // A row without an id or a status is not a device we can act on or describe.
                // Dropping just that row would quietly shrink the roster, so the whole read
                // fails instead — an incomplete list the user believes is complete is worse
                // than an honest error.
                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(status))
                {
                    return AccountDeviceRosterSnapshot.Empty(AccountDeviceRosterFailure.MalformedResponse);
                }

                var name = ReadString(element, "device_name");
                devices.Add(new AccountDeviceEntry(
                    deviceId!,
                    string.IsNullOrWhiteSpace(name) ? "Unknown Device" : name!,
                    status!,
                    ReadTimestamp(element, "last_seen_at"),
                    ReadString(element, "protocol_public_key_fingerprint")));
            }

            return new AccountDeviceRosterSnapshot(devices.AsReadOnly(), AccountDeviceRosterFailure.None);
        }
    }

    private static string? ReadString(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static DateTimeOffset? ReadTimestamp(JsonElement element, string property)
    {
        var raw = ReadString(element, property);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        // An unparseable timestamp becomes "unknown", not "now" and not a load failure: the
        // device is still real and still listable, we simply cannot say when it was last seen.
        return DateTimeOffset.TryParse(
            raw,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal,
            out var parsed)
            ? parsed
            : null;
    }
}
