using System;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using System.Windows.Input;
using Skybridge.WinClient.Services;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  WeatherStateCoordinator — drives the weather hero card's async lifecycle.
//
//  It follows the house async-refresh idiom (see WorkspaceBusyCoordinator /
//  ReadOnlyWorkspaceRefreshCoordinator): await IWeatherClient.BuildReadOnlySnapshotAsync()
//  and then mutate the observable surface on the captured UI context — NO DispatcherQueue
//  (the VM layer has none; the command is invoked from a UI-thread ICommand.Execute so
//  the continuation resumes on the UI thread). Errors never escape into the UI: a failed
//  fetch is rendered as the error/retry state with the message text, exactly like the Mac
//  errorView. No fake numbers are ever shown — the card stays in Loading until real data
//  arrives, then flips to Loaded (or Error).
//
//  State setters are the four SetField-backed scalar props on the SessionViewModel
//  (WeatherPhase / WeatherLocation / WeatherTemperature / WeatherCondition / ...), passed
//  in as Action delegates so this stays a thin, testable coordinator with no VM coupling.
// =====================================================================================

internal sealed class WeatherStateCoordinator
{
    private readonly IWeatherClient _weatherClient;
    private readonly ObservableCollection<WeatherMetricView> _metrics;
    private readonly Action<string> _setPhase;
    private readonly Action<string> _setLocation;
    private readonly Action<string> _setTemperature;
    private readonly Action<string> _setCondition;
    private readonly Action<string> _setConditionKey;
    private readonly Action<string> _setSource;
    private readonly Action<string> _setUpdatedRelative;
    private readonly Action<string> _setErrorMessage;
    private readonly Action<string> _setStatusMessage;

    private bool _isRefreshing;

    // The coordinator owns its own bindable refresh command (the weather card's
    // refresh button binds to SessionViewModel.RefreshWeatherCommand, which is
    // assigned from this). Keeping the `new AsyncRelayCommand` here — not in
    // SessionViewModel — honors the WorkspaceCommandBindings command-ownership gate.
    public ICommand RefreshCommand { get; }

    public WeatherStateCoordinator(
        IWeatherClient weatherClient,
        ObservableCollection<WeatherMetricView> metrics,
        Action<string> setPhase,
        Action<string> setLocation,
        Action<string> setTemperature,
        Action<string> setCondition,
        Action<string> setConditionKey,
        Action<string> setSource,
        Action<string> setUpdatedRelative,
        Action<string> setErrorMessage,
        Action<string> setStatusMessage)
    {
        _weatherClient = weatherClient ?? throw new ArgumentNullException(nameof(weatherClient));
        _metrics = metrics ?? throw new ArgumentNullException(nameof(metrics));
        _setPhase = setPhase;
        _setLocation = setLocation;
        _setTemperature = setTemperature;
        _setCondition = setCondition;
        _setConditionKey = setConditionKey;
        _setSource = setSource;
        _setUpdatedRelative = setUpdatedRelative;
        _setErrorMessage = setErrorMessage;
        _setStatusMessage = setStatusMessage;
        RefreshCommand = new AsyncRelayCommand(RefreshAsync);
    }

    // Phase tokens the XAML keys its three state Visibilities off (via the
    // WeatherPhaseToVisibilityConverter): "Loading" | "Loaded" | "Error".
    public const string PhaseLoading = "Loading";
    public const string PhaseLoaded = "Loaded";
    public const string PhaseError = "Error";

    public async Task RefreshAsync()
    {
        if (_isRefreshing)
        {
            return;
        }

        _isRefreshing = true;
        try
        {
            // Keep existing data on screen if we already have some (refresh doesn't blank
            // the card); only show the full Loading state on the first load.
            if (_metrics.Count == 0)
            {
                _setPhase(PhaseLoading);
            }

            _setStatusMessage(_weatherClient.BuildPendingStatus());

            var snapshot = await _weatherClient.BuildReadOnlySnapshotAsync().ConfigureAwait(true);

            ApplySnapshot(snapshot);
            _setPhase(PhaseLoaded);
            _setStatusMessage(_weatherClient.BuildCompletedStatusMessage());
        }
        catch (WeatherUnavailableException ex)
        {
            ApplyError(ex.Message);
        }
        catch (Exception ex)
        {
            // Defensive: nothing should escape BuildReadOnlySnapshotAsync, but never throw
            // into the UI — degrade to the error/retry state with a readable message.
            ApplyError(string.IsNullOrWhiteSpace(ex.Message)
                ? "Weather is currently unavailable."
                : ex.Message);
        }
        finally
        {
            _isRefreshing = false;
        }
    }

    private void ApplySnapshot(WeatherSnapshot snapshot)
    {
        _setLocation(snapshot.Location);
        _setTemperature(snapshot.Temperature);
        _setCondition(snapshot.Condition);
        _setConditionKey(snapshot.ConditionKey);
        _setSource(snapshot.Source);
        _setUpdatedRelative(FormatRelative(snapshot.CapturedAt));
        _setErrorMessage(string.Empty);

        WorkspaceCollectionProjector.Replace(
            _metrics,
            snapshot.Metrics,
            WeatherMetricView.FromMetric);
    }

    private void ApplyError(string message)
    {
        _setErrorMessage(message);
        _setStatusMessage(message);
        // Only fall to the error state when we have no data to show; otherwise keep the
        // last-good card visible (matches the Mac: refresh failure doesn't blank content).
        if (_metrics.Count == 0)
        {
            _setPhase(PhaseError);
        }
        else
        {
            _setPhase(PhaseLoaded);
        }
    }

    // Relative time-ago, English mapping of the Mac strings:
    //   <60s -> "Just now"; <3600s -> "N minutes ago"; else -> "N hours ago".
    private static string FormatRelative(DateTimeOffset capturedAt)
    {
        var elapsed = DateTimeOffset.UtcNow - capturedAt;
        if (elapsed < TimeSpan.Zero)
        {
            elapsed = TimeSpan.Zero;
        }

        var seconds = elapsed.TotalSeconds;
        if (seconds < 60)
        {
            return "Just now";
        }

        if (seconds < 3600)
        {
            var minutes = (int)(seconds / 60);
            return minutes == 1 ? "1 minute ago" : $"{minutes} minutes ago";
        }

        var hours = (int)(seconds / 3600);
        return hours == 1 ? "1 hour ago" : $"{hours} hours ago";
    }
}
