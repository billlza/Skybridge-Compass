using System;

namespace Skybridge.WinClient.Services;

public sealed class SettingsThemePreferenceClient(SettingsService settings) : ITopBarThemePreferenceClient
{
    private readonly SettingsService _settings = settings ?? throw new ArgumentNullException(nameof(settings));
    public string CurrentStatus => _settings.AppearanceMode switch
    {
        "system" => TopBarStatusClient.DefaultThemeStatus,
        "light" => TopBarStatusClient.LightThemeStatus,
        _ => TopBarStatusClient.DarkThemeStatus
    };
    public string Toggle()
    {
        _settings.AppearanceMode = _settings.AppearanceMode switch { "system" => "dark", "dark" => "light", _ => "system" };
        return CurrentStatus;
    }
}
