import Foundation

struct SDPParserLimits: Sendable, Equatable {
    let maximumBytes: Int
    let maximumLines: Int
    let maximumLineBytes: Int
    let maximumMediaSections: Int
    let maximumAttributesPerSection: Int
    let maximumParameterSetBytes: Int
    let maximumParameterSets: Int

    init(
        maximumBytes: Int = 256 * 1_024,
        maximumLines: Int = 2_048,
        maximumLineBytes: Int = 4_096,
        maximumMediaSections: Int = 32,
        maximumAttributesPerSection: Int = 512,
        maximumParameterSetBytes: Int = 64 * 1_024,
        maximumParameterSets: Int = 32
    ) {
        precondition(maximumBytes > 0)
        precondition(maximumLines > 0)
        precondition(maximumLineBytes > 0)
        precondition(maximumMediaSections > 0)
        precondition(maximumAttributesPerSection > 0)
        precondition(maximumParameterSetBytes > 0)
        precondition(maximumParameterSets > 0)
        self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines
        self.maximumLineBytes = maximumLineBytes
        self.maximumMediaSections = maximumMediaSections
        self.maximumAttributesPerSection = maximumAttributesPerSection
        self.maximumParameterSetBytes = maximumParameterSetBytes
        self.maximumParameterSets = maximumParameterSets
    }
}

struct RTSPH264MediaDescription: Sendable, Equatable {
    let payloadType: UInt8
    let controlURL: URL
    let playURL: URL
    let packetizationMode: UInt8
    let sequenceParameterSets: [Data]
    let pictureParameterSets: [Data]

    init(
        payloadType: UInt8,
        controlURL: URL,
        playURL: URL,
        packetizationMode: UInt8,
        sequenceParameterSets: [Data],
        pictureParameterSets: [Data]
    ) {
        self.payloadType = payloadType
        self.controlURL = controlURL
        self.playURL = playURL
        self.packetizationMode = packetizationMode
        self.sequenceParameterSets = sequenceParameterSets
        self.pictureParameterSets = pictureParameterSets
    }
}

struct SDPParser: Sendable {
    private let limits: SDPParserLimits

    init(limits: SDPParserLimits = SDPParserLimits()) {
        self.limits = limits
    }

    func parseH264Media(
        _ data: Data,
        baseURL: URL,
        endpoint: RTSPEndpoint
    ) throws -> RTSPH264MediaDescription {
        guard data.count <= limits.maximumBytes else {
            throw SkyBridgeCameraError.sdpTooLarge(limit: limits.maximumBytes)
        }
        guard data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || ($0 >= 32 && $0 <= 126) }),
              let text = String(data: data, encoding: .ascii)
        else {
            throw SkyBridgeCameraError.malformedSDP(
                "the document contains non-ASCII or disallowed control characters"
            )
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.utf8.allSatisfy({ $0 != 13 }) else {
            throw SkyBridgeCameraError.malformedSDP("a bare carriage return is not accepted")
        }
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            throw SkyBridgeCameraError.malformedSDP("the document is empty")
        }
        guard lines.count <= limits.maximumLines else {
            throw SkyBridgeCameraError.malformedSDP(
                "the document exceeds \(limits.maximumLines) lines"
            )
        }

        var sessionControl: String?
        var sessionDirection = "sendrecv"
        var hasSessionDirection = false
        var mediaSections: [MediaSection] = []
        var currentMediaIndex: Int?

        for line in lines {
            guard !line.isEmpty, line.utf8.count <= limits.maximumLineBytes else {
                throw SkyBridgeCameraError.malformedSDP(
                    "a line is empty or exceeds \(limits.maximumLineBytes) bytes"
                )
            }
            guard line.count >= 2, line[line.index(after: line.startIndex)] == "=" else {
                throw SkyBridgeCameraError.malformedSDP("a line is not in type=value form")
            }
            let type = line[line.startIndex]
            let value = line.dropFirst(2)
            guard !value.isEmpty else {
                throw SkyBridgeCameraError.malformedSDP("an SDP field has an empty value")
            }

            switch type {
            case "m":
                guard mediaSections.count < limits.maximumMediaSections else {
                    throw SkyBridgeCameraError.malformedSDP(
                        "the document exceeds \(limits.maximumMediaSections) media sections"
                    )
                }
                mediaSections.append(try parseMediaLine(
                    value,
                    inheritedDirection: sessionDirection
                ))
                currentMediaIndex = mediaSections.count - 1

            case "a":
                if let currentMediaIndex {
                    guard mediaSections[currentMediaIndex].attributeCount <
                            limits.maximumAttributesPerSection
                    else {
                        throw SkyBridgeCameraError.malformedSDP(
                            "a media section has too many attributes"
                        )
                    }
                    mediaSections[currentMediaIndex].attributeCount += 1
                    try applyAttribute(value, to: &mediaSections[currentMediaIndex])
                } else if value.hasPrefix("control:") {
                    guard sessionControl == nil else {
                        throw SkyBridgeCameraError.malformedSDP(
                            "the session contains duplicate control attributes"
                        )
                    }
                    sessionControl = String(value.dropFirst("control:".count))
                } else if value == "inactive" || value == "recvonly" ||
                            value == "sendonly" || value == "sendrecv"
                {
                    guard !hasSessionDirection else {
                        throw SkyBridgeCameraError.malformedSDP(
                            "the session contains duplicate direction attributes"
                        )
                    }
                    sessionDirection = String(value)
                    hasSessionDirection = true
                }

            default:
                continue
            }
        }

        let playURL = try resolveSessionControl(
            sessionControl,
            baseURL: baseURL,
            endpoint: endpoint
        )

        for section in mediaSections where
            section.mediaType == "video" &&
            section.port != 0 &&
            section.direction != "inactive" &&
            section.direction != "recvonly"
        {
            for format in section.formats {
                guard let mapping = section.rtpMappings[format],
                      mapping.codec.caseInsensitiveCompare("H264") == .orderedSame,
                      mapping.clockRate == 90_000,
                      mapping.channels == nil
                else { continue }
                guard let control = section.control, !control.isEmpty else {
                    throw SkyBridgeCameraError.unsupportedMedia(
                        "the H.264 video track has no media control URI"
                    )
                }
                let controlURL = try resolveMediaControl(
                    control,
                    baseURL: baseURL,
                    endpoint: endpoint
                )
                let formatParameters = section.formatParameters[format] ?? [:]
                let packetizationMode = try parsePacketizationMode(formatParameters)
                let parameterSets = try parseParameterSets(formatParameters)
                return RTSPH264MediaDescription(
                    payloadType: format,
                    controlURL: controlURL,
                    playURL: playURL,
                    packetizationMode: packetizationMode,
                    sequenceParameterSets: parameterSets.sps,
                    pictureParameterSets: parameterSets.pps
                )
            }
        }

        throw SkyBridgeCameraError.unsupportedMedia(
            "no H.264/90000 video payload was advertised"
        )
    }

    private struct RTPMapping: Sendable {
        let codec: String
        let clockRate: Int
        let channels: Int?
    }

    private struct MediaSection: Sendable {
        let mediaType: String
        let port: Int
        let formats: [UInt8]
        var rtpMappings: [UInt8: RTPMapping] = [:]
        var formatParameters: [UInt8: [String: String]] = [:]
        var control: String?
        var direction = "sendrecv"
        var hasDirectionAttribute = false
        var attributeCount = 0
    }

    private func parseMediaLine(
        _ value: Substring,
        inheritedDirection: String
    ) throws -> MediaSection {
        let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4 else {
            throw SkyBridgeCameraError.malformedSDP("an m= line has fewer than four fields")
        }
        let mediaType = fields[0].lowercased()
        guard isSDPToken(mediaType) else {
            throw SkyBridgeCameraError.malformedSDP("the media type is invalid")
        }
        guard validPortField(fields[1]) else {
            throw SkyBridgeCameraError.malformedSDP("the media port is invalid")
        }
        let protocolName = fields[2].uppercased()
        guard protocolName == "RTP/AVP" || protocolName == "RTP/AVP/TCP" else {
            return MediaSection(
                mediaType: mediaType,
                port: portValue(fields[1]),
                formats: [],
                direction: inheritedDirection
            )
        }

        var formats: [UInt8] = []
        formats.reserveCapacity(fields.count - 3)
        for field in fields.dropFirst(3) {
            guard field.allSatisfy(\.isNumber), let payload = UInt8(field), payload <= 127 else {
                throw SkyBridgeCameraError.malformedSDP("an RTP payload type is invalid")
            }
            guard !formats.contains(payload) else {
                throw SkyBridgeCameraError.malformedSDP("an RTP payload type is duplicated")
            }
            formats.append(payload)
        }
        return MediaSection(
            mediaType: mediaType,
            port: portValue(fields[1]),
            formats: formats,
            direction: inheritedDirection
        )
    }

    private func applyAttribute(_ value: Substring, to section: inout MediaSection) throws {
        if value.hasPrefix("rtpmap:") {
            let remainder = value.dropFirst("rtpmap:".count)
            let fields = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2,
                  fields[0].allSatisfy(\.isNumber),
                  let payload = UInt8(fields[0]), payload <= 127,
                  section.formats.contains(payload)
            else {
                throw SkyBridgeCameraError.malformedSDP("an rtpmap attribute is invalid")
            }
            let encoding = fields[1].split(separator: "/", omittingEmptySubsequences: false)
            guard (2...3).contains(encoding.count),
                  isSDPToken(encoding[0]),
                  encoding[1].allSatisfy(\.isNumber),
                  let clockRate = Int(encoding[1]), clockRate > 0
            else {
                throw SkyBridgeCameraError.malformedSDP("an rtpmap encoding is invalid")
            }
            let channels: Int?
            if encoding.count == 3 {
                guard encoding[2].allSatisfy(\.isNumber),
                      let parsedChannels = Int(encoding[2]), parsedChannels > 0
                else {
                    throw SkyBridgeCameraError.malformedSDP("rtpmap channels are invalid")
                }
                channels = parsedChannels
            } else {
                channels = nil
            }
            guard section.rtpMappings.updateValue(
                RTPMapping(codec: String(encoding[0]), clockRate: clockRate, channels: channels),
                forKey: payload
            ) == nil else {
                throw SkyBridgeCameraError.malformedSDP("an rtpmap attribute is duplicated")
            }
        } else if value.hasPrefix("fmtp:") {
            let remainder = value.dropFirst("fmtp:".count)
            guard let separator = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                throw SkyBridgeCameraError.malformedSDP("an fmtp attribute has no parameters")
            }
            let payloadText = remainder[..<separator]
            guard payloadText.allSatisfy(\.isNumber),
                  let payload = UInt8(payloadText), payload <= 127,
                  section.formats.contains(payload),
                  section.formatParameters[payload] == nil
            else {
                throw SkyBridgeCameraError.malformedSDP("an fmtp payload type is invalid or repeated")
            }
            let rawParameters = remainder[separator...].trimmingCharacters(in: .whitespaces)
            section.formatParameters[payload] = try parseFormatParameters(rawParameters)
        } else if value.hasPrefix("control:") {
            guard section.control == nil else {
                throw SkyBridgeCameraError.malformedSDP(
                    "a media section contains duplicate control attributes"
                )
            }
            section.control = String(value.dropFirst("control:".count))
        } else if value == "inactive" || value == "recvonly" ||
                    value == "sendonly" || value == "sendrecv"
        {
            guard !section.hasDirectionAttribute else {
                throw SkyBridgeCameraError.malformedSDP(
                    "a media section contains duplicate direction attributes"
                )
            }
            section.direction = String(value)
            section.hasDirectionAttribute = true
        }
    }

    private func parseFormatParameters(_ value: String) throws -> [String: String] {
        var output: [String: String] = [:]
        for rawParameter in value.split(separator: ";", omittingEmptySubsequences: false) {
            let parameter = rawParameter.trimmingCharacters(in: .whitespaces)
            guard !parameter.isEmpty, let equals = parameter.firstIndex(of: "=") else {
                throw SkyBridgeCameraError.malformedSDP("an fmtp parameter is invalid")
            }
            let name = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parameter[parameter.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard isSDPToken(name), !value.isEmpty,
                  value.utf8.allSatisfy({ $0 != 13 && $0 != 10 })
            else {
                throw SkyBridgeCameraError.malformedSDP("an fmtp parameter is invalid")
            }
            guard output.updateValue(value, forKey: name) == nil else {
                throw SkyBridgeCameraError.malformedSDP("an fmtp parameter is duplicated")
            }
        }
        return output
    }

    private func parsePacketizationMode(_ parameters: [String: String]) throws -> UInt8 {
        guard let value = parameters["packetization-mode"] else { return 0 }
        guard value == "0" || value == "1", let mode = UInt8(value) else {
            throw SkyBridgeCameraError.unsupportedMedia(
                "H.264 packetization-mode must be 0 or 1"
            )
        }
        return mode
    }

    private func parseParameterSets(
        _ parameters: [String: String]
    ) throws -> (sps: [Data], pps: [Data]) {
        guard let rawSets = parameters["sprop-parameter-sets"] else { return ([], []) }
        let encodedSets = rawSets.split(separator: ",", omittingEmptySubsequences: false)
        guard !encodedSets.isEmpty, encodedSets.count <= limits.maximumParameterSets else {
            throw SkyBridgeCameraError.malformedSDP(
                "sprop-parameter-sets has an invalid number of entries"
            )
        }
        var sps: [Data] = []
        var pps: [Data] = []
        for encoded in encodedSets {
            guard !encoded.isEmpty,
                  let decoded = Data(base64Encoded: String(encoded), options: []),
                  !decoded.isEmpty,
                  decoded.count <= limits.maximumParameterSetBytes
            else {
                throw SkyBridgeCameraError.malformedSDP(
                    "sprop-parameter-sets contains invalid or oversized Base64"
                )
            }
            switch decoded[decoded.startIndex] & 0x1F {
            case 7: sps.append(decoded)
            case 8: pps.append(decoded)
            default:
                throw SkyBridgeCameraError.malformedSDP(
                    "sprop-parameter-sets contains a NAL unit other than SPS/PPS"
                )
            }
        }
        guard !sps.isEmpty, !pps.isEmpty else {
            throw SkyBridgeCameraError.malformedSDP(
                "sprop-parameter-sets must contain both SPS and PPS"
            )
        }
        return (sps, pps)
    }

    private func resolveSessionControl(
        _ value: String?,
        baseURL: URL,
        endpoint: RTSPEndpoint
    ) throws -> URL {
        guard let value else { return try endpoint.validateSameOrigin(baseURL) }
        if value == "*" {
            return try endpoint.validateSameOrigin(baseURL)
        }
        return try resolveControl(value, baseURL: baseURL, endpoint: endpoint)
    }

    private func resolveMediaControl(
        _ value: String,
        baseURL: URL,
        endpoint: RTSPEndpoint
    ) throws -> URL {
        guard value != "*" else {
            throw SkyBridgeCameraError.unsupportedMedia(
                "a media-level control attribute cannot be '*'"
            )
        }
        return try resolveControl(value, baseURL: baseURL, endpoint: endpoint)
    }

    private func resolveControl(
        _ value: String,
        baseURL: URL,
        endpoint: RTSPEndpoint
    ) throws -> URL {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 != 0 && $0 != 13 && $0 != 10 }),
              let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL
        else {
            throw SkyBridgeCameraError.malformedSDP("a control URI is invalid")
        }
        return try endpoint.validateSameOrigin(resolved)
    }

    private func validPortField(_ value: Substring) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts[0].allSatisfy(\.isNumber),
              let port = Int(parts[0]), (0...65_535).contains(port)
        else { return false }
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber),
                  let count = Int(parts[1]), count > 0
            else { return false }
        }
        return true
    }

    private func portValue(_ value: Substring) -> Int {
        Int(value.split(separator: "/", maxSplits: 1)[0]) ?? 0
    }

    private func isSDPToken<S: StringProtocol>(_ value: S) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }
}
