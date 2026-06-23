using System;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  AccountSessionCoordinator — owns the entire account/identity lifecycle for the sidebar
//  account block, kept OUT of the SessionViewModel constructor and OUT of the DI root.
//
//  CRITICAL ARCHITECTURE RULE (the escape hatch): this coordinator SELF-PROVISIONS its
//  SupabaseAuthClient + SessionStore (exactly like WeatherStateCoordinator owns its own
//  IWeatherClient seam). It is NOT injected through SessionViewModelDependencies or any
//  *DependencyFactory — touching that composition root merges into the user's backend
//  wiring and breaks the build. The SessionViewModel just `new`s one of these.
//
//  It also OWNS the sign-out command (the `new AsyncRelayCommand(...)` lives HERE, never in
//  SessionViewModel — same command-ownership gate as WeatherStateCoordinator.RefreshCommand).
//
//  Identity flows out via the IdentityChanged event: the SessionViewModel subscribes and
//  forwards DisplayName / NebulaId / AvatarUrl / IsSignedIn into its SetField-backed props.
//  Continuations resume on the captured UI context (callers await on the UI thread), so the
//  forwarding setters run on the UI thread — no DispatcherQueue, matching the house idiom.
// =====================================================================================

public sealed class AccountSessionCoordinator
{
    private readonly ISupabaseAuthClient _authClient;
    private readonly SessionStore _sessionStore;

    private string? _accessToken;
    private string? _refreshToken;
    private string? _userId;

    // Refresh a little before the JWT actually expires so a call never races the boundary.
    private static readonly TimeSpan RefreshSkew = TimeSpan.FromMinutes(5);

    public AccountSessionCoordinator(ISupabaseAuthClient? authClient = null, SessionStore? sessionStore = null)
    {
        // Self-provision the real implementations by default (the whole point of the escape
        // hatch). Tests may pass fakes, but production never touches the DI root.
        _authClient = authClient ?? new SupabaseAuthClient();
        _sessionStore = sessionStore ?? new SessionStore();
        SignOutCommand = new AsyncRelayCommand(SignOutAsync);
    }

    // The account block binds the dialog trigger here: the VM forwards this so MainWindow can
    // construct the SignInDialog with the same client it will persist with.
    public ISupabaseAuthClient AuthClient => _authClient;

    // Owned here (NOT in SessionViewModel) so the `new AsyncRelayCommand(` ownership gate is
    // honored — the account block's sign-out affordance binds to this via the VM.
    public ICommand SignOutCommand { get; }

    // Raised whenever the resolved identity changes (sign-in, hydrate, sign-out). The VM
    // forwards the payload into its bindable props.
    public event EventHandler<AccountIdentity>? IdentityChanged;

    public bool IsSignedIn { get; private set; }

    public string DisplayName { get; private set; } = string.Empty;

    public string NebulaId { get; private set; } = string.Empty;

    public string AvatarUrl { get; private set; } = string.Empty;

    // Contact fields for the user-profile overlay (邮箱 / 手机号). Empty when unbound.
    public string Email { get; private set; } = string.Empty;

    public string PhoneNumber { get; private set; } = string.Empty;

    // ---- Sign-in -------------------------------------------------------------------

    // Called by MainWindow after a successful SignInDialog: persist the session and set the
    // identity from user_metadata, falling back to GetUser / user_profiles when thin.
    public async Task ApplyAuthAsync(AuthToken token)
    {
        if (token is null || string.IsNullOrWhiteSpace(token.AccessToken))
        {
            return;
        }

        _accessToken = token.AccessToken;
        _refreshToken = token.RefreshToken;
        _userId = token.User?.Id;

        var metadata = token.User?.UserMetadata;

        // If the token's embedded user_metadata is thin, re-fetch the full user (which itself
        // falls back to the user_profiles REST row inside the client).
        if (IsMetadataThin(metadata))
        {
            var user = await _authClient
                .GetUserAsync(token.AccessToken, _userId)
                .ConfigureAwait(true);
            if (user is not null)
            {
                _userId ??= user.Id;
                metadata = MergeMetadata(metadata, user.UserMetadata);
            }
        }

        ApplyIdentity(metadata, token.User?.Email);
        Persist();
    }

    // ---- Email sign-in (in-window AuthOverlay path) ---------------------------------

    // Called by the in-window AuthOverlay's 邮箱登录 button (via the VM). Validates non-empty
    // input, performs the REAL Supabase email/password sign-in through the owned auth client,
    // and on success applies + persists the identity. Returns a result the overlay binds to:
    // Success flips the overlay closed; a failure keeps it open with the inline error string.
    // NEVER throws — the auth client is result-or-null and any surprise is caught here.
    public async Task<EmailSignInResult> SignInWithEmailAsync(string email, string password)
    {
        var trimmedEmail = email?.Trim() ?? string.Empty;
        // The password is taken verbatim from user input — never trimmed-away or defaulted.
        var rawPassword = password ?? string.Empty;

        if (string.IsNullOrWhiteSpace(trimmedEmail) || string.IsNullOrEmpty(rawPassword))
        {
            return EmailSignInResult.Failed("请输入邮箱和密码。");
        }

        try
        {
            var token = await _authClient
                .SignInWithPasswordAsync(trimmedEmail, rawPassword)
                .ConfigureAwait(true);

            if (token is null || string.IsNullOrWhiteSpace(token.AccessToken))
            {
                return EmailSignInResult.Failed("登录失败，请检查邮箱和密码后重试。");
            }

            await ApplyAuthAsync(token).ConfigureAwait(true);
            return EmailSignInResult.Succeeded();
        }
        catch (Exception)
        {
            // The client never throws (result-or-null), but be defensive: any unexpected
            // failure shows a generic error rather than bubbling into the UI thread.
            return EmailSignInResult.Failed("登录失败，请稍后重试。");
        }
    }

    // ---- Hydrate on launch ----------------------------------------------------------

    // Load the persisted session; if the JWT is within the refresh skew of expiry, refresh it
    // first; then GetUser to re-confirm identity. Any failure leaves the block signed out.
    public async Task HydrateFromStoreAsync()
    {
        var persisted = _sessionStore.Load();
        if (persisted is null || string.IsNullOrWhiteSpace(persisted.AccessToken))
        {
            return;
        }

        _accessToken = persisted.AccessToken;
        _refreshToken = persisted.RefreshToken;
        _userId = persisted.UserId;

        // Show the persisted identity immediately (optimistic) so the block isn't blank while
        // the network refresh runs; a live GetUser below upgrades/corrects it.
        ApplyPersistedIdentity(persisted);

        // Refresh the access token if it is expired or within the skew window.
        if (NeedsRefresh(_accessToken) && !string.IsNullOrWhiteSpace(_refreshToken))
        {
            var refreshed = await _authClient.RefreshAsync(_refreshToken!).ConfigureAwait(true);
            if (refreshed is not null && !string.IsNullOrWhiteSpace(refreshed.AccessToken))
            {
                _accessToken = refreshed.AccessToken;
                _refreshToken = refreshed.RefreshToken ?? _refreshToken;
                _userId ??= refreshed.User?.Id;
            }
            else
            {
                // Refresh failed (revoked/expired refresh token): the persisted identity is
                // still shown optimistically, but we cannot make authenticated calls. Keep
                // the optimistic identity rather than forcing a sign-out blank — the next
                // sign-out/sign-in corrects state. Do not re-persist a dead token.
                return;
            }
        }

        // Re-confirm the live identity (and pick up any profile changes since last launch).
        var user = await _authClient
            .GetUserAsync(_accessToken!, _userId)
            .ConfigureAwait(true);
        if (user is not null)
        {
            _userId ??= user.Id;
            ApplyIdentity(user.UserMetadata, user.Email);
        }

        Persist();
    }

    // ---- Sign-out -------------------------------------------------------------------

    public async Task SignOutAsync()
    {
        var token = _accessToken;
        if (!string.IsNullOrWhiteSpace(token))
        {
            await _authClient.SignOutAsync(token!).ConfigureAwait(true);
        }

        _accessToken = null;
        _refreshToken = null;
        _userId = null;

        _sessionStore.Clear();

        IsSignedIn = false;
        DisplayName = string.Empty;
        NebulaId = string.Empty;
        AvatarUrl = string.Empty;
        Email = string.Empty;
        PhoneNumber = string.Empty;
        RaiseIdentityChanged();
    }

    // ---- Identity application -------------------------------------------------------

    private void ApplyIdentity(AuthUserMetadata? metadata, string? email)
    {
        var display = FirstNonEmpty(
            metadata?.DisplayName,
            metadata?.FullName,
            email);

        DisplayName = display ?? string.Empty;
        NebulaId = metadata?.NebulaId ?? string.Empty;
        AvatarUrl = metadata?.AvatarUrl ?? string.Empty;
        // Prefer the top-level AuthUser.Email; fall back to a metadata email if present.
        Email = FirstNonEmpty(email, metadata?.Email) ?? string.Empty;
        PhoneNumber = metadata?.Phone ?? string.Empty;
        IsSignedIn = !string.IsNullOrWhiteSpace(DisplayName) || !string.IsNullOrWhiteSpace(_accessToken);
        RaiseIdentityChanged();
    }

    private void ApplyPersistedIdentity(PersistedSession persisted)
    {
        DisplayName = persisted.DisplayName ?? string.Empty;
        NebulaId = persisted.NebulaId ?? string.Empty;
        AvatarUrl = persisted.AvatarUrl ?? string.Empty;
        // PersistedSession deliberately stays small (no email/phone); the live GetUser that
        // runs right after hydrate fills these in. Show empty (→ "未绑定") until then.
        Email = string.Empty;
        PhoneNumber = string.Empty;
        IsSignedIn = !string.IsNullOrWhiteSpace(_accessToken);
        RaiseIdentityChanged();
    }

    private void RaiseIdentityChanged()
    {
        IdentityChanged?.Invoke(this, new AccountIdentity(
            DisplayName, NebulaId, AvatarUrl, IsSignedIn, Email, PhoneNumber));
    }

    private void Persist()
    {
        if (string.IsNullOrWhiteSpace(_accessToken))
        {
            return;
        }

        _sessionStore.Save(new PersistedSession
        {
            AccessToken = _accessToken,
            RefreshToken = _refreshToken,
            UserId = _userId,
            NebulaId = NebulaId,
            DisplayName = DisplayName,
            AvatarUrl = AvatarUrl,
            IssuedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        });
    }

    // ---- JWT expiry decode ----------------------------------------------------------

    // True when the access token is missing, undecodable, or its `exp` is within the refresh
    // skew of now. Decode failures conservatively return true so we attempt a refresh.
    private static bool NeedsRefresh(string? accessToken)
    {
        var exp = DecodeJwtExpiry(accessToken);
        if (exp is null)
        {
            return true;
        }

        return DateTimeOffset.UtcNow + RefreshSkew >= exp.Value;
    }

    // Decodes the `exp` claim (Unix seconds) from a JWT's payload segment. Returns null if the
    // token is malformed — the caller treats null as "needs refresh".
    private static DateTimeOffset? DecodeJwtExpiry(string? jwt)
    {
        if (string.IsNullOrWhiteSpace(jwt))
        {
            return null;
        }

        try
        {
            var parts = jwt.Split('.');
            if (parts.Length < 2)
            {
                return null;
            }

            var payloadJson = Encoding.UTF8.GetString(Base64UrlDecode(parts[1]));
            using var document = JsonDocument.Parse(payloadJson);
            if (document.RootElement.TryGetProperty("exp", out var expElement)
                && expElement.TryGetInt64(out var expSeconds))
            {
                return DateTimeOffset.FromUnixTimeSeconds(expSeconds);
            }

            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static byte[] Base64UrlDecode(string segment)
    {
        var padded = segment.Replace('-', '+').Replace('_', '/');
        switch (padded.Length % 4)
        {
            case 2: padded += "=="; break;
            case 3: padded += "="; break;
        }

        return Convert.FromBase64String(padded);
    }

    // ---- Small helpers --------------------------------------------------------------

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

    private static AuthUserMetadata MergeMetadata(AuthUserMetadata? primary, AuthUserMetadata? secondary)
    {
        return new AuthUserMetadata
        {
            DisplayName = FirstNonEmpty(primary?.DisplayName, secondary?.DisplayName),
            FullName = FirstNonEmpty(primary?.FullName, secondary?.FullName),
            NebulaId = FirstNonEmpty(primary?.NebulaId, secondary?.NebulaId),
            AvatarUrl = FirstNonEmpty(primary?.AvatarUrl, secondary?.AvatarUrl)
        };
    }

    private static string? FirstNonEmpty(params string?[] candidates)
    {
        foreach (var candidate in candidates)
        {
            if (!string.IsNullOrWhiteSpace(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}

// Result of an email/password sign-in attempt: either success, or failure carrying a
// user-facing (already-localized) error string the AuthOverlay shows inline.
public readonly record struct EmailSignInResult(bool Success, string ErrorMessage)
{
    public static EmailSignInResult Succeeded() => new(true, string.Empty);

    public static EmailSignInResult Failed(string message) => new(false, message);
}

// Identity payload the VM forwards into its bindable props. Email / PhoneNumber feed the
// user-profile overlay's 邮箱 / 手机号 rows; both are empty (→ "未绑定" in the UI) when the
// account has not bound them — never fabricated.
public readonly record struct AccountIdentity(
    string DisplayName,
    string NebulaId,
    string AvatarUrl,
    bool IsSignedIn,
    string Email,
    string PhoneNumber);
