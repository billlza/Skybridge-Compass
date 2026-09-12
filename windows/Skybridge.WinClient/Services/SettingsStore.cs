using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skybridge.WinClient.Services;

// =====================================================================================
//  SettingsStore — at-rest persistence of the Windows Settings page. Writes the typed
//  SkyBridgeSettings model as plaintext JSON to %LOCALAPPDATA%\SkyBridge\settings.json
//  (the same directory the SessionStore uses for session.bin).
//
//  This is modeled BYTE-FOR-BYTE on SessionStore.cs's defensive style, with ONE difference:
//  settings are NOT secrets, so there is NO DPAPI. ProtectedData would only make the file
//  impossible to inspect/diff and add a crypto failure mode for no security benefit. Plain
//  System.Text.Json (JsonIgnoreCondition.WhenWritingNull) is used, exactly like SessionStore's
//  JsonOptions.
//
//  Missing state is the only first-run default path. Empty files, corrupt JSON, schema
//  mismatch, validation failure, save failure, reset failure, and import/export failure
//  are typed results so settings-runtime truth cannot silently drift.
//
//  Schema versioning: SkyBridgeSettings carries SchemaVersion (starts at 1). A loaded file whose
//  SchemaVersion does not match the current version is treated as foreign → defaults (clean
//  migration boundary for the future).
// =====================================================================================

public interface ISettingsStore
{
    SettingsStoreLoadResult Load();

    SettingsStoreWriteResult Save(SkyBridgeSettings settings);

    SettingsStoreWriteResult Reset();

    SettingsStoreWriteResult ExportTo(string path, SkyBridgeSettings settings);

    SettingsStoreLoadResult ImportFrom(string path);
}

public sealed class SettingsStore : ISettingsStore
{
    // The schema version this build writes/expects. Bump when the model changes in a
    // non-backward-compatible way; a mismatch on Load() falls back to defaults.
    public const int CurrentSchemaVersion = 1;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    private readonly string _directory;
    private readonly string _filePath;

    public SettingsStore(string? directory = null)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _directory = directory ?? Path.Combine(localAppData, "SkyBridge");
        _filePath = Path.Combine(_directory, "settings.json");
    }

    /// <summary>Absolute path to the on-disk settings file (for diagnostics / Export defaults).</summary>
    public string FilePath => _filePath;

    public SettingsStoreWriteResult Save(SkyBridgeSettings settings)
    {
        var validation = Validate(settings);
        if (validation is not null)
        {
            return SettingsStoreWriteResult.InvalidSettings(validation);
        }

        var json = JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions);
        try
        {
            Directory.CreateDirectory(_directory);
            File.WriteAllBytes(_filePath, json);
            return SettingsStoreWriteResult.Saved();
        }
        catch (Exception ex) when (IsStorageBoundaryException(ex))
        {
            return SettingsStoreWriteResult.IoFailure("settings_save_io_failure");
        }
    }

    public SettingsStoreLoadResult Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return SettingsStoreLoadResult.MissingDefaults(new SkyBridgeSettings());
            }

            var bytes = File.ReadAllBytes(_filePath);
            if (bytes.Length == 0)
            {
                return SettingsStoreLoadResult.EmptyFile(new SkyBridgeSettings());
            }

            var loaded = JsonSerializer.Deserialize<SkyBridgeSettings>(bytes, JsonOptions);
            if (loaded is null)
            {
                return SettingsStoreLoadResult.InvalidSettings(new SkyBridgeSettings(), "settings_json_empty");
            }

            // Schema drift / foreign blob — treat as first run rather than honoring stale shapes.
            if (loaded.SchemaVersion != CurrentSchemaVersion)
            {
                return SettingsStoreLoadResult.SchemaMismatch(new SkyBridgeSettings());
            }

            var validation = Validate(loaded);
            return validation is null
                ? SettingsStoreLoadResult.Loaded(loaded)
                : SettingsStoreLoadResult.InvalidSettings(new SkyBridgeSettings(), validation);
        }
        catch (JsonException)
        {
            return SettingsStoreLoadResult.InvalidJson(new SkyBridgeSettings());
        }
        catch (Exception ex) when (IsStorageBoundaryException(ex))
        {
            return SettingsStoreLoadResult.IoFailure(new SkyBridgeSettings());
        }
    }

    public SettingsStoreWriteResult Reset()
    {
        try
        {
            if (File.Exists(_filePath))
            {
                File.Delete(_filePath);
            }

            return SettingsStoreWriteResult.Reset();
        }
        catch (Exception ex) when (IsStorageBoundaryException(ex))
        {
            return SettingsStoreWriteResult.IoFailure("settings_reset_io_failure");
        }
    }

    /// <summary>
    /// Serialize the given settings to an arbitrary path (the user-chosen Export target). Throws
    /// on failure so the caller can surface a status — Export is an explicit user action, unlike
    /// the silent best-effort Save.
    /// </summary>
    public SettingsStoreWriteResult ExportTo(string path, SkyBridgeSettings settings)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return SettingsStoreWriteResult.IoFailure("settings_export_path_missing");
        }

        var validation = Validate(settings);
        if (validation is not null)
        {
            return SettingsStoreWriteResult.InvalidSettings(validation);
        }

        var json = JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions);
        try
        {
            File.WriteAllBytes(path, json);
            return SettingsStoreWriteResult.Exported();
        }
        catch (Exception ex) when (IsStorageBoundaryException(ex))
        {
            return SettingsStoreWriteResult.IoFailure("settings_export_io_failure");
        }
    }

    /// <summary>
    /// Deserialize settings from an arbitrary path (the user-chosen Import source). Missing,
    /// empty, corrupt, foreign-schema, and invalid files are explicit untrusted failures so the
    /// caller can leave the current settings untouched and report the failure honestly.
    /// </summary>
    public SettingsStoreLoadResult ImportFrom(string path)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                return SettingsStoreLoadResult.MissingFile(new SkyBridgeSettings());
            }

            var bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0)
            {
                return SettingsStoreLoadResult.EmptyFile(new SkyBridgeSettings());
            }

            var loaded = JsonSerializer.Deserialize<SkyBridgeSettings>(bytes, JsonOptions);
            if (loaded is null)
            {
                return SettingsStoreLoadResult.InvalidSettings(new SkyBridgeSettings(), "settings_json_empty");
            }

            if (loaded.SchemaVersion != CurrentSchemaVersion)
            {
                return SettingsStoreLoadResult.SchemaMismatch(new SkyBridgeSettings());
            }

            var validation = Validate(loaded);
            return validation is null
                ? SettingsStoreLoadResult.Loaded(loaded)
                : SettingsStoreLoadResult.InvalidSettings(new SkyBridgeSettings(), validation);
        }
        catch (JsonException)
        {
            return SettingsStoreLoadResult.InvalidJson(new SkyBridgeSettings());
        }
        catch (Exception ex) when (IsStorageBoundaryException(ex))
        {
            return SettingsStoreLoadResult.IoFailure(new SkyBridgeSettings());
        }
    }

    private static string? Validate(SkyBridgeSettings? settings)
    {
        if (settings is null)
        {
            return "settings_null";
        }

        if (settings.SchemaVersion != CurrentSchemaVersion)
        {
            return "settings_schema_mismatch";
        }

        if (!IsOneOf(settings.Language, "system", "en-US", "zh-Hans", "ja"))
        {
            return "settings_language_invalid";
        }

        if (settings.AppearanceMode is not (null or "system" or "dark" or "light")
            || settings.BackgroundTheme is not ("weather" or "starryNight" or "deepSpace" or "aurora" or "classic" or "custom")
            || (settings.BackgroundTheme == "custom" && string.IsNullOrWhiteSpace(settings.CustomBackgroundPath)))
        {
            return "settings_appearance_invalid";
        }

        if (!IsHexColor(settings.ThemeColorHex))
        {
            return "settings_theme_color_invalid";
        }

        if (settings.ScanInterval < 5 || settings.ScanInterval > 3600
            || settings.WifiScanTimeout < 1 || settings.WifiScanTimeout > 120
            || settings.DiscoveryTimeout < 1 || settings.DiscoveryTimeout > 300
            || settings.ConnectionTimeout < 1 || settings.ConnectionTimeout > 300
            || settings.RetryCount < 0 || settings.RetryCount > 10)
        {
            return "settings_network_range_invalid";
        }

        if (settings.MinimumSignalStrength < -120 || settings.MinimumSignalStrength > 0)
        {
            return "settings_signal_strength_invalid";
        }

        if (string.IsNullOrWhiteSpace(settings.DefaultTransferPath)
            || settings.MaxConcurrentConnections < 1
            || settings.MaxConcurrentConnections > 128
            || settings.TransferBufferSize < 4096
            || settings.TransferBufferSize > 16 * 1024 * 1024
            || settings.TransferSpeedLimitMBps < 0)
        {
            return "settings_file_transfer_invalid";
        }

        if (!IsOneOf(settings.VideoResolution, "hd720p", "hd1080p", "qhd1440p", "uhd4k")
            || !IsOneOf(settings.VideoFrameRate, "fps15", "fps30", "fps60")
            || !IsOneOf(settings.VideoCompressionQuality, "speed", "balanced", "quality")
            || settings.MouseSensitivity <= 0
            || settings.DoubleClickInterval < 100
            || settings.DoubleClickInterval > 2000
            || settings.RdNetworkCompressionLevel < 0
            || settings.RdNetworkCompressionLevel > 9
            || settings.RdBufferSize < 256
            || settings.RdBufferSize > 65536
            || settings.RdBandwidthLimit < 0)
        {
            return "settings_remote_desktop_invalid";
        }

        if (settings.SystemMonitorRefreshInterval <= 0
            || settings.SystemMonitorRetentionDays < 1
            || settings.SystemMonitorRetentionDays > 365
            || settings.MaxHistoryPoints < 1
            || settings.CpuThreshold < 0
            || settings.CpuThreshold > 100
            || settings.MemoryThreshold < 0
            || settings.MemoryThreshold > 100
            || settings.TemperatureThreshold < 0
            || settings.TemperatureThreshold > 120
            || settings.FanSpeedThreshold < 0
            || settings.DiskThreshold < 0
            || settings.DiskThreshold > 100)
        {
            return "settings_monitor_invalid";
        }

        if (!IsOneOf(settings.LogLevel, "Trace", "Debug", "Info", "Warning", "Error", "Critical")
            || !IsOneOf(settings.PerformanceMode, "balanced", "performance", "battery")
            || !IsOneOf(settings.PqcSignatureAlgorithm, "ML-DSA-65", "Ed25519")
            || settings.SignalStrengthAlpha < 0
            || settings.SignalStrengthAlpha > 1)
        {
            return "settings_advanced_invalid";
        }

        foreach (var serviceType in settings.CustomServiceTypes ?? Array.Empty<string>())
        {
            if (string.IsNullOrWhiteSpace(serviceType)
                || serviceType.Length > 128
                || !serviceType.StartsWith('_'))
            {
                return "settings_service_type_invalid";
            }
        }

        return null;
    }

    private static bool IsOneOf(string? value, params string[] allowed)
    {
        foreach (var candidate in allowed)
        {
            if (string.Equals(value, candidate, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsHexColor(string? value)
    {
        if (value is null || value.Length != 7 || value[0] != '#')
        {
            return false;
        }

        for (var i = 1; i < value.Length; i++)
        {
            var c = value[i];
            var hex = c is >= '0' and <= '9'
                || c is >= 'a' and <= 'f'
                || c is >= 'A' and <= 'F';
            if (!hex)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsStorageBoundaryException(Exception ex) =>
        ex is IOException
            or UnauthorizedAccessException
            or ArgumentException
            or NotSupportedException;
}

public enum SettingsStoreLoadStatus
{
    Loaded,
    MissingDefaults,
    MissingFile,
    EmptyFile,
    InvalidJson,
    SchemaMismatch,
    InvalidSettings,
    IoFailure
}

public sealed record SettingsStoreLoadResult(
    SettingsStoreLoadStatus Status,
    SkyBridgeSettings Settings,
    bool Trusted,
    string ErrorCode)
{
    public bool Succeeded => Status is SettingsStoreLoadStatus.Loaded or SettingsStoreLoadStatus.MissingDefaults;

    public static SettingsStoreLoadResult Loaded(SkyBridgeSettings settings) =>
        new(SettingsStoreLoadStatus.Loaded, settings, true, string.Empty);

    public static SettingsStoreLoadResult MissingDefaults(SkyBridgeSettings settings) =>
        new(SettingsStoreLoadStatus.MissingDefaults, settings, true, string.Empty);

    public static SettingsStoreLoadResult MissingFile(SkyBridgeSettings defaults) =>
        new(SettingsStoreLoadStatus.MissingFile, defaults, false, "settings_missing_file");

    public static SettingsStoreLoadResult EmptyFile(SkyBridgeSettings defaults) =>
        new(SettingsStoreLoadStatus.EmptyFile, defaults, false, "settings_empty_file");

    public static SettingsStoreLoadResult InvalidJson(SkyBridgeSettings defaults) =>
        new(SettingsStoreLoadStatus.InvalidJson, defaults, false, "settings_invalid_json");

    public static SettingsStoreLoadResult SchemaMismatch(SkyBridgeSettings defaults) =>
        new(SettingsStoreLoadStatus.SchemaMismatch, defaults, false, "settings_schema_mismatch");

    public static SettingsStoreLoadResult InvalidSettings(SkyBridgeSettings defaults, string code) =>
        new(SettingsStoreLoadStatus.InvalidSettings, defaults, false, code);

    public static SettingsStoreLoadResult IoFailure(SkyBridgeSettings defaults) =>
        new(SettingsStoreLoadStatus.IoFailure, defaults, false, "settings_io_failure");
}

public enum SettingsStoreWriteStatus
{
    Saved,
    Reset,
    Exported,
    InvalidSettings,
    IoFailure
}

public sealed record SettingsStoreWriteResult(SettingsStoreWriteStatus Status, string ErrorCode)
{
    public bool Succeeded =>
        Status is SettingsStoreWriteStatus.Saved
            or SettingsStoreWriteStatus.Reset
            or SettingsStoreWriteStatus.Exported;

    public static SettingsStoreWriteResult Saved() => new(SettingsStoreWriteStatus.Saved, string.Empty);

    public static SettingsStoreWriteResult Reset() => new(SettingsStoreWriteStatus.Reset, string.Empty);

    public static SettingsStoreWriteResult Exported() => new(SettingsStoreWriteStatus.Exported, string.Empty);

    public static SettingsStoreWriteResult InvalidSettings(string code) =>
        new(SettingsStoreWriteStatus.InvalidSettings, code);

    public static SettingsStoreWriteResult IoFailure(string code) =>
        new(SettingsStoreWriteStatus.IoFailure, code);
}
