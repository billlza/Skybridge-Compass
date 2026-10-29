import SkyBridgeProtocolCore

enum AudioPlaybackFailureDiagnostic {
    static func label(for error: Error) -> String {
        #if os(macOS)
        if let output = error as? CoreAudioOpusOutputError {
            let code: String
            switch output {
            case .invalidOwner: code = "invalid_owner"
            case .wrongOwner: code = "wrong_owner"
            case .invalidState: code = "invalid_state"
            case .invalidFormat: code = "invalid_format"
            case .invalidSourceCount: code = "invalid_source_count"
            case .busy: code = "busy"
            case .authorizationLost: code = "authorization_lost"
            case .insufficientPrefill: code = "insufficient_prefill"
            case .endpointChanged: code = "endpoint_changed"
            case .engineStopped: code = "engine_stopped"
            case .underrun: code = "underrun"
            case .invalidCallback: code = "invalid_callback"
            case .invalidTimeline: code = "invalid_timeline"
            case .timedOut: code = "timed_out"
            case .cleanupUnconfirmed: code = "cleanup_unconfirmed"
            case .native(let status): code = "native.\(status)"
            }
            return "opus_output." + code
        }
        #endif
        return SkyBridgeProtocolCore.AudioPlaybackFailureDiagnostic.label(for: error)
    }
}

#if os(macOS)
/// Local presentation only. The peer still receives the existing Stop reason; native property
/// selectors, status codes and arbitrary error descriptions never become public diagnostics.
public enum AudioPlaybackOutputIssue: String, Equatable, Sendable {
    case endpointUnavailable = "output.endpoint_unavailable"
    case formatMismatch = "output.format_mismatch"
    case mixingRequired = "output.mixing_required"
    case unsupportedLayout = "output.unsupported_layout"
    case unsupportedTopology = "output.unsupported_topology"
    case processingActive = "output.processing_active"
    case deviceBusy = "output.device_busy"
    case variableBufferSize = "output.variable_buffer_size"
    case propertyUnavailable = "output.property_unavailable"

    init?(error: Error) {
        guard let native = error as? CoreAudioExactPcmError else { return nil }
        switch native {
        case .invalidEndpoint, .endpointUnavailable: self = .endpointUnavailable
        case .formatMismatch: self = .formatMismatch
        case .mixableVirtualFormat: self = .mixingRequired
        case .unsupportedLayout: self = .unsupportedLayout
        case .unsupportedTopology: self = .unsupportedTopology
        case .gainOrMuteActive: self = .processingActive
        case .deviceBusy: self = .deviceBusy
        case .variableBufferSize: self = .variableBufferSize
        case .malformedProperty, .propertyFailure: self = .propertyUnavailable
        }
    }
}
#endif
