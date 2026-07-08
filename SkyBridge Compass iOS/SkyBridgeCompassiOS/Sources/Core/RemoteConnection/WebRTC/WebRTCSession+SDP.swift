import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@available(iOS 17.0, *)
extension WebRTCSession {
    private static let maxRemoteSDPBytes = 512 * 1024
    private static let maxRemoteSDPLines = 4_096
    private static let maxRemoteSDPLineBytes = 4_096
    private static let maxRemoteSDPMediaSections = 16
    private static let maxRemoteSDPCandidates = 256
    private static let maxRemoteICECandidateBytes = 4_096
    private static let maxRemoteICEMidBytes = 128

    struct ValidatedRemoteICECandidate: Equatable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int32
    }

    struct ValidatedRemoteSDPMediaSection: Equatable, Sendable {
        let index: Int32
        let mid: String
    }

    struct ValidatedRemoteSessionDescription: Equatable, Sendable {
        let mediaSections: [ValidatedRemoteSDPMediaSection]

        func validate(candidate: ValidatedRemoteICECandidate) throws {
            let index = Int(candidate.sdpMLineIndex)
            guard mediaSections.indices.contains(index) else {
                throw WebRTCError.sdpFailed("remote ICE candidate m-line index is not present in accepted remote SDP")
            }
            guard let mid = candidate.sdpMid else { return }
            let section = mediaSections[index]
            guard section.mid == mid else {
                throw WebRTCError.sdpFailed("remote ICE candidate sdpMid does not match accepted remote SDP m-line")
            }
        }
    }

    @discardableResult
    nonisolated static func validateRemoteSessionDescription(
        _ sdp: String,
        expectedKind: String
    ) throws -> ValidatedRemoteSessionDescription {
        let kind = expectedKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "remote"
            : expectedKind
        let byteCount = sdp.utf8.count
        guard byteCount > 0 else {
            throw WebRTCError.sdpFailed("\(kind) SDP is empty")
        }
        guard byteCount <= maxRemoteSDPBytes else {
            throw WebRTCError.sdpFailed("\(kind) SDP exceeds \(maxRemoteSDPBytes) bytes")
        }
        guard !sdp.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WebRTCError.sdpFailed("\(kind) SDP contains NUL")
        }

        let lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw WebRTCError.sdpFailed("\(kind) SDP has no lines")
        }
        guard lines.count <= maxRemoteSDPLines else {
            throw WebRTCError.sdpFailed("\(kind) SDP exceeds \(maxRemoteSDPLines) lines")
        }
        guard lines.first == "v=0" else {
            throw WebRTCError.sdpFailed("\(kind) SDP must start with v=0")
        }
        guard lines.contains(where: { $0.hasPrefix("o=") }),
              lines.contains(where: { $0.hasPrefix("s=") }),
              lines.contains(where: { $0.hasPrefix("t=") }) else {
            throw WebRTCError.sdpFailed("\(kind) SDP is missing required session fields")
        }

        var mediaSectionCount = 0
        var candidateCount = 0
        var currentSectionMid: String?
        var mediaSections: [ValidatedRemoteSDPMediaSection] = []
        var seenMids = Set<String>()
        var hasFingerprint = false
        var hasICEUfrag = false
        var hasICEPwd = false

        func finishMediaSection() throws {
            guard mediaSectionCount > 0 else { return }
            guard let currentSectionMid else {
                throw WebRTCError.sdpFailed("\(kind) SDP media section is missing a=mid")
            }
            mediaSections.append(
                ValidatedRemoteSDPMediaSection(
                    index: Int32(mediaSections.count),
                    mid: currentSectionMid
                )
            )
        }

        for line in lines {
            try validateRemoteSDPLine(line, kind: kind)
            if line.hasPrefix("m=") {
                try finishMediaSection()
                mediaSectionCount += 1
                guard mediaSectionCount <= maxRemoteSDPMediaSections else {
                    throw WebRTCError.sdpFailed("\(kind) SDP exceeds \(maxRemoteSDPMediaSections) media sections")
                }
                currentSectionMid = nil
                try validateRemoteSDPMediaLine(line, kind: kind)
                continue
            }
            if line.hasPrefix("a=fingerprint:") {
                hasFingerprint = true
            } else if line.hasPrefix("a=ice-ufrag:") {
                hasICEUfrag = true
            } else if line.hasPrefix("a=ice-pwd:") {
                hasICEPwd = true
            }
            if line.hasPrefix("a=mid:") {
                guard mediaSectionCount > 0 else {
                    throw WebRTCError.sdpFailed("\(kind) SDP has session-level a=mid")
                }
                let mid = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try validatedRemoteICEMid(mid)
                guard currentSectionMid == nil else {
                    throw WebRTCError.sdpFailed("\(kind) SDP media section has multiple a=mid lines")
                }
                guard seenMids.insert(mid).inserted else {
                    throw WebRTCError.sdpFailed("\(kind) SDP has duplicate a=mid")
                }
                currentSectionMid = mid
                continue
            }
            if line.hasPrefix("a=candidate:") {
                guard mediaSectionCount > 0 else {
                    throw WebRTCError.sdpFailed("\(kind) SDP has session-level ICE candidate")
                }
                candidateCount += 1
                guard candidateCount <= maxRemoteSDPCandidates else {
                    throw WebRTCError.sdpFailed("\(kind) SDP exceeds \(maxRemoteSDPCandidates) ICE candidates")
                }
                _ = try normalizedRemoteICECandidateSDP(line, context: "\(kind) SDP candidate")
            }
        }

        guard mediaSectionCount > 0 else {
            throw WebRTCError.sdpFailed("\(kind) SDP has no media sections")
        }
        guard hasFingerprint else {
            throw WebRTCError.sdpFailed("\(kind) SDP is missing DTLS fingerprint")
        }
        guard hasICEUfrag, hasICEPwd else {
            throw WebRTCError.sdpFailed("\(kind) SDP is missing ICE credentials")
        }
        try finishMediaSection()
        return ValidatedRemoteSessionDescription(mediaSections: mediaSections)
    }

    nonisolated static func validatedRemoteICECandidate(
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32?,
        acceptedRemoteDescription: ValidatedRemoteSessionDescription? = nil
    ) throws -> ValidatedRemoteICECandidate {
        let normalizedCandidate = try normalizedRemoteICECandidateSDP(
            candidate,
            context: "remote ICE candidate"
        )
        let normalizedMid = try validatedRemoteICEMid(sdpMid)
        guard normalizedMid != nil || sdpMLineIndex != nil else {
            throw WebRTCError.sdpFailed("remote ICE candidate is missing sdpMid and sdpMLineIndex")
        }
        let normalizedIndex = try validatedRemoteICEMLineIndex(sdpMLineIndex)
        let validated = ValidatedRemoteICECandidate(
            candidate: normalizedCandidate,
            sdpMid: normalizedMid,
            sdpMLineIndex: normalizedIndex
        )
        try acceptedRemoteDescription?.validate(candidate: validated)
        return validated
    }

    private nonisolated static func validateRemoteSDPLine(_ line: String, kind: String) throws {
        guard line.utf8.count <= maxRemoteSDPLineBytes else {
            throw WebRTCError.sdpFailed("\(kind) SDP line exceeds \(maxRemoteSDPLineBytes) bytes")
        }
        guard line.count >= 2,
              line[line.index(after: line.startIndex)] == "=" else {
            throw WebRTCError.sdpFailed("\(kind) SDP contains malformed line")
        }
        guard line.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw WebRTCError.sdpFailed("\(kind) SDP contains control characters")
        }
    }

    private nonisolated static func validateRemoteSDPMediaLine(_ line: String, kind: String) throws {
        let body = String(line.dropFirst(2))
        let parts = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else {
            throw WebRTCError.sdpFailed("\(kind) SDP media line is incomplete")
        }
        guard let port = Int(parts[1]), (0...65_535).contains(port) else {
            throw WebRTCError.sdpFailed("\(kind) SDP media line has invalid port")
        }
        guard !parts[0].isEmpty, !parts[2].isEmpty else {
            throw WebRTCError.sdpFailed("\(kind) SDP media line has empty media/protocol")
        }
    }

    private nonisolated static func normalizedRemoteICECandidateSDP(
        _ candidate: String,
        context: String
    ) throws -> String {
        let raw = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw WebRTCError.sdpFailed("\(context) is empty")
        }
        guard raw.utf8.count <= maxRemoteICECandidateBytes else {
            throw WebRTCError.sdpFailed("\(context) exceeds \(maxRemoteICECandidateBytes) bytes")
        }
        guard !raw.contains(where: { $0 == "\n" || $0 == "\r" }),
              raw.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw WebRTCError.sdpFailed("\(context) contains control characters")
        }

        let normalized = raw.hasPrefix("a=") ? String(raw.dropFirst(2)) : raw
        guard normalized.hasPrefix("candidate:") else {
            throw WebRTCError.sdpFailed("\(context) must start with candidate:")
        }

        let fields = normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 8 else {
            throw WebRTCError.sdpFailed("\(context) is incomplete")
        }
        let foundation = String(fields[0].dropFirst("candidate:".count))
        guard !foundation.isEmpty else {
            throw WebRTCError.sdpFailed("\(context) has empty foundation")
        }
        guard let component = Int(fields[1]), component > 0 else {
            throw WebRTCError.sdpFailed("\(context) has invalid component")
        }
        let transport = fields[2].lowercased()
        guard transport == "udp" || transport == "tcp" else {
            throw WebRTCError.sdpFailed("\(context) has unsupported transport")
        }
        guard UInt64(fields[3]) != nil else {
            throw WebRTCError.sdpFailed("\(context) has invalid priority")
        }
        guard isValidICEAddressToken(fields[4]) else {
            throw WebRTCError.sdpFailed("\(context) has invalid address")
        }
        guard let port = Int(fields[5]), (1...65_535).contains(port) else {
            throw WebRTCError.sdpFailed("\(context) has invalid port")
        }
        guard fields[6].lowercased() == "typ" else {
            throw WebRTCError.sdpFailed("\(context) is missing typ")
        }
        let candidateType = fields[7].lowercased()
        guard ["host", "srflx", "prflx", "relay"].contains(candidateType) else {
            throw WebRTCError.sdpFailed("\(context) has unsupported type")
        }
        return normalized
    }

    private nonisolated static func validatedRemoteICEMid(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let mid = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else {
            throw WebRTCError.sdpFailed("remote ICE candidate has empty sdpMid")
        }
        guard mid.utf8.count <= maxRemoteICEMidBytes else {
            throw WebRTCError.sdpFailed("remote ICE candidate sdpMid exceeds \(maxRemoteICEMidBytes) bytes")
        }
        guard mid.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw WebRTCError.sdpFailed("remote ICE candidate sdpMid is not an SDP token")
        }
        return mid
    }

    private nonisolated static func validatedRemoteICEMLineIndex(
        _ value: Int32?
    ) throws -> Int32 {
        guard let value else {
            throw WebRTCError.sdpFailed("remote ICE candidate is missing sdpMLineIndex")
        }
        guard value >= 0 else {
            throw WebRTCError.sdpFailed("remote ICE candidate has negative sdpMLineIndex")
        }
        return value
    }

    private nonisolated static func isValidICEAddressToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    static func sdpWithNativeScreenH264LevelSupport(
        _ sdp: String,
        requiredLevelHex: String,
        maxFS: Int,
        maxMBPS: Int
    ) -> String {
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailingNewline = sdp.hasSuffix("\r\n") || sdp.hasSuffix("\n")
        var lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }

        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]?
        for line in lines {
            if line.hasPrefix("m=") {
                if let currentSection {
                    sections.append(currentSection)
                }
                currentSection = [line]
            } else if currentSection != nil {
                currentSection?.append(line)
            } else {
                prefix.append(line)
            }
        }
        if let currentSection {
            sections.append(currentSection)
        }

        let rewrittenSections = sections.map {
            sdpSectionWithNativeScreenH264LevelSupport(
                $0,
                requiredLevelHex: requiredLevelHex,
                maxFS: maxFS,
                maxMBPS: maxMBPS
            )
        }
        let renderedLines = prefix + rewrittenSections.flatMap { $0 }
        let rendered = renderedLines.joined(separator: newline)
        return hasTrailingNewline ? rendered + newline : rendered
    }

    private static func sdpSectionWithNativeScreenH264LevelSupport(
        _ section: [String],
        requiredLevelHex: String,
        maxFS: Int,
        maxMBPS: Int
    ) -> [String] {
        guard section.first?.hasPrefix("m=video ") == true else { return section }
        let h264Payloads = Set(
            section.compactMap { line -> String? in
                guard let parsed = sdpAttributePayloadAndValue(line, prefix: "a=rtpmap:") else {
                    return nil
                }
                let codecName = parsed.value
                    .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
                guard codecName == "h264" || codecName == "avc" else { return nil }
                return parsed.payload
            }
        )
        guard !h264Payloads.isEmpty else { return section }

        return section.map { line in
            guard let parsed = sdpAttributePayloadAndValue(line, prefix: "a=fmtp:"),
                  h264Payloads.contains(parsed.payload) else { return line }
            let updated = h264FmtpParametersWithNativeScreenLevelSupport(
                parsed.value,
                requiredLevelHex: requiredLevelHex,
                maxFS: maxFS,
                maxMBPS: maxMBPS
            )
            return "a=fmtp:\(parsed.payload) \(updated)"
        }
    }

    private static func sdpAttributePayloadAndValue(
        _ line: String,
        prefix: String
    ) -> (payload: String, value: String)? {
        guard line.hasPrefix(prefix) else { return nil }
        let body = String(line.dropFirst(prefix.count))
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let payload = parts.first else { return nil }
        return (
            String(payload).trimmingCharacters(in: .whitespacesAndNewlines),
            parts.dropFirst().first.map(String.init) ?? ""
        )
    }

    private static func h264FmtpParametersWithNativeScreenLevelSupport(
        _ fmtp: String,
        requiredLevelHex: String,
        maxFS: Int,
        maxMBPS: Int
    ) -> String {
        var entries = fmtp
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seenKeys = Set<String>()

        for index in entries.indices {
            let parts = entries[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            let value = parts.dropFirst().first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !key.isEmpty else { continue }
            seenKeys.insert(key)
            switch key {
            case "profile-level-id":
                entries[index] = "profile-level-id=\(h264ProfileLevelID(value, upgradedToAtLeast: requiredLevelHex))"
            case "level-asymmetry-allowed":
                entries[index] = "level-asymmetry-allowed=1"
            case "packetization-mode":
                entries[index] = value.isEmpty ? "packetization-mode=1" : "packetization-mode=\(value)"
            case "max-fs":
                entries[index] = "max-fs=\(maxFmtpInteger(value, minimum: maxFS))"
            case "max-mbps":
                entries[index] = "max-mbps=\(maxFmtpInteger(value, minimum: maxMBPS))"
            default:
                break
            }
        }

        if !seenKeys.contains("level-asymmetry-allowed") {
            entries.append("level-asymmetry-allowed=1")
        }
        if !seenKeys.contains("packetization-mode") {
            entries.append("packetization-mode=1")
        }
        if !seenKeys.contains("max-fs") {
            entries.append("max-fs=\(maxFS)")
        }
        if !seenKeys.contains("max-mbps") {
            entries.append("max-mbps=\(maxMBPS)")
        }
        return entries.joined(separator: ";")
    }

    private static func h264ProfileLevelID(
        _ profileLevelID: String,
        upgradedToAtLeast requiredLevelHex: String
    ) -> String {
        let cleaned = profileLevelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let required = requiredLevelHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count == 6,
              required.count == 2,
              let currentLevel = Int(cleaned.suffix(2), radix: 16),
              let requiredLevel = Int(required, radix: 16) else {
            return cleaned.isEmpty ? profileLevelID : cleaned
        }
        guard currentLevel < requiredLevel else { return cleaned }
        return "\(cleaned.prefix(4))\(required)"
    }

    private static func maxFmtpInteger(_ value: String, minimum: Int) -> Int {
        guard let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return minimum
        }
        return max(parsed, minimum)
    }

    private struct SDPMediaSummary: Equatable {
        let kind: String
        let port: String
        let mid: String
        let direction: String
        let codecs: [String]
        let hasMSID: Bool
        let hasSSRC: Bool
        let rejected: Bool
    }

    private static func mediaSummaries(from sdp: String) -> [SDPMediaSummary] {
        let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        var summaries: [SDPMediaSummary] = []
        var current: [String] = []

        func flushCurrent() {
            guard let first = current.first,
                  first.hasPrefix("m=") else { return }
            let mediaParts = first.split(separator: " ", omittingEmptySubsequences: true)
            guard let media = mediaParts.first?.dropFirst(2),
                  !media.isEmpty else { return }
            let port = mediaParts.dropFirst().first.map(String.init) ?? "-"
            var payloadTypes: [String] = []
            if mediaParts.count > 3 {
                payloadTypes = mediaParts.dropFirst(3).map(String.init)
            }
            var mid = "-"
            var direction = "unspecified"
            var rtpmapByPayload: [String: String] = [:]
            var hasMSID = false
            var hasSSRC = false
            for line in current.dropFirst() {
                if line.hasPrefix("a=mid:") {
                    mid = String(line.dropFirst(6))
                } else if line == "a=sendrecv" || line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive" {
                    direction = String(line.dropFirst(2))
                } else if line.hasPrefix("a=rtpmap:") {
                    let rtpmap = String(line.dropFirst(9))
                    let parts = rtpmap.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if let payload = parts.first,
                       let codec = parts.dropFirst().first {
                        rtpmapByPayload[String(payload)] = String(codec)
                    }
                } else if line.hasPrefix("a=msid:") {
                    hasMSID = true
                } else if line.hasPrefix("a=ssrc:") {
                    hasSSRC = true
                }
            }
            let codecs = payloadTypes.compactMap { payload -> String? in
                guard let codec = rtpmapByPayload[payload] else { return nil }
                return "\(payload):\(codec)"
            }
            summaries.append(
                SDPMediaSummary(
                    kind: String(media),
                    port: port,
                    mid: mid,
                    direction: direction,
                    codecs: codecs,
                    hasMSID: hasMSID,
                    hasSSRC: hasSSRC,
                    rejected: port == "0"
                )
            )
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("m=") {
                flushCurrent()
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        flushCurrent()
        return summaries
    }

    static func videoSDPMediaSummary(
        from sdp: String
    ) -> (
        hasVideo: Bool,
        direction: String,
        description: String
    ) {
        let videoSummary = mediaSummaries(from: sdp).first { $0.kind == "video" }
        return (
            hasVideo: videoSummary != nil,
            direction: videoSummary?.direction ?? "unspecified",
            description: videoSummary.map(Self.conciseSDPMediaSummary) ?? "-"
        )
    }

    private static func conciseSDPMediaSummary(_ summary: SDPMediaSummary) -> String {
        let codecList = summary.codecs.prefix(8).joined(separator: ",")
        return "kind=\(summary.kind) mid=\(summary.mid) port=\(summary.port) rejected=\(summary.rejected) direction=\(summary.direction) codecs=\(codecList.isEmpty ? "-" : codecList) msid=\(summary.hasMSID) ssrc=\(summary.hasSSRC)"
    }

}
