public struct RemoteDesktopSmokeDiagnosticSnapshot: Sendable, Equatable {
    public let stateDescription: String
    public let isStreaming: Bool
    public let isUsingCrossNetworkTransport: Bool
    public let transportStatusText: String?
    public let presentationOwnerCount: Int
    public let frameRate: Double
    public let receivedFrameRate: Double
    public let latencyMilliseconds: Double
    public let resolutionWidth: Int
    public let resolutionHeight: Int
    public let renderPipeline: RemoteDesktopRenderPipeline
    public let renderOrientation: RemoteDesktopRenderOrientation
    public let receivedFramesInStream: Int
    public let displayedFramesInStream: Int
    public let receivedFrameClock: String
    public let receivedFramesInLastTwoSeconds: Int
    public let socketArrivalFramesInLastTwoSeconds: Int
    public let sourceCadenceFramesInLastTwoSeconds: Int
    public let metalDeliveryFramesInLastTwoSeconds: Int
    public let displayedFramesInLastTwoSeconds: Int
    public let lastFrameArrivalAgeSeconds: Double?
    public let lastDisplayedFrameAgeSeconds: Double?
    public let metalFrameAgeMaxInLastTwoSecondsMs: Int?
    public let realtimeAudio: RemoteDesktopSmokeAudioDiagnosticSnapshot?
    public let audioChannelCount: Int?

    public var hasActivePresentationOwner: Bool {
        presentationOwnerCount > 0
    }
}
