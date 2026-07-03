using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Skybridge.WinClient.Services;

internal static class SkybridgeNativeLibraryResolver
{
    private const string LibraryName = "skybridge_core";

    private static readonly object Sync = new();
    private static bool _registered;

    public static void Register()
    {
        lock (Sync)
        {
            if (_registered)
            {
                return;
            }

            NativeLibrary.SetDllImportResolver(typeof(SkybridgeNativeLibraryResolver).Assembly, Resolve);
            _registered = true;
        }
    }

    private static nint Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, LibraryName, StringComparison.Ordinal))
        {
            return nint.Zero;
        }

        var libraryPath = Path.Combine(AppContext.BaseDirectory, GetPlatformLibraryFileName());
        if (!File.Exists(libraryPath))
        {
            throw new DllNotFoundException(
                $"SkyBridge native Core library was not found in the application directory: {libraryPath}");
        }

        return NativeLibrary.Load(libraryPath);
    }

    private static string GetPlatformLibraryFileName()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return "skybridge_core.dll";
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return "libskybridge_core.dylib";
        }

        return "libskybridge_core.so";
    }
}
