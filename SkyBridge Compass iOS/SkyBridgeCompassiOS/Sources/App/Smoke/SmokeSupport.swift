#if DEBUG || SKYBRIDGE_TESTING
import Foundation
import SwiftUI
import SkyBridgeRealtimeMedia
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

func skyBridgeIsSameRealtimeMediaRelayAddress(
    _ lhs: SkyBridgeMediaEndpoint,
    _ rhs: SkyBridgeMediaEndpoint
) -> Bool {
    lhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == rhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        && lhs.port == rhs.port
}

final class SmokeAudioRelayTrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: UInt64 = 0

    func increment() {
        lock.lock()
        packets &+= 1
        lock.unlock()
    }

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }
}

#if canImport(WebRTC)
@available(iOS 17.0, *)
struct LocalWebRTCSmokeNativeRenderHost: View {
    @ObservedObject private var manager = CrossNetworkWebRTCManager.instance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.001)

                    if let track = manager.remoteVideoTrack {
                        RemoteDesktopRTCVideoView(
                            track: track,
                            acceptsRenderEvidence: true,
                            uiSurface: "smokeOverlay",
                            requiresRemoteDesktopAdmission: false
                        )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear {
                        if let owner = manager.currentRemoteDesktopSessionOwner() {
                            _ = manager.setRemoteDesktopNativeVideoAdmission(
                                true,
                                owner: owner
                            )
                        }
                        SkyBridgeDiagnosticTrace.appendStatus(
                            "native-render-host trackId=\(track.trackId) visible=1 size=\(Int(geometry.size.width))x\(Int(geometry.size.height)) source=smoke-overlay"
                        )
                    }
                    .onDisappear {
                        if let owner = manager.currentRemoteDesktopSessionOwner() {
                            _ = manager.setRemoteDesktopNativeVideoAdmission(
                                false,
                                owner: owner
                            )
                        }
                    }
                    .onChange(of: track.trackId) { _, newTrackId in
                        SkyBridgeDiagnosticTrace.appendStatus(
                            "native-render-host trackId=\(newTrackId) visible=1 size=\(Int(geometry.size.width))x\(Int(geometry.size.height)) source=smoke-overlay"
                        )
                    }
                } else {
                    Color.clear
                        .onAppear {
                            SkyBridgeDiagnosticTrace.appendStatus(
                                "native-render-host waitingForTrack=1 size=\(Int(geometry.size.width))x\(Int(geometry.size.height)) source=smoke-overlay"
                            )
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityIdentifier("smoke.native-video.render-host")
    }
}
#endif
#endif
