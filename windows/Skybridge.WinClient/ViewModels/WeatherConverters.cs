using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
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
