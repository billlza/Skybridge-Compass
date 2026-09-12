using System.Text.Json;

namespace Skybridge.WinClient.Services;

internal static class AccountDevicePresentation
{
    private static readonly Lazy<IReadOnlyDictionary<string, string>> AppleModels = new(() =>
    {
        using var stream = typeof(AccountDevicePresentation).Assembly.GetManifestResourceStream("Skybridge.AccountDevices.AppleModels.json")
            ?? throw new InvalidDataException("Packaged Apple model catalogue is absent.");
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? throw new InvalidDataException("Apple model catalogue is invalid.");
    });
    internal static string Model(string? model, string? platform, Func<string, string> text)
    {
        if (string.IsNullOrWhiteSpace(model)) return text("AccountDeviceModelUnknown");
        if (AppleModels.Value.TryGetValue(model.Trim().ToLowerInvariant(), out string? name)) return name;
        // Manufacturer model codes are kept as evidence; never infer from user names.
        return model;
    }
    internal static string Glyph(string? platform) => platform switch
    { "ios" or "android" => "\uE8EA", "ipados" => "\uE70A", "macos" or "windows" or "linux" => "\uE7F4", _ => "\uE772" };
}
