import Foundation

@preconcurrency import WebRTC

extension WebRTCSession {
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

    /// Reorders the native-screen video m-line so a Constrained-Baseline H264 payload
    /// (`profile-level-id` starting `42`) is selected before a High one (`640c`).
    ///
    /// The macOS-host WebRTC VideoToolbox encoder will not bring up Constrained-High,
    /// so if the negotiated SDP lists `640c1f` first the encoder stays at
    /// framesEncoded=0. This makes Baseline the first/preferred payload type while
    /// keeping the High payload in the set (we never delete payloads — that would
    /// risk breaking the offer/answer payload contract). Only the m-line payload
    /// order changes; every `a=rtpmap`/`a=fmtp`/`a=rtcp-fb` attribute line is left
    /// byte-identical (their order within a section is not significant per RFC 4566).
    /// If both profiles are not present, or only one H264 entry exists, the SDP is
    /// returned unchanged.
    static func sdpWithNativeScreenH264BaselineFirst(_ sdp: String) -> String {
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

        let rewrittenSections = sections.map { sdpSectionWithNativeScreenH264BaselineFirst($0) }
        let renderedLines = prefix + rewrittenSections.flatMap { $0 }
        let rendered = renderedLines.joined(separator: newline)
        return hasTrailingNewline ? rendered + newline : rendered
    }

    private static func sdpSectionWithNativeScreenH264BaselineFirst(_ section: [String]) -> [String] {
        guard let header = section.first, header.hasPrefix("m=video ") else { return section }

        // Map payload -> H264 profile rank from a=rtpmap (H264) + a=fmtp (profile-level-id).
        var isH264Payload = Set<String>()
        for line in section {
            guard let parsed = sdpAttributePayloadAndValue(line, prefix: "a=rtpmap:") else { continue }
            let codecName = parsed.value
                .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            if codecName == "h264" || codecName == "avc" {
                isH264Payload.insert(parsed.payload)
            }
        }
        guard !isH264Payload.isEmpty else { return section }

        var profileRankByPayload: [String: Int] = [:]
        for line in section {
            guard let parsed = sdpAttributePayloadAndValue(line, prefix: "a=fmtp:"),
                  isH264Payload.contains(parsed.payload) else { continue }
            let profileLevelID = h264ProfileLevelIDValue(fromFmtp: parsed.value)
            profileRankByPayload[parsed.payload] = WebRTCNativeScreenVideoValuePolicy
                .h264ProfilePreferenceRank(profileLevelID: profileLevelID)
        }

        // Only reorder when BOTH a Baseline (rank 0, profile-idc 0x42) and a
        // High (rank 2, profile-idc 0x64) H264 payload are present.
        let ranks = Set(profileRankByPayload.values)
        guard ranks.contains(0), ranks.contains(2) else { return section }

        // Parse the m= header: "m=video <port> <proto> <pt1> <pt2> ...".
        let headerParts = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard headerParts.count > 3 else { return section }
        let headerLead = headerParts.prefix(3)
        let payloadOrder = Array(headerParts.dropFirst(3))

        // Stable sort: H264 payloads by profile rank (Baseline first), everything
        // else keeps original position. Non-H264 and unranked H264 payloads keep
        // their relative order; only High vs Baseline H264 are reordered.
        let indexed = payloadOrder.enumerated()
        let reordered = indexed.sorted { lhs, rhs in
            let lhsRank = profileRankByPayload[lhs.element]
            let rhsRank = profileRankByPayload[rhs.element]
            // Only impose ordering between two ranked H264 payloads.
            if let lhsRank, let rhsRank, lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        guard reordered != payloadOrder else { return section }
        let newHeader = (headerLead + reordered).joined(separator: " ")
        var newSection = section
        newSection[0] = newHeader
        return newSection
    }

    /// Returns the `profile-level-id` of the first H264 payload listed on the video
    /// m-line (i.e. the selected/preferred codec), or `nil` if there is no H264 video
    /// payload. Diagnostic helper for confirming the negotiated profile on-device.
    static func selectedH264ProfileLevelID(fromVideoMLineOf sdp: String) -> String? {
        let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]?
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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

        guard let videoSection = sections.first(where: { $0.first?.hasPrefix("m=video ") == true }),
              let header = videoSection.first else { return nil }

        var isH264Payload = Set<String>()
        var fmtpByPayload: [String: String] = [:]
        for line in videoSection {
            if let rtpmap = sdpAttributePayloadAndValue(line, prefix: "a=rtpmap:") {
                let codecName = rtpmap.value
                    .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
                if codecName == "h264" || codecName == "avc" {
                    isH264Payload.insert(rtpmap.payload)
                }
            } else if let fmtp = sdpAttributePayloadAndValue(line, prefix: "a=fmtp:") {
                fmtpByPayload[fmtp.payload] = fmtp.value
            }
        }
        guard !isH264Payload.isEmpty else { return nil }

        let headerParts = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard headerParts.count > 3 else { return nil }
        for payload in headerParts.dropFirst(3) where isH264Payload.contains(payload) {
            if let fmtp = fmtpByPayload[payload],
               let profileLevelID = h264ProfileLevelIDValue(fromFmtp: fmtp) {
                return profileLevelID
            }
        }
        return nil
    }

    private static func h264ProfileLevelIDValue(fromFmtp fmtp: String) -> String? {
        for entry in fmtp.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            guard key == "profile-level-id",
                  let value = parts.dropFirst().first else { continue }
            return String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
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

    static func h264FmtpParametersWithNativeScreenLevelSupport(
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

    static func h264ProfileLevelID(
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
        let codecParameters: [String]
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
            var fmtpByPayload: [String: String] = [:]
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
                } else if line.hasPrefix("a=fmtp:") {
                    let fmtp = String(line.dropFirst(7))
                    let parts = fmtp.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard let payload = parts.first else { continue }
                    fmtpByPayload[String(payload)] = parts.dropFirst().first.map(String.init) ?? ""
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
            let codecParameters = payloadTypes.compactMap { payload -> String? in
                guard let codec = rtpmapByPayload[payload],
                      WebRTCNativeScreenVideoValuePolicy.codecIsHardwarePreferred(codec),
                      let fmtp = fmtpByPayload[payload] else { return nil }
                let codecName = codec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? codec
                let compactFmtp = Self.conciseSDPFmtpParameters(fmtp)
                return "\(payload):\(codecName)(\(compactFmtp.isEmpty ? "-" : compactFmtp))"
            }
            summaries.append(
                SDPMediaSummary(
                    kind: String(media),
                    port: port,
                    mid: mid,
                    direction: direction,
                    codecs: codecs,
                    codecParameters: codecParameters,
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
        let parameterList = summary.codecParameters.prefix(8).joined(separator: ",")
        return "kind=\(summary.kind) mid=\(summary.mid) port=\(summary.port) rejected=\(summary.rejected) direction=\(summary.direction) codecs=\(codecList.isEmpty ? "-" : codecList) fmtp=\(parameterList.isEmpty ? "-" : parameterList) msid=\(summary.hasMSID) ssrc=\(summary.hasSSRC)"
    }

    static func conciseSDPFmtpParameters(_ fmtp: String) -> String {
        let prioritizedKeys = [
            "profile-level-id",
            "level-asymmetry-allowed",
            "packetization-mode",
            "max-fs",
            "max-mbps",
            "x-google-start-bitrate",
            "x-google-max-bitrate",
            "x-google-min-bitrate"
        ]
        let entries = fmtp
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var valueByKey: [String: String] = [:]
        var originalEntryByKey: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            guard !key.isEmpty else { continue }
            if let value = parts.dropFirst().first {
                valueByKey[key] = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                valueByKey[key] = ""
            }
            originalEntryByKey[key] = entry
        }

        var emittedKeys = Set<String>()
        var compact: [String] = []
        for key in prioritizedKeys {
            guard let value = valueByKey[key] else { continue }
            emittedKeys.insert(key)
            compact.append(value.isEmpty ? key : "\(key)=\(value)")
        }
        let extras = entries.compactMap { entry -> (key: String, entry: String)? in
            let key = entry
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            guard !key.isEmpty, !emittedKeys.contains(key) else { return nil }
            return (key, originalEntryByKey[key] ?? entry)
        }
        for extra in extras.prefix(max(0, 8 - compact.count)) {
            emittedKeys.insert(extra.key)
            compact.append(extra.entry)
        }
        return compact.joined(separator: ";")
    }
}
