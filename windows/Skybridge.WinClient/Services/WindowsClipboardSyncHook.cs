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
// needs an ISkyBridgeDataPlane (created when the session/data plane comes up) and
// the per-session secret material that derives the AES-256 clipboard key. Two
// integration points, pick whichever lands first:
//
//   (A) Session/data-plane owner (preferred): when the verified data plane is
//       constructed (the same place that wires Control/File channels — see the
//       transport-adapter clients), the WebRTC proof + the validated pairing code
//       are BOTH already in hand. Call:
//
//           _clipboardSync = WindowsClipboardSyncHook.StartForSession(
//               dataPlane,
//               sharedPairingSecret: <the validated connection code>,
//               sessionId:          <proof.transportSecretFingerprintHex>);
//
//       and on teardown:  _clipboardSync?.Dispose();
//
//   (B) App composition root: WindowsNativeRuntimeDependencyFactory.CreateFromEnvironment
//       (windows/Skybridge.WinClient/WindowsNativeRuntimeDependencyFactory.cs) is where
//       all the live clients are built. Add the started service to whatever owns the
//       session's disposables there, once SessionViewModelDependencies carries both the
//       data plane AND the session binding (connection code + proof). (Left un-edited
//       deliberately: adding ctor params there ripples into every call-site and the
//       fail-closed stubs; do it when the data plane is actually threaded through.)
//
// === Session-key wiring (DONE — no dev-key fallback) ===
// The key is derived from REAL per-session secret material via HKDF-SHA256
// (ClipboardKeyDerivation): IKM = the shared pairing/connection secret, salt = the
// per-session id (the WebRTC proof's transportSecretFingerprintHex), info =
// "skybridge-clipboard-key-v1". There is NO development-key path in release: the
// previous DerivedDevelopmentKeyProvider is now a DEBUG-only test type
// (TestOnlyDeterministicClipboardKeyProvider) and is not reachable here. If the
// session material is missing, this hook throws and the caller must NOT start
// clipboard sync (fail closed; never send under public pairing material or a
// placeholder key).

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
    /// Start clipboard sync for an active P2P session, deriving the AES-256 key from
    /// the session's real secret material via HKDF-SHA256.
    /// </summary>
    /// <param name="dataPlane">The live data plane (clipboard rides channel 3).</param>
    /// <param name="sharedPairingSecret">
    /// The shared pairing/connection secret both peers possess (the validated
    /// non-public secret, not the public pairing envelope). Used as the HKDF input
    /// keying material. Must be non-empty.
    /// </param>
    /// <param name="sessionId">
    /// The per-session, both-sides-observable id used as the HKDF salt — the WebRTC
    /// proof's <c>transportSecretFingerprintHex</c>. Must be non-empty so a NEW
    /// session derives a DISTINCT key from the same pairing secret.
    /// </param>
    /// <exception cref="ArgumentException">If either secret input is missing/blank (fail closed).</exception>
    public static WindowsClipboardSyncService StartForSession(
        ISkyBridgeDataPlane dataPlane,
        string sharedPairingSecret,
        string sessionId,
        bool syncImages = true)
    {
        ArgumentNullException.ThrowIfNull(dataPlane);
        var keyProvider = ClipboardKeyProviders.CreateForSession(sharedPairingSecret, sessionId);
        return Start(dataPlane, keyProvider, syncImages);
    }
}
