import Foundation

struct WebRTCRemoteDesktopStreamBudget: Sendable, Equatable {
    let frameRate: Int
    let maxBufferedAmountBytes: UInt64
    let reason: String
}

enum WebRTCRemoteDesktopBudgetSelector {
    static func select(
        requestedFrameRate: Int,
        transportPath: WebRTCSession.ICETransportPath,
        thermalState: ProcessInfo.ThermalState,
        longEdge: Int,
        lowLatencyMode: Bool,
        codec: RemoteFrameType = .bgra,
        enableHardwareAcceleration: Bool = true,
        enableAppleSiliconOptimization: Bool = true,
        isAppleSilicon: Bool = false
    ) -> WebRTCRemoteDesktopStreamBudget {
        let requested = max(4, min(requestedFrameRate, 120))
        var fpsCap: Int
        var bufferCap: UInt64
        let baseReason: String

        switch transportPath {
        case .direct:
            switch codec {
            case .bgra:
                if longEdge >= 5120 {
                    fpsCap = 24
                } else if longEdge >= 3840 {
                    fpsCap = 30
                } else {
                    fpsCap = lowLatencyMode ? 45 : 30
                }
                bufferCap = 1_500_000
                baseReason = "direct-jpeg"
            case .h264:
                if longEdge >= 5120 {
                    fpsCap = 60
                } else if longEdge >= 3840 {
                    fpsCap = 60
                } else {
                    fpsCap = lowLatencyMode ? 120 : 90
                }
                bufferCap = 2_000_000
                baseReason = "direct-h264"
            case .hevc:
                if longEdge >= 5120 {
                    fpsCap = isAppleSilicon && enableHardwareAcceleration && enableAppleSiliconOptimization ? 120 : 60
                } else if longEdge >= 3840 {
                    fpsCap = isAppleSilicon ? 90 : 60
                } else {
                    fpsCap = lowLatencyMode ? 120 : 90
                }
                bufferCap = 2_500_000
                baseReason = "direct-hevc"
            }
        case .relay:
            if longEdge >= 5120 {
                fpsCap = 8
            } else if longEdge >= 3840 {
                fpsCap = 12
            } else {
                fpsCap = 15
            }
            bufferCap = 384_000
            baseReason = "relay-conservative"
        case .unknown:
            switch codec {
            case .bgra:
                if longEdge >= 5120 {
                    fpsCap = 12
                } else if longEdge >= 3840 {
                    fpsCap = 18
                } else {
                    fpsCap = 24
                }
                bufferCap = 768_000
                baseReason = "unknown-path-jpeg"
            case .h264:
                if longEdge >= 5120 {
                    fpsCap = 16
                } else if longEdge >= 3840 {
                    fpsCap = 24
                } else {
                    fpsCap = lowLatencyMode ? 30 : 24
                }
                bufferCap = 1_024_000
                baseReason = "unknown-path-h264"
            case .hevc:
                if longEdge >= 5120 {
                    fpsCap = 18
                } else if longEdge >= 3840 {
                    fpsCap = 24
                } else {
                    fpsCap = lowLatencyMode ? 30 : 24
                }
                bufferCap = 1_152_000
                baseReason = "unknown-path-hevc"
            }
        }

        switch thermalState {
        case .nominal:
            break
        case .fair:
            switch transportPath {
            case .relay:
                fpsCap = min(fpsCap, 10)
            case .direct:
                switch codec {
                case .bgra:
                    fpsCap = min(fpsCap, 24)
                case .h264, .hevc:
                    fpsCap = min(fpsCap, longEdge >= 5120 ? 90 : 60)
                }
            case .unknown:
                fpsCap = min(fpsCap, 18)
            }
        case .serious:
            switch transportPath {
            case .relay:
                fpsCap = min(fpsCap, 8)
                bufferCap = min(bufferCap, 256_000)
            case .direct:
                switch codec {
                case .bgra:
                    fpsCap = min(fpsCap, 12)
                    bufferCap = min(bufferCap, 512_000)
                case .h264, .hevc:
                    fpsCap = min(fpsCap, longEdge >= 3840 ? 45 : 60)
                    bufferCap = min(bufferCap, 1_000_000)
                }
            case .unknown:
                fpsCap = min(fpsCap, 8)
                bufferCap = min(bufferCap, 256_000)
            }
        case .critical:
            switch transportPath {
            case .direct:
                fpsCap = min(fpsCap, codec == .bgra ? 8 : 24)
                bufferCap = min(bufferCap, codec == .bgra ? 128_000 : 384_000)
            case .relay, .unknown:
                fpsCap = min(fpsCap, 4)
                bufferCap = min(bufferCap, 128_000)
            }
        @unknown default:
            fpsCap = min(fpsCap, 12)
        }

        if transportPath == .direct {
            if !enableHardwareAcceleration {
                fpsCap = min(fpsCap, codec == .bgra ? 20 : 30)
            }
            if !enableAppleSiliconOptimization {
                fpsCap = min(fpsCap, codec == .hevc ? 60 : fpsCap)
            }
        } else if !enableHardwareAcceleration {
            fpsCap = min(fpsCap, codec == .bgra ? fpsCap : 20)
            bufferCap = min(bufferCap, codec == .bgra ? bufferCap : 512_000)
        }

        return WebRTCRemoteDesktopStreamBudget(
            frameRate: max(4, min(requested, fpsCap)),
            maxBufferedAmountBytes: bufferCap,
            reason: baseReason
        )
    }
}
