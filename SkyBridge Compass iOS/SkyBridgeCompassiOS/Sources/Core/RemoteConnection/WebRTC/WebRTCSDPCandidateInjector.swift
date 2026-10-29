import Foundation

enum WebRTCSDPCandidateInjector {
    static func injectLocalICECandidates(
        _ candidates: [WebRTCSignalingEnvelope.Payload],
        into sdp: String
    ) -> String {
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        let normalizedLines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]? = nil

        for line in normalizedLines {
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
        guard !sections.isEmpty else { return sdp }

        for payload in candidates {
            guard let candidateLine = normalizedCandidateSDPLine(from: payload) else { continue }
            let targetIndex = targetMediaSectionIndex(for: payload, sections: sections) ?? 0
            guard sections.indices.contains(targetIndex) else { continue }
            insertSDPLine(candidateLine, into: &sections[targetIndex])
        }

        var flattened = prefix
        for section in sections {
            flattened.append(contentsOf: section)
        }

        var rendered = flattened.joined(separator: newline)
        if sdp.hasSuffix("\r\n") || sdp.hasSuffix("\n") {
            rendered.append(newline)
        }
        return rendered
    }

    private static func normalizedCandidateSDPLine(from payload: WebRTCSignalingEnvelope.Payload) -> String? {
        guard let raw = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("a=") {
            return raw
        }
        if raw.hasPrefix("candidate:") {
            return "a=\(raw)"
        }
        return raw
    }

    private static func targetMediaSectionIndex(
        for payload: WebRTCSignalingEnvelope.Payload,
        sections: [[String]]
    ) -> Int? {
        if let index = payload.sdpMLineIndex, index >= 0, Int(index) < sections.count {
            return Int(index)
        }
        if let mid = payload.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mid.isEmpty,
           let match = sections.firstIndex(where: { section in
               section.contains(where: { $0 == "a=mid:\(mid)" })
           }) {
            return match
        }
        return sections.isEmpty ? nil : max(0, sections.count - 1)
    }

    private static func insertSDPLine(_ line: String, into section: inout [String]) {
        guard !section.contains(line) else { return }
        if let insertionIndex = section.firstIndex(of: "a=end-of-candidates") {
            section.insert(line, at: insertionIndex)
        } else {
            section.append(line)
        }
    }
}
