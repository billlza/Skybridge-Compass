using System;
using System.Diagnostics.CodeAnalysis;
using System.Threading;
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
    private readonly ISessionStore _sessionStore;
    private readonly SemaphoreSlim _mutationGate = new(1, 1);

    private string? _accessToken;
    private string? _refreshToken;
    private string? _userId;

    // Refresh a little before the JWT actually expires so a call never races the boundary.
    private static readonly TimeSpan RefreshSkew = TimeSpan.FromMinutes(5);

    public AccountSessionCoordinator(ISupabaseAuthClient? authClient = null, ISessionStore? sessionStore = null)
    {
        // Self-provision the real implementations by default (the whole point of the escape
        // hatch). Tests may pass fakes, but production never touches the DI root.
        _authClient = authClient ?? new SupabaseAuthClient();
        _sessionStore = sessionStore ?? new SessionStore();
        SignOutCommand = new AsyncRelayCommand(async () => { await SignOutAsync().ConfigureAwait(true); });
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
    public async Task<AccountSessionResult> ApplyAuthAsync(AuthToken token)
    {
        await _mutationGate.WaitAsync().ConfigureAwait(true);
        try
        {
            return await ApplyAuthCoreAsync(token).ConfigureAwait(true);
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    // ---- Email sign-in (in-window AuthOverlay path) ---------------------------------

    // Called by the in-window AuthOverlay's 邮箱登录 button (via the VM). Validates non-empty
    // input, performs the REAL Supabase email/password sign-in through the owned auth client,
    // and on success applies + persists the identity. Returns a result the overlay binds to:
    // Success flips the overlay closed; a typed auth/storage failure keeps it open with the
    // inline error string. Unexpected programming/platform failures are not hidden here.
    public async Task<EmailSignInResult> SignInWithEmailAsync(string email, string password)
    {
        await _mutationGate.WaitAsync().ConfigureAwait(true);
        try
        {
            var trimmedEmail = email?.Trim() ?? string.Empty;
            // The password is taken verbatim from user input — never trimmed-away or defaulted.
            var rawPassword = password ?? string.Empty;

            if (string.IsNullOrWhiteSpace(trimmedEmail) || string.IsNullOrEmpty(rawPassword))
            {
                return EmailSignInResult.Failed(
                    EmailSignInFailureKind.Input,
                    "请输入邮箱和密码。");
            }

            var token = await _authClient
                .SignInWithPasswordAsync(trimmedEmail, rawPassword)
                .ConfigureAwait(true);

            if (!token.Succeeded || token.Value is null)
            {
                return EmailFailureFor(token.Failure);
            }

            var result = await ApplyAuthCoreAsync(token.Value)
                .ConfigureAwait(true);
            if (result.Success)
            {
                return EmailSignInResult.Succeeded();
            }

            return result.FailureKind switch
            {
                AccountSessionFailureKind.SessionPersistenceFailed => EmailSignInResult.Failed(
                    EmailSignInFailureKind.Storage,
                    "登录已验证，但本机安全存储失败。请检查磁盘或账户目录权限后重试。"),
                AccountSessionFailureKind.Network => EmailSignInResult.Failed(
                    EmailSignInFailureKind.Network,
                    "网络或认证服务暂时不可用，请稍后重试。"),
                _ => EmailSignInResult.Failed(
                    EmailSignInFailureKind.Verification,
                    "登录响应未通过账号身份连续性验证，请重新登录。")
            };
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    // ---- Hydrate on launch ----------------------------------------------------------

    // Load the persisted session; if the JWT is within the refresh skew of expiry, refresh it
    // first; then GetUser to re-confirm identity. Any failure leaves the block signed out.
    public async Task<AccountSessionResult> HydrateFromStoreAsync()
    {
        await _mutationGate.WaitAsync().ConfigureAwait(true);
        try
        {
            var loadResult = _sessionStore.Load();
            if (loadResult.IsQuietSignedOut)
            {
                return AccountSessionResult.SignedOutResult();
            }

            if (!loadResult.Succeeded || loadResult.Session is null)
            {
                return ClearStoredSessionAfterFailure(
                    AccountSessionFailureKind.SessionPersistenceFailed,
                    loadResult.Status.ToString());
            }

            var persisted = loadResult.Session;
            if (persisted.Authority is null
                || persisted.Authority != _authClient.SessionAuthority)
            {
                return ClearStoredSessionAfterFailure(
                    AccountSessionFailureKind.AuthorityMismatch,
                    "auth_persisted_authority_mismatch");
            }

            if (!SessionJwtValidator.TryValidate(
                    persisted.AccessToken,
                    _authClient.SessionAuthority,
                    persisted.Subject,
                    requireUnexpired: false,
                    out var persistedClaims,
                    out var persistedTokenError)
                || persistedClaims is null)
            {
                return ClearStoredSessionAfterFailure(
                    FailureKindForTokenError(persistedTokenError),
                    persistedTokenError);
            }

            var accessToken = persisted.AccessToken!;
            var refreshToken = persisted.RefreshToken!;
            var subject = persistedClaims.Subject;

            // Refresh the access token if it is expired or within the skew window.
            if (NeedsRefresh(persistedClaims.ExpiresAtUnix))
            {
                var refreshed = await _authClient.RefreshAsync(refreshToken).ConfigureAwait(true);
                if (!refreshed.Succeeded
                    || refreshed.Value is null
                    || string.IsNullOrWhiteSpace(refreshed.Value.AccessToken)
                    || string.IsNullOrWhiteSpace(refreshed.Value.RefreshToken))
                {
                    if (IsTransientAuthFailure(refreshed.Failure))
                        return DeferHydration(refreshed.Failure.Code);
                    return ClearStoredSessionAfterFailure(
                        AccountSessionFailureKind.RefreshRejected,
                        refreshed.Failure?.Code ?? "auth_refresh_missing_rotated_token");
                }

                if (!SessionJwtValidator.TryValidate(
                        refreshed.Value.AccessToken,
                        _authClient.SessionAuthority,
                        subject,
                        requireUnexpired: true,
                        out var refreshedClaims,
                        out var refreshTokenError)
                    || refreshedClaims is null
                    || !EmbeddedUserMatchesSubject(refreshed.Value, subject))
                {
                    return ClearStoredSessionAfterFailure(
                        string.IsNullOrEmpty(refreshTokenError)
                            ? AccountSessionFailureKind.SubjectMismatch
                            : FailureKindForTokenError(refreshTokenError),
                        string.IsNullOrEmpty(refreshTokenError)
                            ? "auth_refresh_embedded_subject_mismatch"
                            : refreshTokenError);
                }

                accessToken = refreshed.Value.AccessToken;
                refreshToken = refreshed.Value.RefreshToken;
                // Rotation has already happened on the server. Commit the replacement
                // before another network request can fail; do not publish identity yet.
                var rotated = _sessionStore.Save(persisted with
                {
                    AccessToken = accessToken, RefreshToken = refreshToken,
                    IssuedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
                });
                if (!rotated.Succeeded)
                {
                    ClearInMemoryAndNotify();
                    return AccountSessionResult.Failed(AccountSessionFailureKind.SessionPersistenceFailed, rotated.Status.ToString());
                }
            }

            // Re-confirm the live identity on every launch, even when the access token did not
            // require refresh. Parsed JWT claims alone are never authentication proof.
            var user = await _authClient
                .GetUserAsync(accessToken, subject)
                .ConfigureAwait(true);
            var returnedSubjectMismatch = user.Value is not null
                && !string.Equals(user.Value.Id, subject, StringComparison.Ordinal);
            if (!user.Succeeded
                || user.Value is null
                || returnedSubjectMismatch)
            {
                if (!returnedSubjectMismatch && IsTransientAuthFailure(user.Failure))
                    return DeferHydration(user.Failure.Code);
                return ClearStoredSessionAfterFailure(
                    FailureKindForUserFailure(user.Failure, returnedSubjectMismatch),
                    user.Failure?.Code ?? "auth_user_subject_mismatch");
            }

            var previous = CaptureState();
            ApplyVerifiedIdentity(accessToken, refreshToken, subject, user.Value);
            var saveResult = Persist();
            if (!saveResult.Succeeded)
            {
                RestoreState(previous);
                var clearResult = _sessionStore.Clear();
                _ = await _authClient.SignOutAsync(accessToken).ConfigureAwait(true);
                if (!clearResult.Succeeded)
                {
                    return AccountSessionResult.Failed(
                        AccountSessionFailureKind.SessionPersistenceFailed,
                        $"{saveResult.Status}:{clearResult.Status}");
                }

                ClearInMemoryAndNotify();
                return AccountSessionResult.FailedSignedOut(
                    AccountSessionFailureKind.SessionPersistenceFailed,
                    saveResult.Status.ToString());
            }

            RaiseIdentityChanged();
            return AccountSessionResult.Succeeded();
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    // ---- Sign-out -------------------------------------------------------------------

    public async Task<AccountSessionResult> SignOutAsync()
    {
        await _mutationGate.WaitAsync().ConfigureAwait(true);
        try
        {
            var token = _accessToken;

            // Local cleanup is authoritative for the UI and happens first. If it fails, keep
            // the exact in-memory identity and do not tell either the UI or server that logout
            // completed; a retry still has the token needed to finish safely.
            var clearResult = _sessionStore.Clear();
            if (!clearResult.Succeeded)
            {
                return AccountSessionResult.Failed(
                    AccountSessionFailureKind.SessionPersistenceFailed,
                    clearResult.Status.ToString());
            }

            ClearInMemoryAndNotify();

            if (string.IsNullOrWhiteSpace(token))
            {
                return AccountSessionResult.SignedOutResult();
            }

            var signOutResult = await _authClient.SignOutAsync(token).ConfigureAwait(true);
            if (!signOutResult.Succeeded || signOutResult.Value?.ServerRevoked != true)
            {
                return AccountSessionResult.FailedSignedOut(
                    AccountSessionFailureKind.ServerSignOutFailed,
                    signOutResult.Failure?.Code ?? "auth_sign_out_not_revoked");
            }

            return AccountSessionResult.SignedOutResult();
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    // ---- Identity application -------------------------------------------------------

    private async Task<AccountSessionResult> ApplyAuthCoreAsync(AuthToken token)
    {
        if (token is null
            || string.IsNullOrWhiteSpace(token.AccessToken)
            || string.IsNullOrWhiteSpace(token.RefreshToken))
        {
            return AccountSessionResult.Failed(
                AccountSessionFailureKind.InvalidToken,
                "auth_token_bundle_incomplete");
        }

        if (!SessionJwtValidator.TryValidate(
                token.AccessToken,
                _authClient.SessionAuthority,
                expectedSubject: null,
                requireUnexpired: true,
                out var claims,
                out var tokenError)
            || claims is null)
        {
            return AccountSessionResult.Failed(FailureKindForTokenError(tokenError), tokenError);
        }

        if (!EmbeddedUserMatchesSubject(token, claims.Subject))
        {
            return AccountSessionResult.Failed(
                AccountSessionFailureKind.SubjectMismatch,
                "auth_embedded_subject_mismatch");
        }

        var userResult = await _authClient
            .GetUserAsync(token.AccessToken, claims.Subject)
            .ConfigureAwait(true);
        var returnedSubjectMismatch = userResult.Value is not null
            && !string.Equals(userResult.Value.Id, claims.Subject, StringComparison.Ordinal);
        if (!userResult.Succeeded
            || userResult.Value is null
            || returnedSubjectMismatch)
        {
            return AccountSessionResult.Failed(
                FailureKindForUserFailure(userResult.Failure, returnedSubjectMismatch),
                userResult.Failure?.Code ?? "auth_user_subject_mismatch");
        }

        var previous = CaptureState();
        ApplyVerifiedIdentity(
            token.AccessToken,
            token.RefreshToken,
            claims.Subject,
            userResult.Value);

        var saveResult = Persist();
        if (!saveResult.Succeeded)
        {
            RestoreState(previous);
            _ = await _authClient.SignOutAsync(token.AccessToken).ConfigureAwait(true);

            return AccountSessionResult.Failed(
                AccountSessionFailureKind.SessionPersistenceFailed,
                saveResult.Status.ToString());
        }

        RaiseIdentityChanged();
        return AccountSessionResult.Succeeded();
    }

    private void ApplyVerifiedIdentity(
        string accessToken,
        string refreshToken,
        string subject,
        AuthUser user)
    {
        _accessToken = accessToken;
        _refreshToken = refreshToken;
        _userId = subject;

        var metadata = user.UserMetadata;
        var email = user.Email;
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
        IsSignedIn = true;
    }

    private void RaiseIdentityChanged()
    {
        IdentityChanged?.Invoke(this, new AccountIdentity(
            DisplayName, NebulaId, AvatarUrl, IsSignedIn, Email, PhoneNumber));
    }

    private SessionStoreWriteResult Persist()
    {
        if (string.IsNullOrWhiteSpace(_accessToken))
        {
            return SessionStoreWriteResult.InvalidSession();
        }

        return _sessionStore.Save(new PersistedSession
        {
            SchemaVersion = PersistedSession.CurrentSchemaVersion,
            Authority = _authClient.SessionAuthority,
            Subject = _userId,
            AccessToken = _accessToken,
            RefreshToken = _refreshToken,
            NebulaId = NebulaId,
            DisplayName = DisplayName,
            AvatarUrl = AvatarUrl,
            IssuedAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        });
    }

    private AccountSessionResult ClearStoredSessionAfterFailure(
        AccountSessionFailureKind failureKind,
        string errorCode)
    {
        var clearResult = _sessionStore.Clear();
        if (!clearResult.Succeeded)
        {
            return AccountSessionResult.Failed(
                AccountSessionFailureKind.SessionPersistenceFailed,
                clearResult.Status.ToString());
        }

        ClearInMemoryAndNotify();
        return AccountSessionResult.FailedSignedOut(failureKind, errorCode);
    }

    private static bool IsTransientAuthFailure([NotNullWhen(true)] AuthClientFailure? failure) =>
        failure?.Kind is AuthFailureKind.Network or AuthFailureKind.Timeout or AuthFailureKind.HttpFailure;

    private AccountSessionResult DeferHydration(string errorCode)
    {
        // A transport failure does not revoke a credential. Keep its DPAPI record,
        // but require a successful live check before exposing a signed-in identity.
        ClearInMemoryAndNotify();
        return AccountSessionResult.Failed(AccountSessionFailureKind.Network, errorCode);
    }

    private void ClearInMemoryAndNotify()
    {
        _accessToken = null;
        _refreshToken = null;
        _userId = null;

        IsSignedIn = false;
        DisplayName = string.Empty;
        NebulaId = string.Empty;
        AvatarUrl = string.Empty;
        Email = string.Empty;
        PhoneNumber = string.Empty;
        RaiseIdentityChanged();
    }

    // ---- JWT expiry decode ----------------------------------------------------------

    private static bool NeedsRefresh(long expiresAtUnix)
    {
        return DateTimeOffset.UtcNow + RefreshSkew >= DateTimeOffset.FromUnixTimeSeconds(expiresAtUnix);
    }

    private static bool EmbeddedUserMatchesSubject(AuthToken token, string subject)
    {
        return string.IsNullOrWhiteSpace(token.User?.Id)
            || string.Equals(token.User.Id, subject, StringComparison.Ordinal);
    }

    private static AccountSessionFailureKind FailureKindForTokenError(string errorCode)
    {
        if (errorCode.StartsWith("auth_authority_", StringComparison.Ordinal))
        {
            return AccountSessionFailureKind.AuthorityMismatch;
        }

        return errorCode is "auth_subject_missing" or "auth_subject_mismatch"
            ? AccountSessionFailureKind.SubjectMismatch
            : AccountSessionFailureKind.InvalidToken;
    }

    private static EmailSignInResult EmailFailureFor(AuthClientFailure? failure)
    {
        return failure?.Kind switch
        {
            AuthFailureKind.InvalidCredentials or AuthFailureKind.Unauthorized or AuthFailureKind.Forbidden =>
                EmailSignInResult.Failed(
                    EmailSignInFailureKind.Credentials,
                    "邮箱或密码不正确，请检查后重试。"),
            AuthFailureKind.Network or AuthFailureKind.Timeout or AuthFailureKind.HttpFailure =>
                EmailSignInResult.Failed(
                    EmailSignInFailureKind.Network,
                    "网络或认证服务暂时不可用，请稍后重试。"),
            _ => EmailSignInResult.Failed(
                EmailSignInFailureKind.Verification,
                "认证服务返回了无效的会话数据，请重新登录。")
        };
    }

    private static AccountSessionFailureKind FailureKindForUserFailure(
        AuthClientFailure? failure,
        bool returnedSubjectMismatch)
    {
        if (returnedSubjectMismatch || failure?.Kind == AuthFailureKind.SubjectMismatch)
        {
            return AccountSessionFailureKind.SubjectMismatch;
        }

        return failure?.Kind is AuthFailureKind.Network or AuthFailureKind.Timeout or AuthFailureKind.HttpFailure
            ? AccountSessionFailureKind.Network
            : AccountSessionFailureKind.UserVerificationFailed;
    }

    private AccountState CaptureState() =>
        new(
            _accessToken,
            _refreshToken,
            _userId,
            IsSignedIn,
            DisplayName,
            NebulaId,
            AvatarUrl,
            Email,
            PhoneNumber);

    private void RestoreState(AccountState state)
    {
        _accessToken = state.AccessToken;
        _refreshToken = state.RefreshToken;
        _userId = state.Subject;
        IsSignedIn = state.IsSignedIn;
        DisplayName = state.DisplayName;
        NebulaId = state.NebulaId;
        AvatarUrl = state.AvatarUrl;
        Email = state.Email;
        PhoneNumber = state.PhoneNumber;
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

    private sealed record AccountState(
        string? AccessToken,
        string? RefreshToken,
        string? Subject,
        bool IsSignedIn,
        string DisplayName,
        string NebulaId,
        string AvatarUrl,
        string Email,
        string PhoneNumber);
}

// Result of an email/password sign-in attempt: either success, or failure carrying a
// user-facing (already-localized) error string the AuthOverlay shows inline.
public enum EmailSignInFailureKind
{
    Input,
    Credentials,
    Network,
    Storage,
    Verification
}

public readonly record struct EmailSignInResult(
    bool Success,
    EmailSignInFailureKind? FailureKind,
    string ErrorMessage)
{
    public static EmailSignInResult Succeeded() => new(true, null, string.Empty);

    public static EmailSignInResult Failed(EmailSignInFailureKind kind, string message) =>
        new(false, kind, message);
}

public enum AccountSessionFailureKind
{
    InvalidToken,
    RefreshRejected,
    Network,
    UserVerificationFailed,
    SessionPersistenceFailed,
    ServerSignOutFailed,
    AuthorityMismatch,
    SubjectMismatch
}

public readonly record struct AccountSessionResult(
    bool Success,
    bool SignedOut,
    AccountSessionFailureKind? FailureKind,
    string ErrorCode)
{
    public static AccountSessionResult Succeeded() => new(true, false, null, string.Empty);

    public static AccountSessionResult SignedOutResult() => new(true, true, null, string.Empty);

    public static AccountSessionResult Failed(AccountSessionFailureKind kind, string errorCode) =>
        new(false, false, kind, errorCode);

    public static AccountSessionResult FailedSignedOut(AccountSessionFailureKind kind, string errorCode) =>
        new(false, true, kind, errorCode);
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
