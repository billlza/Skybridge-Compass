import CoreGraphics
import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
@available(iOS 17.0, *)
extension WebRTCSession {
    struct RemoteInboundVideoStatsSample: Equatable {
        let type: String
        let values: [String: NSObject]
    }

    struct RemoteInboundVideoStatsSnapshot: Equatable {
        let statType: String
        let packetsReceived: Int?
        let bytesReceived: Int?
        let framesReceived: Int?
        let framesDecoded: Int?
        let frameWidth: Int?
        let frameHeight: Int?

        var size: CGSize? {
            guard let frameWidth, let frameHeight,
                  frameWidth > 0, frameHeight > 0 else {
                return nil
            }
            return CGSize(width: frameWidth, height: frameHeight)
        }

        var hasPacketEvidence: Bool {
            (framesDecoded ?? 0) > 0
                || (framesReceived ?? 0) > 0
                || (bytesReceived ?? 0) > 0
                || (packetsReceived ?? 0) > 0
        }

        var hasFrameEvidence: Bool {
            guard size != nil else { return false }
            return (framesDecoded ?? 0) > 0 || (framesReceived ?? 0) > 0
        }

        var summary: String {
            [
                "type=\(statType)",
                "packets=\(packetsReceived.map(String.init) ?? "-")",
                "bytes=\(bytesReceived.map(String.init) ?? "-")",
                "framesReceived=\(framesReceived.map(String.init) ?? "-")",
                "framesDecoded=\(framesDecoded.map(String.init) ?? "-")",
                "size=\(frameWidth.map(String.init) ?? "-")x\(frameHeight.map(String.init) ?? "-")"
            ].joined(separator: " ")
        }
    }

    struct RemoteInboundVideoStatsCandidate {
        let source: String
        let receiver: RTCRtpReceiver?
        let receiverTrackId: String
        let snapshot: RemoteInboundVideoStatsSnapshot

        var traceSource: String {
            if receiver != nil {
                return "receiver-specific"
            }
            return source
        }

        var summary: String {
            "source=\(traceSource) receiverTrackId=\(receiverTrackId.isEmpty ? "-" : receiverTrackId) \(snapshot.summary)"
        }
    }

    static func remoteInboundVideoStatsSnapshot(
        from samples: [RemoteInboundVideoStatsSample]
    ) -> RemoteInboundVideoStatsSnapshot? {
        let videoSamples = samples.filter { sample in
            let sampleType = sample.type.lowercased()
            if sampleType == "data-channel"
                || sampleType == "candidate-pair"
                || sampleType == "transport"
                || sampleType == "local-candidate"
                || sampleType == "remote-candidate" {
                return false
            }
            let kind = stringValue(sample.values, key: "kind")?.lowercased()
                ?? stringValue(sample.values, key: "mediaType")?.lowercased()
            if let kind, kind != "video" {
                return false
            }
            return kind == "video"
                || sampleType == "inbound-rtp"
                || sampleType == "track"
                || sampleType == "receiver"
                || sampleType == "media-source"
                || sampleType == "media-playout"
                || sample.values["frameWidth"] != nil
                || sample.values["frameHeight"] != nil
                || sample.values["framesDecoded"] != nil
                || sample.values["framesReceived"] != nil
        }

        guard !videoSamples.isEmpty else { return nil }

        let primaryType = videoSamples
            .max { lhs, rhs in samplePriority(lhs) < samplePriority(rhs) }?
            .type ?? "aggregate"

        var packetsReceived: Int?
        var bytesReceived: Int?
        var framesReceived: Int?
        var framesDecoded: Int?
        var frameWidth: Int?
        var frameHeight: Int?

        for sample in videoSamples {
            packetsReceived = mergeMetric(
                packetsReceived,
                intValue(sample.values, key: "packetsReceived")
            )
            bytesReceived = mergeMetric(
                bytesReceived,
                intValue(sample.values, key: "bytesReceived")
            )
            framesReceived = mergeMetric(
                framesReceived,
                intValue(sample.values, key: "framesReceived")
            )
            framesDecoded = mergeMetric(
                framesDecoded,
                intValue(sample.values, key: "framesDecoded")
            )
            frameWidth = mergeMetric(
                frameWidth,
                intValue(sample.values, key: "frameWidth")
                    ?? intValue(sample.values, key: "width")
            )
            frameHeight = mergeMetric(
                frameHeight,
                intValue(sample.values, key: "frameHeight")
                    ?? intValue(sample.values, key: "height")
            )
        }

        return RemoteInboundVideoStatsSnapshot(
            statType: primaryType,
            packetsReceived: packetsReceived,
            bytesReceived: bytesReceived,
            framesReceived: framesReceived,
            framesDecoded: framesDecoded,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    private static func samplePriority(_ sample: RemoteInboundVideoStatsSample) -> Int {
        var score = 0
        switch sample.type.lowercased() {
        case "inbound-rtp":
            score += 500
        case "track":
            score += 300
        case "media-playout":
            score += 200
        default:
            break
        }
        if intValue(sample.values, key: "framesDecoded") != nil { score += 100 }
        if intValue(sample.values, key: "frameWidth") != nil || intValue(sample.values, key: "width") != nil {
            score += 50
        }
        if intValue(sample.values, key: "frameHeight") != nil || intValue(sample.values, key: "height") != nil {
            score += 50
        }
        return score
    }

    static func snapshotPriority(_ snapshot: RemoteInboundVideoStatsSnapshot) -> Int {
        var score = 0
        if snapshot.hasFrameEvidence { score += 10_000 }
        score += min(snapshot.framesDecoded ?? 0, 5_000)
        score += min(snapshot.framesReceived ?? 0, 2_500)
        score += min((snapshot.bytesReceived ?? 0) / 1_024, 1_000)
        switch snapshot.statType.lowercased() {
        case "inbound-rtp":
            score += 200
        case "track":
            score += 150
        case "media-playout":
            score += 100
        default:
            break
        }
        return score
    }

    private static func mergeMetric(_ current: Int?, _ candidate: Int?) -> Int? {
        switch (current, candidate) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case (nil, let rhs?):
            return rhs
        default:
            return current
        }
    }

    private static func intValue(_ values: [String: NSObject], key: String) -> Int? {
        guard let raw = values[key] else { return nil }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let string = raw as? NSString {
            return Int(string.doubleValue.rounded())
        }
        return nil
    }

    private static func stringValue(_ values: [String: NSObject], key: String) -> String? {
        guard let raw = values[key] else { return nil }
        if let string = raw as? NSString {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return String(describing: raw)
    }
}
#endif
