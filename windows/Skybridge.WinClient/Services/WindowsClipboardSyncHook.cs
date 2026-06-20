using System;

namespace Skybridge.WinClient.Services;

// WindowsClipboardSyncHook
//
// Minimal, self-contained construction + lifecycle hook for clipboard sync. Kept
// in the Services folder (no edits to the shared dependency factory) so wiring is
// a single additive call once the data plane and the real session key are ready.
//
// === Where this plugs into the app lifecycle ===
// The clipboard service should live for the duration of an active P2P session: it
// needs an ISkyBridgeDataPlane (created when the session/data plane comes up) and a
// session key provider. Two integration points, pick whichever lands first:
//
//   (A) Session/data-plane owner (preferred): when the verified data plane is
//       constructed (the same place that wires Control/File channels — see the
//       transport-adapter clients), call:
//
//           _clipboardSync = WindowsClipboardSyncHook.Start(dataPlane, keyProvider);
//
//       and on teardown:  _clipboardSync?.Dispose();
//
//   (B) App composition root: WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment
//       (windows/Skybridge.WinClient/WindowsNativeRuntimeDependencyFactory.cs) is where
//       all the live clients are built. Add the started service to whatever owns the
//       session's disposables there, once SessionViewModelDependencies carries the
//       data plane. (Left un-edited deliberately: adding a ctor param there ripples
//       into every call-site and the fail-closed stubs; do it when the data plane is
//       actually threaded through.)
//
// === Session-key wiring (TODO) ===
// Pass the real handshake-derived key provider as `keyProvider`. Until then,
// `StartForBringUp` uses DerivedDevelopmentKeyProvider — bring-up only, NOT for
// production traffic (the derived key is not secret).

internal static class WindowsClipboardSyncHook
{
    /// <summary>
    /// Construct and start a clipboard sync service bound to the given data plane and
    /// session-key provider. Caller owns the returned instance and must Dispose it on
    /// session teardown.
    /// </summary>
    public static WindowsClipboardSyncService Start(
        ISkyBridgeDataPlane dataPlane,
        IClipboardSessionKeyProvider keyProvider,
        bool syncImages = true)
    {
        ArgumentNullException.ThrowIfNull(dataPlane);
        ArgumentNullException.ThrowIfNull(keyProvider);

        var service = new WindowsClipboardSyncService(dataPlane, keyProvider, syncImages);
        service.Start();
        return service;
    }

    /// <summary>
    /// Bring-up convenience: start with a deterministic development key derived from
    /// <paramref name="sharedSeed"/>. Both peers must use the SAME seed to interop.
    /// Replace with <see cref="Start"/> + the real session key before shipping.
    /// </summary>
    public static WindowsClipboardSyncService StartForBringUp(
        ISkyBridgeDataPlane dataPlane,
        string sharedSeed = "skybridge.clipboard.dev-key.v1",
        bool syncImages = true)
    {
        ArgumentNullException.ThrowIfNull(dataPlane);
        return Start(dataPlane, new DerivedDevelopmentKeyProvider(sharedSeed), syncImages);
    }
}
