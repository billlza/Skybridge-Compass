import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
@available(iOS 17.0, *)
struct RemoteDesktopRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    let acceptsRenderEvidence: Bool
    let uiSurface: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ObservableRTCMTLVideoView {
        let view = ObservableRTCMTLVideoView(frame: .zero)
        view.diagnosticTrackId = track.trackId
        view.acceptsNativeRenderEvidence = acceptsRenderEvidence
        view.uiSurface = uiSurface
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.isEnabled = true
        let renderEpoch = CrossNetworkWebRTCManager.instance.currentRemoteVideoTrackRenderToken(trackId: track.trackId)
        view.renderEpoch = renderEpoch
        view.videoContentMode = .scaleAspectFit
        view.delegate = context.coordinator
        let trackId = track.trackId
        view.onRenderedFrame = { size in
            Task { @MainActor in
                CrossNetworkWebRTCManager.instance.noteRemoteVideoTrackRenderedFrame(
                    size,
                    source: ObservableRTCMTLVideoView.nativeRenderEvidenceSource,
                    uiSurface: uiSurface,
                    trackId: trackId,
                    renderEpoch: renderEpoch
                )
                RemoteDesktopManager.instance.updateCrossNetworkNativeVideoResolution(size)
            }
        }
        context.coordinator.bind(track: track, to: view)
        SkyBridgeDiagnosticTrace.appendStatus(
            "native-render-view-bound trackId=\(track.trackId) acceptsEvidence=\(acceptsRenderEvidence ? 1 : 0) epoch=\(renderEpoch) source=rtc-mtl-video-view"
        )
        SkyBridgeLogger.shared.info(
            "🎬 WebRTC native video UIView created and bound: trackId=\(track.trackId) enabled=\(track.isEnabled)"
        )
        return view
    }

    func updateUIView(_ uiView: ObservableRTCMTLVideoView, context: Context) {
        uiView.diagnosticTrackId = track.trackId
        uiView.acceptsNativeRenderEvidence = acceptsRenderEvidence
        uiView.uiSurface = uiSurface
        uiView.isOpaque = false
        uiView.backgroundColor = .clear
        uiView.layer.isOpaque = false
        uiView.isEnabled = true
        let renderEpoch = CrossNetworkWebRTCManager.instance.currentRemoteVideoTrackRenderToken(trackId: track.trackId)
        if uiView.renderEpoch != renderEpoch {
            uiView.renderEpoch = renderEpoch
            uiView.resetVisibleRenderEvidence()
        }
        uiView.delegate = context.coordinator
        let trackId = track.trackId
        uiView.onRenderedFrame = { size in
            Task { @MainActor in
                CrossNetworkWebRTCManager.instance.noteRemoteVideoTrackRenderedFrame(
                    size,
                    source: ObservableRTCMTLVideoView.nativeRenderEvidenceSource,
                    uiSurface: uiSurface,
                    trackId: trackId,
                    renderEpoch: renderEpoch
                )
                RemoteDesktopManager.instance.updateCrossNetworkNativeVideoResolution(size)
            }
        }
        context.coordinator.bind(track: track, to: uiView)
        if acceptsRenderEvidence {
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-render-view-updated trackId=\(track.trackId) acceptsEvidence=1 epoch=\(renderEpoch) source=rtc-mtl-video-view"
            )
        }
    }

    static func dismantleUIView(_ uiView: ObservableRTCMTLVideoView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.onRenderedFrame = nil
        uiView.acceptsNativeRenderEvidence = false
        uiView.resetVisibleRenderEvidence()
        uiView.delegate = nil
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        private weak var boundTrack: RTCVideoTrack?
        private weak var boundView: ObservableRTCMTLVideoView?
        private var boundRenderer: VisibleRTCMTLVideoRenderer?

        func bind(track: RTCVideoTrack, to view: ObservableRTCMTLVideoView) {
            if boundTrack === track, boundView === view {
                return
            }
            unbind()
            track.isEnabled = true
            let renderer = VisibleRTCMTLVideoRenderer(view: view)
            boundTrack = track
            boundView = view
            boundRenderer = renderer
            track.add(renderer)
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-render-track-bound trackId=\(track.trackId) enabled=\(track.isEnabled ? 1 : 0) source=rtc-mtl-video-view renderer=forwarder"
            )
            SkyBridgeLogger.shared.debug(
                "🎬 WebRTC native video renderer bound: trackId=\(track.trackId) enabled=\(track.isEnabled)"
            )
        }

        func unbind() {
            if let boundTrack, let boundRenderer {
                boundTrack.remove(boundRenderer)
            }
            boundTrack = nil
            boundView = nil
            boundRenderer = nil
        }

        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            Task { @MainActor in
                RemoteDesktopManager.instance.updateCrossNetworkNativeVideoResolution(size)
                if let view = videoView as? ObservableRTCMTLVideoView {
                    view.noteVideoViewSizeEvidence(size)
                }
            }
        }

        private final class VisibleRTCMTLVideoRenderer: NSObject, RTCVideoRenderer {
            private weak var view: ObservableRTCMTLVideoView?
            private let logState = VisibleRenderForwarderLogState()

            init(view: ObservableRTCMTLVideoView) {
                self.view = view
            }

            func setSize(_ size: CGSize) {
                guard size.width > 0, size.height > 0 else { return }
                guard let view else { return }
                let logState = logState
                DispatchQueue.main.async { [weak view] in
                    guard let view else { return }
                    view.setSize(size)
                    view.noteVideoViewSizeEvidence(size)
                    if logState.markFirstSize() {
                        SkyBridgeDiagnosticTrace.appendStatus(
                            "native-render-forwarder-size trackId=\(view.diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) source=rtc-mtl-video-view"
                        )
                    }
                }
            }

            func renderFrame(_ frame: RTCVideoFrame?) {
                guard let frame else { return }
                let size = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
                guard size.width > 0, size.height > 0 else { return }
                guard let view else { return }
                let logState = logState
                DispatchQueue.main.async { [weak view] in
                    guard let view else { return }
                    view.renderFrame(frame)
                    if logState.markFirstFrame() {
                        SkyBridgeDiagnosticTrace.appendStatus(
                            "native-render-forwarder-frame trackId=\(view.diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) source=rtc-mtl-video-view"
                        )
                    }
                }
            }

            private final class VisibleRenderForwarderLogState: @unchecked Sendable {
                private let lock = NSLock()
                private var didLogFirstFrame = false
                private var didLogFirstSize = false

                func markFirstFrame() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didLogFirstFrame else { return false }
                    didLogFirstFrame = true
                    return true
                }

                func markFirstSize() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didLogFirstSize else { return false }
                    didLogFirstSize = true
                    return true
                }
            }
        }
    }

    final class ObservableRTCMTLVideoView: RTCMTLVideoView {
        private static let minimumVisibleNativeRenderFrames = 1
        private static let diagnosticLogInterval: TimeInterval = 1.0
        var diagnosticTrackId = "-"
        var acceptsNativeRenderEvidence = false
        var uiSurface = "remoteDesktopView"
        var renderEpoch: UInt64 = 0
        static let nativeRenderEvidenceSource = "rtc-mtl-video-view"
        var onRenderedFrame: ((CGSize) -> Void)?
        private var consecutiveVisibleRenderFrames = 0
        private var lastVisibleRenderSize: CGSize = .zero
        private var lastRenderedFrameTimestampNs: Int64?
        private var hasLoggedVisibleRenderEvidence = false
        private var hasLoggedViewSizeEvidence = false
        private var lastDiagnosticLogAt = Date.distantPast
        private var visibleRenderFrameCount = 0
        private var visibleRenderFrameWindowStart: Date?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard acceptsNativeRenderEvidence else { return }
            logNativeRenderDiagnostic(
                "layout",
                "\(visibilityDiagnostic)"
            )
        }

        override func renderFrame(_ frame: RTCVideoFrame?) {
            super.renderFrame(frame)
            guard let frame else { return }
            let size = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
            guard size.width > 0, size.height > 0 else { return }
            let timestampNs = frame.timeStampNs
            DispatchQueue.main.async { [weak self] in
                self?.noteRenderedFrameCandidate(size: size, timestampNs: timestampNs)
            }
        }

        private func noteRenderedFrameCandidate(size: CGSize, timestampNs: Int64) {
            guard isVisibleForNativeRenderEvidence else {
                logNativeRenderDiagnostic(
                    "blocked",
                    "reason=not-visible \(visibilityDiagnostic) size=\(Int(size.width))x\(Int(size.height)) timestampNs=\(timestampNs)"
                )
                resetVisibleRenderEvidence()
                return
            }
            if let lastRenderedFrameTimestampNs, timestampNs <= lastRenderedFrameTimestampNs {
                logNativeRenderDiagnostic(
                    "blocked",
                    "reason=stale-timestamp trackId=\(diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) timestampNs=\(timestampNs) lastTimestampNs=\(lastRenderedFrameTimestampNs)"
                )
                return
            }
            lastRenderedFrameTimestampNs = timestampNs
            noteVisibleRenderFrameForDiagnostics(size: size)
            if lastVisibleRenderSize == size {
                consecutiveVisibleRenderFrames += 1
            } else {
                lastVisibleRenderSize = size
                consecutiveVisibleRenderFrames = 1
                hasLoggedVisibleRenderEvidence = false
            }
            guard consecutiveVisibleRenderFrames >= Self.minimumVisibleNativeRenderFrames else {
                logNativeRenderDiagnostic(
                    "candidate",
                    "trackId=\(diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) consecutive=\(consecutiveVisibleRenderFrames)"
                )
                return
            }
            if !hasLoggedVisibleRenderEvidence {
                hasLoggedVisibleRenderEvidence = true
                SkyBridgeLogger.shared.info(
                    "🎬 WebRTC native video visible render evidence: trackId=\(diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) consecutive=\(consecutiveVisibleRenderFrames) nativeRenderEvidenceSource=\(Self.nativeRenderEvidenceSource)"
                )
            }
            onRenderedFrame?(size)
        }

        func noteVideoViewSizeEvidence(_ size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            guard isVisibleForNativeRenderEvidence else {
                logNativeRenderDiagnostic(
                    "blocked",
                    "reason=delegate-not-visible \(visibilityDiagnostic) size=\(Int(size.width))x\(Int(size.height))"
                )
                return
            }
            if !hasLoggedViewSizeEvidence {
                hasLoggedViewSizeEvidence = true
                SkyBridgeLogger.shared.info(
                    "🎬 WebRTC native video visible view-size evidence: trackId=\(diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) nativeRenderEvidenceSource=\(Self.nativeRenderEvidenceSource)"
                )
            }
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-render-view-size trackId=\(diagnosticTrackId) size=\(Int(size.width))x\(Int(size.height)) source=\(Self.nativeRenderEvidenceSource)"
            )
        }

        func resetVisibleRenderEvidence() {
            consecutiveVisibleRenderFrames = 0
            lastVisibleRenderSize = .zero
            lastRenderedFrameTimestampNs = nil
            hasLoggedVisibleRenderEvidence = false
            hasLoggedViewSizeEvidence = false
            visibleRenderFrameCount = 0
            visibleRenderFrameWindowStart = nil
        }

        private func noteVisibleRenderFrameForDiagnostics(size: CGSize) {
            let now = Date()
            if let windowStart = visibleRenderFrameWindowStart {
                visibleRenderFrameCount += 1
                let elapsed = now.timeIntervalSince(windowStart)
                guard elapsed >= 1.0 else { return }
                let fps = Double(visibleRenderFrameCount) / elapsed
                visibleRenderFrameCount = 0
                visibleRenderFrameWindowStart = now
                let sessionId = CrossNetworkWebRTCManager.instance.activeRemoteDesktopSessionId?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
                    [
                        "kind": "visibleNativeRenderFPS",
                        "session": sessionId,
                        "session_id": sessionId,
                        "source": Self.nativeRenderEvidenceSource,
                        "uiSurface": uiSurface,
                        "metricSource": "rtc-mtl-render-frame",
                        "renderPipeline": "webrtcNativeVideo",
                        "trackId": diagnosticTrackId,
                        "viewerDisplayFPS": fps,
                        "displayFPS": fps,
                        "visibleWidth": Int(size.width),
                        "visibleHeight": Int(size.height)
                    ]
                )
            } else {
                visibleRenderFrameWindowStart = now
                visibleRenderFrameCount = 1
            }
        }

        private func logNativeRenderDiagnostic(_ phase: String, _ details: String) {
            let now = Date()
            guard now.timeIntervalSince(lastDiagnosticLogAt) >= Self.diagnosticLogInterval else {
                return
            }
            lastDiagnosticLogAt = now
            SkyBridgeLogger.shared.debug(
                "🎬 WebRTC native video render diagnostic: phase=\(phase) \(details)"
            )
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-render-diagnostic phase=\(phase) \(details)"
            )
        }

        private var isVisibleForNativeRenderEvidence: Bool {
            acceptsNativeRenderEvidence
                && window != nil
                && !isHidden
                && alpha > 0.01
                && bounds.width > 0
                && bounds.height > 0
                && superview != nil
        }

        private var visibilityDiagnostic: String {
            "trackId=\(diagnosticTrackId) acceptsEvidence=\(acceptsNativeRenderEvidence) window=\(window != nil) superview=\(superview != nil) hidden=\(isHidden) alpha=\(String(format: "%.3f", alpha)) bounds=\(Int(bounds.width))x\(Int(bounds.height))"
        }
    }
}
#endif
