using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

internal sealed record AccountDeviceRow(string Identity, string Name, string Detail, string State, string LastSeen, string Glyph);

// One application-owned loop, independent of how many account-device views are
// visible. All bound state changes resume on the UI context; network/identity I/O
// never blocks it. Account changes cancel requests and invalidate their results.
internal sealed class AccountDevicesCoordinator : INotifyPropertyChanged, IAsyncDisposable
{
    private readonly IAccountDeviceRosterClient _client;
    private readonly Func<CancellationToken, Task<AccountDeviceAuthentication?>> _authenticate;
    private readonly Func<CancellationToken, Task<CurrentPathProtocolIdentityBinding>> _identity;
    private readonly Func<CancellationToken, Task<AccountDeviceMetadata>> _metadata;
    private readonly Func<string, string> _text;
    private readonly TimeProvider _time;
    private readonly SemaphoreSlim _wake = new(0, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _request;
    private Task? _loop;
    private string? _scope;
    private long _generation;
    private long? _snapshotTime;
    private long _lastAttempt;
    private TimeSpan _retryDelay;
    private int _failures;
    private AccountDeviceRosterSnapshot? _snapshot;
    private string _status;
    private string _phase = "signedOut";
    internal string Phase => _phase;
    private bool _busy;
    private bool _disposed;
    internal ObservableCollection<AccountDeviceRow> Devices { get; } = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    public string Status => _status;
    public bool IsBusy => _busy;
    public bool CanRefresh => !_busy && _scope is not null;
    public string Summary => _snapshot is null ? _status : string.Format(_text("AccountDevicesSummary"), Devices.Count, _snapshot.Devices.Count(d => d.Online));
    internal AccountDevicesCoordinator(IAccountDeviceRosterClient client,
        Func<CancellationToken, Task<AccountDeviceAuthentication?>> authenticate,
        Func<CancellationToken, Task<CurrentPathProtocolIdentityBinding>> identity,
        Func<CancellationToken, Task<AccountDeviceMetadata>> metadata, Func<string, string> text, TimeProvider? time = null)
    {
        _client = client; _authenticate = authenticate; _identity = identity; _metadata = metadata; _text = text; _time = time ?? TimeProvider.System;
        _status = text("AccountDevicesSignedOut");
    }
    internal void Start() => _loop ??= RunAsync();
    internal void SetAccount(string? scope)
    {
        if (_scope == scope) return;
        _scope = scope; _generation++; _request?.Cancel(); _snapshot = null; _snapshotTime = null; Devices.Clear(); _failures = 0; _retryDelay = TimeSpan.Zero;
        SetPhase(scope is null ? "signedOut" : "loading");
        SetStatus(_text(scope is null ? "AccountDevicesSignedOut" : "AccountDevicesLoading"));
        Notify(nameof(CanRefresh)); Wake();
    }
    internal void Refresh()
    {
        if (!CanRefresh) return;
        // Coalesce clicks, and never let UI retries create an unbounded request loop.
        if (_time.GetElapsedTime(_lastAttempt) < TimeSpan.FromSeconds(1)) return;
        _retryDelay = TimeSpan.Zero; Wake();
    }
    private void Wake() { if (_wake.CurrentCount == 0) _wake.Release(); }
    private async Task RunAsync()
    {
        try
        {
            while (!_lifetime.IsCancellationRequested)
            {
                ExpireSnapshot();
                if (_scope is not null && (_retryDelay == TimeSpan.Zero || _time.GetElapsedTime(_lastAttempt) >= _retryDelay))
                    await RefreshOnceAsync(_lifetime.Token).ConfigureAwait(true);
                var delay = _scope is null ? TimeSpan.FromSeconds(90) : _retryDelay - _time.GetElapsedTime(_lastAttempt);
                if (_snapshotTime is long stamp) delay = Min(delay, TimeSpan.FromSeconds(90) - _time.GetElapsedTime(stamp));
                if (delay < TimeSpan.FromMilliseconds(100)) delay = TimeSpan.FromMilliseconds(100);
                await _wake.WaitAsync(delay, _lifetime.Token).ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
    }
    internal async Task RefreshOnceAsync(CancellationToken cancellationToken)
    {
        if (_busy || _scope is null) return;
        long generation = _generation; string scope = _scope;
        _busy = true; Notify(nameof(IsBusy)); Notify(nameof(CanRefresh)); _lastAttempt = _time.GetTimestamp();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        request.CancelAfter(TimeSpan.FromSeconds(20)); _request = request;
        try
        {
            var auth = await _authenticate(request.Token).ConfigureAwait(true);
            if (auth is null || auth.Scope != scope) throw new AccountDeviceAuthenticationException(AccountSessionFailureKind.UserVerificationFailed);
            var binding = await _identity(request.Token).ConfigureAwait(true);
            var metadata = await _metadata(request.Token).ConfigureAwait(true);
            var snapshot = await _client.RefreshAsync(auth, binding, metadata, request.Token).ConfigureAwait(true);
            request.Token.ThrowIfCancellationRequested();
            if (_generation != generation || _scope != scope) return;
            _snapshot = snapshot; _snapshotTime = _time.GetTimestamp(); _failures = 0; _retryDelay = TimeSpan.FromSeconds(30);
            bool callerActive = snapshot.Devices.Any(d => d.IsCaller && d.Status == "active");
            SetPhase(callerActive ? "ready" : "needsApproval");
            ProjectSnapshot(); SetStatus(_text(!callerActive ? "AccountDevicesNotActive" : snapshot.Truncated ? "AccountDevicesTruncated" : "AccountDevicesCurrent"));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested || generation != _generation) { }
        catch (Exception error)
        {
            if (generation != _generation) return;
            _failures = Math.Min(_failures + 1, 5);
            string key = FailureKey(error);
            // No network/auth failure is displayed as a successful empty list or as
            // currently online. Keep useful metadata clearly marked offline.
            if (_snapshot is not null) _snapshot = _snapshot with { Devices = _snapshot.Devices.Select(d => d with { Online = false }).ToArray() };
            if (key is "AccountDevicesAuthError" or "AccountDevicesNotActive") _snapshot = null;
            SetPhase("error");
            _snapshotTime = null; ProjectSnapshot(); SetStatus(_text(key));
            _retryDelay = TimeSpan.FromSeconds(key is "AccountDevicesNotActive" or "AccountDevicesAuthError" ? 300 : Math.Min(300, (key == "AccountDevicesRateLimited" ? 60 : 30) * (1 << (_failures - 1))));
            string cause = error is CurrentPathSignalServerException rejected
                ? ((int)rejected.StatusCode) + ":" + (AccountDeviceWire.ErrorCode(rejected) ?? "rejected") : error.GetType().Name;
            Debug.WriteLine("Account devices refresh failed: " + cause);
        }
        finally
        {
            _request = null; _busy = false; Notify(nameof(IsBusy)); Notify(nameof(CanRefresh));
        }
    }
    internal void ExpireSnapshot()
    {
        if (_snapshotTime is not long time || _snapshot is null || _time.GetElapsedTime(time) < TimeSpan.FromSeconds(90)) return;
        _snapshot = _snapshot with { Devices = _snapshot.Devices.Select(d => d with { Online = false }).ToArray() }; _snapshotTime = null;
        SetPhase("expired"); ProjectSnapshot(); SetStatus(_text("AccountDevicesExpired"));
    }
    private void ProjectSnapshot()
    {
        Devices.Clear();
        if (_snapshot is null) { Notify(nameof(Summary)); return; }
        foreach (var device in _snapshot.Devices.OrderByDescending(d => d.IsCaller).ThenByDescending(d => d.Online).ThenBy(d => d.DeviceName, StringComparer.CurrentCulture))
        {
            string model = AccountDevicePresentation.Model(device.Model, device.Platform, _text);
            string detail = string.Join(" · ", new[] { model, device.OsVersion, device.AppVersion is null ? null : "v" + device.AppVersion }.Where(v => !string.IsNullOrWhiteSpace(v)));
            string state = _text(device.Status == "pending" ? "AccountDevicePending" : device.Status == "frozen" ? "AccountDeviceFrozen" : device.Online ? "AccountDeviceOnline" : "AccountDeviceOffline");
            if (device.IsCaller) state = _text("AccountDeviceThisDevice") + " · " + state;
            string seen = device.LastSeenAt is long stamp ? string.Format(_text("AccountDeviceLastSeen"), DateTimeOffset.FromUnixTimeMilliseconds(stamp).ToLocalTime().ToString("g")) : _text("AccountDeviceLastSeenUnknown");
            Devices.Add(new(device.Identity, device.DeviceName, detail, state, seen, AccountDevicePresentation.Glyph(device.Platform)));
        }
        Notify(nameof(Summary));
    }
    private static string FailureKey(Exception error) => error switch
    {
        AccountDeviceAuthenticationException e when e.Kind == AccountSessionFailureKind.Network => "AccountDevicesNetworkError",
        AccountDeviceAuthenticationException => "AccountDevicesAuthError",
        CurrentPathSignalServerException e when e.StatusCode == HttpStatusCode.Unauthorized => "AccountDevicesAuthError",
        CurrentPathSignalServerException e when AccountDeviceWire.ErrorCode(e) is "device_not_registered" or "device_not_active" or "device_pending" or "device_frozen" or "device_revoked" => "AccountDevicesNotActive",
        CurrentPathSignalServerException e when e.StatusCode == HttpStatusCode.TooManyRequests => "AccountDevicesRateLimited",
        CurrentPathSignalServerException => "AccountDevicesServiceError",
        HttpRequestException or OperationCanceledException => "AccountDevicesNetworkError",
        InvalidDataException or System.Text.Json.JsonException => "AccountDevicesInvalidResponse",
        _ => "AccountDevicesLocalError"
    };
    private static TimeSpan Min(TimeSpan a, TimeSpan b) => a < b ? a : b;
    private void SetPhase(string phase) { _phase = phase; Notify(nameof(Phase)); }
    private void Notify(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    private void SetStatus(string status) { _status = status; Notify(nameof(Status)); Notify(nameof(Summary)); }
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return; _disposed = true;
        _lifetime.Cancel(); _request?.Cancel();
        if (_loop is not null) await _loop.ConfigureAwait(true);
        _wake.Dispose(); _lifetime.Dispose();
    }
}

internal sealed class AccountDeviceAuthenticationException(AccountSessionFailureKind? kind)
    : Exception("Account request authentication is unavailable.")
{
    internal AccountSessionFailureKind? Kind { get; } = kind;
}
