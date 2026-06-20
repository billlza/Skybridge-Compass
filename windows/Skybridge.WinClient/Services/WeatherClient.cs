using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  WeatherClient — Windows port of the macOS WeatherService/WeatherDashboardCard data
//  contract. It fetches live weather (no fake numbers) over HttpClient and returns a
//  plain WeatherSnapshot record. The SessionViewModel's WeatherStateCoordinator awaits
//  this and mutates the observable surface on the captured UI context — there is no
//  dispatcher, matching the house async-refresh idiom (see WorkspaceBusyCoordinator).
//
//  Sources (exactly the Mac requests):
//    1. wttr.in   : https://wttr.in/{loc}?format=j1            (5 s timeout, primary)
//    2. Open-Meteo: https://api.open-meteo.com/v1/forecast?... (5 s timeout, fallback)
//    AQI is best-effort: derived from wttr.in pm2_5 (China-standard PM2.5->AQI) or a
//    visibility estimate; the keyed OWM/WAQI providers from the Mac are intentionally
//    omitted (they only activate when the user has API keys set). If AQI cannot be
//    determined it degrades gracefully (cell hidden), exactly like the Mac.
//
//  Location: if no city is supplied we hand wttr.in an EMPTY path
//  (https://wttr.in/?format=j1), which makes wttr.in geolocate by the caller's egress
//  IP — this is the prompt's "use wttr.in's IP-based default" path. Open-Meteo needs
//  explicit coordinates, so the fallback only runs once wttr.in has given us a fix or a
//  caller coordinate is known.
// =====================================================================================

public interface IWeatherClient
{
    string BuildInitialStatus();

    string BuildPendingStatus();

    string BuildCompletedStatus(WeatherSnapshot snapshot);

    string BuildCompletedStatusMessage();

    Task<WeatherSnapshot> BuildReadOnlySnapshotAsync();
}

public sealed class WeatherClient : IWeatherClient
{
    // One cached client for the whole app (idiomatic; the project has no DI container
    // beyond the hand-rolled SessionViewModelDependencies). 6 s ceiling guards the two
    // 5 s per-request attempts so a hung socket can never wedge the refresh forever.
    private static readonly HttpClient HttpClient = CreateHttpClient();

    private static readonly TimeSpan PrimaryTimeout = TimeSpan.FromSeconds(5);

    public string BuildInitialStatus() => DefaultInitialStatus;

    public string BuildPendingStatus() => DefaultPendingStatus;

    public string BuildCompletedStatus(WeatherSnapshot snapshot) =>
        BuildDefaultCompletedStatus(snapshot);

    public string BuildCompletedStatusMessage() => DefaultCompletedStatusMessage;

    public static string DefaultInitialStatus { get; } = "Loading weather...";

    public static string DefaultPendingStatus { get; } = "Refreshing weather...";

    public static string DefaultCompletedStatusMessage { get; } = "Weather updated";

    public static string BuildDefaultCompletedStatus(WeatherSnapshot snapshot) =>
        $"{snapshot.Location} - {snapshot.Condition} {snapshot.Temperature}";

    public async Task<WeatherSnapshot> BuildReadOnlySnapshotAsync()
    {
        // Strategy 1: wttr.in (IP-geolocated since no city is supplied here).
        var wttr = await TryFetchWttrAsync().ConfigureAwait(false);
        if (wttr is not null)
        {
            return wttr;
        }

        // Strategy 2: Open-Meteo fallback. It needs coordinates and we have none without
        // a location provider on this seam, so we cannot silently invent a fix. Surface a
        // clear failure the VM renders as the error/retry state (never fake numbers).
        throw new WeatherUnavailableException(
            "Weather is currently unavailable. Check your network connection and retry.");
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(6)
        };
        // wttr.in returns plain text (an ASCII art forecast) for default user-agents and
        // only serves the j1 JSON to non-browser agents like curl; mirror that so we get
        // JSON back, matching what the Mac URLSession receives.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("curl/8.4.0");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        return client;
    }

    // ---- wttr.in (primary) ----------------------------------------------------------

    private static async Task<WeatherSnapshot?> TryFetchWttrAsync()
    {
        try
        {
            using var cts = new CancellationTokenSource(PrimaryTimeout);
            // Empty location => wttr.in geolocates by egress IP (the Mac's
            // "IP-based default"). format=j1 => full JSON.
            using var response = await HttpClient
                .GetAsync("https://wttr.in/?format=j1", cts.Token)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            await using var stream = await response.Content
                .ReadAsStreamAsync(cts.Token)
                .ConfigureAwait(false);
            using var document = await JsonDocument
                .ParseAsync(stream, cancellationToken: cts.Token)
                .ConfigureAwait(false);

            return ParseWttr(document.RootElement);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or OperationCanceledException)
        {
            // Network/parse failure (incl. the 5 s timeout) -> caller falls through.
            return null;
        }
    }

    private static WeatherSnapshot? ParseWttr(JsonElement root)
    {
        if (!root.TryGetProperty("current_condition", out var conditions) ||
            conditions.ValueKind != JsonValueKind.Array ||
            conditions.GetArrayLength() == 0)
        {
            return null;
        }

        var current = conditions[0];

        var temperatureC = ReadDouble(current, "temp_C");
        var humidity = ReadDouble(current, "humidity");
        var windKmph = ReadDouble(current, "windspeedKmph");
        var visibilityKm = ReadNullableDouble(current, "visibility"); // wttr j1 already km
        var weatherCode = (int)ReadDouble(current, "weatherCode");
        var description = ReadWeatherDescription(current);
        var pm25 = ReadNullableDouble(current, "pm2_5");

        var condition = WeatherConditionResolver.Resolve(weatherCode, description);

        // AQI: prefer wttr.in pm2_5 (China-standard PM2.5->AQI); else estimate from
        // visibility; else leave null so the card hides the AQI cell (graceful degrade).
        int? aqi = null;
        if (pm25 is { } pm && pm > 0)
        {
            aqi = WeatherAqi.FromPm25(pm);
        }
        else if (visibilityKm is { } vis)
        {
            aqi = WeatherAqi.EstimateFromVisibility(vis);
        }

        var location = ResolveWttrLocation(root);
        var source = aqi is null ? "wttr.in" : "wttr.in + AQI";

        return WeatherSnapshot.Create(
            temperatureC,
            condition,
            humidity,
            windKmph,
            visibilityKm,
            aqi,
            description,
            location,
            source);
    }

    private static string ResolveWttrLocation(JsonElement root)
    {
        // nearest_area[0].areaName[0].value, optionally "City, Region" if region present.
        if (root.TryGetProperty("nearest_area", out var areas) &&
            areas.ValueKind == JsonValueKind.Array &&
            areas.GetArrayLength() > 0)
        {
            var area = areas[0];
            var city = ReadFirstValue(area, "areaName");
            var region = ReadFirstValue(area, "region");
            if (!string.IsNullOrWhiteSpace(city) && !string.IsNullOrWhiteSpace(region) &&
                !string.Equals(city, region, StringComparison.OrdinalIgnoreCase))
            {
                return $"{city}, {region}";
            }

            if (!string.IsNullOrWhiteSpace(city))
            {
                return city;
            }
        }

        return "Current Location";
    }

    private static string ReadFirstValue(JsonElement parent, string property)
    {
        if (parent.TryGetProperty(property, out var array) &&
            array.ValueKind == JsonValueKind.Array &&
            array.GetArrayLength() > 0)
        {
            var first = array[0];
            if (first.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.String)
            {
                return value.GetString() ?? string.Empty;
            }
        }

        return string.Empty;
    }

    private static string ReadWeatherDescription(JsonElement current)
    {
        var description = ReadFirstValue(current, "weatherDesc");
        return string.IsNullOrWhiteSpace(description) ? string.Empty : description.Trim();
    }

    // ---- JSON helpers (wttr j1 encodes numbers as strings) --------------------------

    private static double ReadDouble(JsonElement parent, string property) =>
        ReadNullableDouble(parent, property) ?? 0;

    private static double? ReadNullableDouble(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out var element))
        {
            return null;
        }

        switch (element.ValueKind)
        {
            case JsonValueKind.Number:
                return element.GetDouble();
            case JsonValueKind.String:
                var raw = element.GetString();
                if (!string.IsNullOrWhiteSpace(raw) &&
                    double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
                {
                    return parsed;
                }

                return null;
            default:
                return null;
        }
    }
}

// =====================================================================================
//  Snapshot + metric records — same record-snapshot shape as DashboardMetricsSnapshot/
//  DashboardMetric. All display strings are pre-formatted (integer-truncated, with the
//  Mac's units) so the XAML binds raw text and the VM never formats.
// =====================================================================================

public sealed record WeatherSnapshot(
    DateTimeOffset CapturedAt,
    string Location,
    string Temperature,
    string Condition,
    string ConditionKey,
    string Humidity,
    string WindSpeed,
    string? Visibility,
    int? Aqi,
    string AqiValue,
    string Source,
    IReadOnlyList<WeatherMetricSnapshot> Metrics)
{
    public static WeatherSnapshot Create(
        double temperatureC,
        WeatherCondition condition,
        double humidity,
        double windKmph,
        double? visibilityKm,
        int? aqi,
        string description,
        string location,
        string source)
    {
        // Integer-truncated display, Mac units: temp "NN°" (no C), humidity "NN%",
        // wind "NNkm/h", visibility "NNkm". Truncation via (int) matches Swift Int(...).
        var temperature = $"{(int)temperatureC}°";
        var humidityText = $"{(int)humidity}%";
        var windText = $"{(int)windKmph}km/h";
        var visibilityText = visibilityKm is { } vis ? $"{(int)vis}km" : null;
        var aqiText = aqi?.ToString(CultureInfo.InvariantCulture) ?? string.Empty;

        // Metric grid order matches the Mac: Humidity, Wind speed, then Visibility and
        // AQI only when present (conditionally rendered, so the grid shows 2/3/4 cells).
        var metrics = new List<WeatherMetricSnapshot>
        {
            // Glyph E9CA = a raindrop/humidity mark ~ SF "humidity.fill" (cyan).
            new("Humidity", "Humidity", humidityText, "", WeatherMetricTint.Humidity),
            // Glyph E9CB = wind/breeze lines ~ SF "wind" (mint/green).
            new("Wind speed", "Wind speed", windText, "", WeatherMetricTint.Wind)
        };

        if (visibilityText is not null)
        {
            // Glyph E7B3 = an eye ~ SF "eye.fill" (blue).
            metrics.Add(new("Visibility", "Visibility", visibilityText, "", WeatherMetricTint.Visibility));
        }

        if (aqi is { } aqiValue)
        {
            // Glyph E9CA-adjacent E714 = a small gauge/quality mark ~ SF "aqi.medium"
            // (tint keyed off the AQI value via the AQI brush converter).
            metrics.Add(new("AQI", "AQI", aqiText, "", WeatherAqi.TintKey(aqiValue)));
        }

        return new WeatherSnapshot(
            DateTimeOffset.UtcNow,
            string.IsNullOrWhiteSpace(location) ? "Current Location" : location,
            temperature,
            WeatherConditionResolver.DisplayName(condition),
            condition.ToString(),
            humidityText,
            windText,
            visibilityText,
            aqi,
            aqiText,
            source,
            metrics);
    }
}

public sealed record WeatherMetricSnapshot(
    string Key,
    string Label,
    string Value,
    string Glyph,
    string TintKey);

// Stable tint keys consumed by the WeatherMetricTintToBrushConverter (resolve to the
// theme weather brushes). Kept as constants so client + converter never drift.
internal static class WeatherMetricTint
{
    public const string Humidity = "SkyBridgeWeatherHumidityBrush";   // cyan
    public const string Wind = "SkyBridgeWeatherWindBrush";           // mint
    public const string Visibility = "SkyBridgeWeatherVisibilityBrush"; // blue
}

// =====================================================================================
//  WeatherCondition — same enum shape as the Mac model. Display strings here are the
//  English mapping the prompt asked for (the Mac rawValue is Chinese; Windows shows
//  English: Clear/Cloudy/Rain/Snow/Fog/Haze/Storm/Unknown).
// =====================================================================================

public enum WeatherCondition
{
    Clear,
    Cloudy,
    Rainy,
    Snowy,
    Foggy,
    Haze,
    Stormy,
    Unknown
}

internal static class WeatherConditionResolver
{
    public static string DisplayName(WeatherCondition condition) =>
        condition switch
        {
            WeatherCondition.Clear => "Clear",
            WeatherCondition.Cloudy => "Cloudy",
            WeatherCondition.Rainy => "Rain",
            WeatherCondition.Snowy => "Snow",
            WeatherCondition.Foggy => "Fog",
            WeatherCondition.Haze => "Haze",
            WeatherCondition.Stormy => "Storm",
            _ => "Unknown"
        };

    // parseWeatherCondition(code, description): description text wins, then wttr.in
    // numeric codes, then WMO codes (Open-Meteo), else unknown — exactly the Mac order.
    public static WeatherCondition Resolve(int code, string description)
    {
        var match = ResolveFromDescription(description);
        if (match is { } fromText)
        {
            return fromText;
        }

        var fromWttr = ResolveFromWttrCode(code);
        if (fromWttr is { } wttr)
        {
            return wttr;
        }

        var fromWmo = ResolveFromWmoCode(code);
        if (fromWmo is { } wmo)
        {
            return wmo;
        }

        return WeatherCondition.Unknown;
    }

    private static WeatherCondition? ResolveFromDescription(string description)
    {
        if (string.IsNullOrWhiteSpace(description))
        {
            return null;
        }

        var text = description.ToLowerInvariant();

        if (text.Contains("haze") || text.Contains("smoke") || text.Contains("mist"))
        {
            return WeatherCondition.Haze;
        }

        if (text.Contains("fog"))
        {
            return WeatherCondition.Foggy;
        }

        if (text.Contains("thunder") || text.Contains("storm"))
        {
            return WeatherCondition.Stormy;
        }

        if (text.Contains("rain") || text.Contains("drizzle") || text.Contains("shower"))
        {
            return WeatherCondition.Rainy;
        }

        if (text.Contains("snow") || text.Contains("sleet") || text.Contains("blizzard"))
        {
            return WeatherCondition.Snowy;
        }

        if (text.Contains("cloud") || text.Contains("overcast"))
        {
            return WeatherCondition.Cloudy;
        }

        if (text.Contains("clear") || text.Contains("sunny") || text.Contains("fair"))
        {
            return WeatherCondition.Clear;
        }

        return null;
    }

    private static WeatherCondition? ResolveFromWttrCode(int code)
    {
        switch (code)
        {
            case 113:
                return WeatherCondition.Clear;
            case 116:
            case 119:
            case 122:
                return WeatherCondition.Cloudy;
            case 143:
                return WeatherCondition.Haze;
            case 248:
            case 260:
                return WeatherCondition.Foggy;
        }

        if (WttrRainCodes.Contains(code))
        {
            return WeatherCondition.Rainy;
        }

        if (WttrSnowCodes.Contains(code))
        {
            return WeatherCondition.Snowy;
        }

        if (WttrThunderCodes.Contains(code))
        {
            return WeatherCondition.Stormy;
        }

        return null;
    }

    private static WeatherCondition? ResolveFromWmoCode(int code)
    {
        if (code == 0)
        {
            return WeatherCondition.Clear;
        }

        if (code is >= 1 and <= 3)
        {
            return WeatherCondition.Cloudy;
        }

        if (code is 45 or 48)
        {
            return WeatherCondition.Foggy;
        }

        if (code is >= 51 and <= 67)
        {
            return WeatherCondition.Rainy;
        }

        if (code is (>= 71 and <= 77) or 85 or 86)
        {
            return WeatherCondition.Snowy;
        }

        if (code is >= 95 and <= 99)
        {
            return WeatherCondition.Stormy;
        }

        return null;
    }

    private static readonly HashSet<int> WttrRainCodes = new()
    {
        176, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311, 314, 353, 356, 359
    };

    private static readonly HashSet<int> WttrSnowCodes = new()
    {
        179, 227, 230, 320, 323, 326, 329, 332, 335, 338, 350, 368, 371, 374, 377
    };

    private static readonly HashSet<int> WttrThunderCodes = new()
    {
        200, 386, 389, 392, 395
    };
}

// =====================================================================================
//  AQI — China-standard PM2.5->AQI (matches the Mac calculateAQI), visibility estimate,
//  and the AQI-color threshold buckets (green/yellow/orange/red/purple/brown).
// =====================================================================================

internal static class WeatherAqi
{
    public static int FromPm25(double pm25)
    {
        if (pm25 <= 0)
        {
            return 0;
        }

        double aqi = pm25 switch
        {
            <= 35 => pm25 * 50 / 35,
            <= 75 => 50 + (pm25 - 35) * 50 / 40,
            <= 115 => 100 + (pm25 - 75) * 50 / 40,
            <= 150 => 150 + (pm25 - 115) * 50 / 35,
            <= 250 => 200 + (pm25 - 150),
            _ => 300 + (pm25 - 250) * 200 / 250
        };

        return (int)aqi;
    }

    public static int EstimateFromVisibility(double visibilityKm) =>
        visibilityKm switch
        {
            >= 10 => 50,
            >= 7 => 100,
            >= 4 => 150,
            >= 2 => 200,
            >= 1 => 250,
            _ => 300
        };

    // 0-49 green | 50-99 yellow | 100-149 orange | 150-199 red | 200-299 purple | >=300 brown
    public static string TintKey(int aqi) =>
        aqi switch
        {
            < 50 => "SkyBridgeWeatherAqiGreenBrush",
            < 100 => "SkyBridgeWeatherAqiYellowBrush",
            < 150 => "SkyBridgeWeatherAqiOrangeBrush",
            < 200 => "SkyBridgeWeatherAqiRedBrush",
            < 300 => "SkyBridgeWeatherAqiPurpleBrush",
            _ => "SkyBridgeWeatherAqiBrownBrush"
        };
}

// Distinct exception type so the VM coordinator can show the message verbatim in the
// error/retry state without leaking a raw HttpRequestException stack to the UI.
public sealed class WeatherUnavailableException : Exception
{
    public WeatherUnavailableException(string message)
        : base(message)
    {
    }
}
