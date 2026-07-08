import Foundation

enum CrossNetworkWebRTCTraceDescription {
    static func smokeTraceToken(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let allowed = sanitized.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
        return String(allowed.prefix(120))
    }

    static func describeEnvelope(_ envelope: WebRTCSignalingEnvelope) -> String {
        let payloadSummary: String
        switch envelope.type {
        case .offer, .answer:
            if let sdp = envelope.payload?.sdp {
                payloadSummary = describeSDPCandidates(sdp)
            } else {
                payloadSummary = "sdp=0"
            }
        case .iceCandidate:
            payloadSummary = "kind=\(describeCandidateKind(envelope.payload?.candidate))"
        case .join, .leave:
            payloadSummary = "payload=0"
        }
        return "session_ref=\(SkyBridgeTraceRedaction.stableReference(envelope.sessionId)) type=\(envelope.type.rawValue) from_ref=\(SkyBridgeTraceRedaction.stableReference(envelope.from)) to_ref=\(SkyBridgeTraceRedaction.stableReference(envelope.to)) auth=\(envelope.authToken == nil ? 0 : 1) \(payloadSummary)"
    }

    static func describeCandidateKind(_ candidate: String?) -> String {
        guard let candidate = candidate?.lowercased() else { return "unknown" }
        if candidate.contains(" typ relay") { return "relay" }
        if candidate.contains(" typ srflx") { return "srflx" }
        if candidate.contains(" typ prflx") { return "prflx" }
        if candidate.contains(" typ host") { return "host" }
        return "unknown"
    }

    static func describeSDPCandidates(_ sdp: String) -> String {
        var total = 0
        var host = 0
        var srflx = 0
        var relay = 0
        var prflx = 0
        var mediaSections = 0
        var hasVideo = false
        var videoDirection = "unspecified"
        var inVideoSection = false

        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                mediaSections += 1
                inVideoSection = line.hasPrefix("m=video ")
                if inVideoSection {
                    hasVideo = true
                    videoDirection = "unspecified"
                }
                continue
            }

            if inVideoSection, line.hasPrefix("a=") {
                if line == "a=sendrecv" {
                    videoDirection = "sendrecv"
                } else if line == "a=sendonly" {
                    videoDirection = "sendonly"
                } else if line == "a=recvonly" {
                    videoDirection = "recvonly"
                } else if line == "a=inactive" {
                    videoDirection = "inactive"
                }
            }

            guard line.hasPrefix("a=candidate:") else { continue }
            total += 1
            let lower = line.lowercased()
            if lower.contains(" typ relay") {
                relay += 1
            } else if lower.contains(" typ srflx") {
                srflx += 1
            } else if lower.contains(" typ prflx") {
                prflx += 1
            } else if lower.contains(" typ host") {
                host += 1
            }
        }

        return "media=\(mediaSections) hasVideo=\(hasVideo) videoDir=\(videoDirection) candidates total=\(total) host=\(host) srflx=\(srflx) relay=\(relay) prflx=\(prflx)"
    }
}
