using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services;

/// <summary>
/// Bridges the WinUI client with the Rust core via FFI.
/// </summary>
public sealed class CoreBridge
{
    public Task<bool> InitializeAsync()
    {
        return Task.Run(() =>
        {
            try
            {
                // Placeholder for future FFI call.
                NativeMethods.InitializeCore();
                return true;
            }
            catch (DllNotFoundException)
            {
                return false;
            }
        });
    }

    private static class NativeMethods
    {
        [DllImport("skybridge_core", EntryPoint = "skybridge_core_initialize")]
        public static extern void InitializeCore();
    }
}
