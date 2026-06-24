using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;

namespace Skybridge.WinClient.ViewModels;

// =====================================================================================
//  Weather card converters — element-match the Mac WeatherDashboardCard glyphs/colors.
//  All Segoe Fluent Icons codepoints are best-fit for the Mac SF Symbol's *meaning* and
//  are commented with the intended picture so the human can visually verify. Brush keys
//  resolve through MetricKeyToBrushConverter.ResolveBrush (same fallback chain as the
//  dashboard StatCard converters). Codepoints are written as \uXXXX escapes so this file
//  stays plain ASCII and the exact glyph is unambiguous for review.
// =====================================================================================

/// <summary>
/// Condition enum name (WeatherSnapshot.ConditionKey: Clear/Cloudy/Rainy/Snowy/Foggy/
/// Haze/Stormy/Unknown) -> the big weather glyph, rendered as a COLOR EMOJI. Segoe Fluent
/// Icons has no weather glyphs, so the card renders these via a TextBlock with
/// FontFamily="Segoe UI Emoji" (reliable colored emoji that match the Mac's colorful SF
/// weather symbols). Mirrors the Mac iconName mapping:
///   Clear  -> sun emoji           ~ SF "sun.max.fill"
///   Cloudy -> cloud emoji         ~ SF "cloud.fill"
///   Rainy  -> rain-cloud emoji    ~ SF "cloud.rain.fill"
///   Snowy  -> snowflake emoji     ~ SF "cloud.snow.fill"
///   Foggy  -> fog emoji           ~ SF "cloud.fog.fill"
///   Haze   -> fog emoji           ~ SF "aqi.medium"
///   Stormy -> storm-cloud emoji   ~ SF "cloud.bolt.rain.fill"
///   Unknown-> question-mark emoji ~ SF "questionmark.circle"
/// </summary>
public sealed class WeatherConditionToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        return key switch
        {
            "Clear" => "☀️",   // sun                  ~ SF sun.max.fill
            "Cloudy" => "☁️",  // cloud                ~ SF cloud.fill
            "Rainy" => "🌧️",   // rain cloud           ~ SF cloud.rain.fill
            "Snowy" => "❄️",   // snowflake            ~ SF cloud.snow.fill
            "Foggy" => "☁️",   // cloud (🌫️ FOG renders as tofu in Segoe UI Emoji) ~ SF cloud.fog.fill
            "Haze" => "☁️",    // cloud (🌫️ FOG renders as tofu)                   ~ SF aqi.medium
            "Stormy" => "⛈️",  // storm cloud + bolt   ~ SF cloud.bolt.rain.fill
            _ => "❓"          // question mark (Unknown) ~ SF questionmark.circle
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// WeatherConditionKey (Clear/Cloudy/Rainy/Snowy/Foggy/Haze/Stormy/Unknown) -> whether the
/// animated WeatherBackdrop renders falling rain. Only wet conditions (Rainy/Stormy) turn rain
/// on; everything else shows the star field alone — mirroring the Mac, whose rain particle layer
/// only runs under wet weather (the current 多云 dashboard is stars-only, no rain).
/// </summary>
public sealed class WeatherConditionToRainConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        (value as string) is "Rainy" or "Stormy";

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Condition enum name -> a VECTOR weather glyph (Geometry) for a Path, replacing the color
/// emoji that read as cheap next to the Mac's SF Symbol vector icons. Clear → a sun (rays +
/// disc); every cloud-bearing condition → a filled cloud (rain/snow/fog/haze/storm are told
/// apart by colour via WeatherConditionToBrushConverter + the animated backdrop, mirroring the
/// Mac which also leans on colour + the effect layer). Material-style 24-unit paths, scaled by
/// the Path's Stretch=Uniform. Tune/extend (dedicated rain/snow glyphs) on device.
/// </summary>
public sealed class WeatherConditionToPathConverter : IValueConverter
{
    // Material wb_sunny (24-unit): disc + 8 rays.
    private const string SunPath =
        "M6.76 4.84l-1.8-1.79-1.41 1.41 1.79 1.79 1.42-1.41zM4 10.5H1v2h3v-2zm9-9.95h-2V3.5h2V.55z" +
        "m7.45 3.91l-1.41-1.41-1.79 1.79 1.41 1.41 1.79-1.79zm-3.21 13.7l1.79 1.8 1.41-1.41-1.8-1.79-1.4 1.4z" +
        "M20 10.5v2h3v-2h-3zm-8-5c-3.31 0-6 2.69-6 6s2.69 6 6 6 6-2.69 6-6-2.69-6-6-6zm-1 16.95h2V19.5h-2v2.95z" +
        "m-7.45-3.91l1.41 1.41 1.79-1.8-1.41-1.41-1.79 1.8z";

    // Material cloud (24-unit): a filled cloud silhouette.
    private const string CloudPath =
        "M19.35 10.04A7.49 7.49 0 0 0 12 4C9.11 4 6.6 5.64 5.35 8.04A5.994 5.994 0 0 0 0 14" +
        "c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z";

    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        var data = key == "Clear" ? SunPath : CloudPath;
        return (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Condition enum name -> the accent brush used for the glyph + glow, mirroring the Mac
/// iconColor: clear=yellow, cloudy=gray, rainy=blue, snowy=cyan, foggy/haze=gray,
/// stormy=purple/violet, unknown=gray. Resolves to the weather theme brushes.
/// </summary>
public sealed class WeatherConditionToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        var brushKey = key switch
        {
            "Clear" => "SkyBridgeWeatherClearBrush",      // yellow
            "Cloudy" => "SkyBridgeWeatherCloudyBrush",    // gray
            "Rainy" => "SkyBridgeWeatherRainyBrush",      // blue
            "Snowy" => "SkyBridgeWeatherSnowyBrush",      // cyan
            "Foggy" => "SkyBridgeWeatherCloudyBrush",     // gray
            "Haze" => "SkyBridgeWeatherCloudyBrush",      // gray
            "Stormy" => "SkyBridgeWeatherStormyBrush",    // purple/violet
            _ => "SkyBridgeWeatherCloudyBrush"            // gray (Unknown)
        };

        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Weather metric Key (Humidity / Wind speed / Visibility / AQI) -> the metric cell
/// glyph, rendered as a COLOR EMOJI via a TextBlock with FontFamily="Segoe UI Emoji"
/// (Segoe Fluent Icons has no weather/humidity/AQI glyphs). Mirrors the Mac per-metric
/// SF Symbols:
///   Humidity   -> droplet emoji ~ SF "humidity.fill"
///   Wind speed -> wind emoji    ~ SF "wind"
///   Visibility -> eye emoji     ~ SF "eye.fill"
///   AQI        -> leaf emoji    ~ SF "aqi.medium"
/// </summary>
public sealed class WeatherMetricKeyToGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        return key switch
        {
            "Humidity" => "💧",    // droplet ~ humidity.fill
            "Wind speed" => "💨",  // wind ~ wind
            "Visibility" => "👁️",  // eye ~ eye.fill
            "AQI" => "🍃",         // leaf / air-quality ~ aqi.medium
            _ => "📊"              // bar chart ~ generic metric
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Weather metric TintKey (a SkyBridgeWeather* brush resource key produced by the client:
/// humidity=cyan, wind=mint, visibility=blue, and the AQI*-bucket colors green/yellow/
/// orange/red/purple/brown) -> the resolved Brush. The key already encodes the color, so
/// this just resolves it through the standard fallback chain.
/// </summary>
public sealed class WeatherMetricTintToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var key = value as string ?? string.Empty;
        if (string.IsNullOrWhiteSpace(key))
        {
            key = "SkyBridgeAccentBrush";
        }

        return MetricKeyToBrushConverter.ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Top-bar IP/location pill: system-proxy state (bool IsSystemProxyEnabled) -> the globe
/// icon brush. Mirrors the Mac top-bar location pill color cue: ORANGE when a system proxy
/// is configured (the egress is proxied — "代理"), BLUE when direct ("直连"). Resolves the
/// two theme brushes through the standard fallback chain so it can never crash on a missing
/// resource. true => SkyBridgeWeatherAqiOrangeBrush (orange); false => SkyBridgeWeatherRainyBrush
/// (the same blue used for the "rainy"/info accent elsewhere).
/// </summary>
public sealed class SystemProxyStateToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var proxyEnabled = value is bool flag && flag;
        var brushKey = proxyEnabled
            ? "SkyBridgeWeatherAqiOrangeBrush" // orange — proxied egress
            : "SkyBridgeWeatherRainyBrush";     // blue — direct connection
        return MetricKeyToBrushConverter.ResolveBrush(brushKey);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>
/// Weather phase token ("Loading" | "Loaded" | "Error") -> Visibility. The target phase
/// is passed as the ConverterParameter; the element is Visible only when the current
/// phase string equals that parameter. Drives the three mutually-exclusive state layers
/// (loading spinner / loaded content / error+retry) the way the Mac body state machine
/// does, with no extra VM booleans.
/// </summary>
public sealed class WeatherPhaseToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var phase = value as string ?? string.Empty;
        var target = parameter as string ?? string.Empty;
        return string.Equals(phase, target, StringComparison.Ordinal)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
