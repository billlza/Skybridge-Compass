namespace Skybridge.WinClient.Services;

// ============================================================================
// SkyBridge Windows DATA PLANE — shared application-facing contract.
// ============================================================================
//
// This is the SAME interface every data-plane consumer (clipboard, file
// transfer, remote desktop) codes against. It abstracts the helper's loopback
// IPC + WebRTC DataChannel behind a channel-multiplexed byte plane.
//
// Channel codes are the SBF1 channel byte (core/skybridge-core/src/frame.rs):
//   1=Control 2=File 3=Clipboard 4=Telemetry 5=Realtime.
//
// FrameReceived raises ONE event per inbound logical message — i.e. the payload
// reassembled across all SBF1 fragments up to and including the frame carrying
// the END_OF_MESSAGE flag (0x0002). Consumers therefore receive whole messages
// per channel, never raw fragments. (Reassembly lives in the client; the helper
// is a verbatim per-frame pipe.)
public enum DataPlaneChannel
{
    Control = 1,
    File = 2,
    Clipboard = 3,
    Telemetry = 4,
    Realtime = 5,
}

public interface ISkyBridgeDataPlane
{
    /// <summary>
    /// True when the loopback IPC to the helper is live. (When the helper
    /// surfaces DataChannel state, this also reflects that the peer channel is
    /// open; today the helper only accepts an IPC connection once its
    /// DataChannel has opened, so a live IPC implies a live DataChannel.)
    /// </summary>
    bool IsConnected { get; }

    /// <summary>
    /// Sends a payload on the given channel. The payload is wrapped in one SBF1
    /// frame with the END_OF_MESSAGE flag set (callers that need to stream a
    /// large message as multiple fragments use the chunking overload, if any, or
    /// pass already-sized chunks). Fails closed if the IPC is not connected.
    /// </summary>
    System.Threading.Tasks.Task SendAsync(
        DataPlaneChannel channel,
        System.ReadOnlyMemory<byte> payload,
        System.Threading.CancellationToken ct = default);

    /// <summary>
    /// Raised once per inbound logical message: (channel, fully reassembled
    /// payload). Dispatched on a background pump thread — handlers must marshal
    /// to the UI thread themselves.
    /// </summary>
    event System.Action<DataPlaneChannel, byte[]> FrameReceived;
}
