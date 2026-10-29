import Foundation

struct RTSPParserLimits: Sendable, Equatable {
    let maximumHeaderBytes: Int
    let maximumBodyBytes: Int
    let maximumBufferedBytes: Int
    let maximumEventsPerAppend: Int

    init(
        maximumHeaderBytes: Int = 32 * 1_024,
        maximumBodyBytes: Int = 256 * 1_024,
        maximumBufferedBytes: Int = 512 * 1_024,
        maximumEventsPerAppend: Int = 1_024
    ) {
        precondition(maximumHeaderBytes >= 64)
        precondition(maximumBodyBytes >= 0)
        precondition(maximumBufferedBytes >= maximumHeaderBytes + maximumBodyBytes)
        precondition(maximumBufferedBytes <= 512 * 1_024)
        precondition(maximumEventsPerAppend > 0)
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumEventsPerAppend = maximumEventsPerAppend
    }
}

struct RTSPMessageParser: Sendable {
    private let limits: RTSPParserLimits
    private var buffer = Data()
    private var readOffset = 0

    init(limits: RTSPParserLimits = RTSPParserLimits()) {
        self.limits = limits
    }

    mutating func append(_ data: Data) throws -> [RTSPWireEvent] {
        guard !data.isEmpty else { return [] }
        guard data.count <= limits.maximumBufferedBytes,
              unconsumedByteCount <= limits.maximumBufferedBytes - data.count
        else {
            throw SkyBridgeCameraError.malformedResponse(
                "incremental parser buffer exceeds \(limits.maximumBufferedBytes) bytes"
            )
        }
        buffer.append(data)

        var events: [RTSPWireEvent] = []
        while readOffset < buffer.count {
            if buffer[readOffset] == 0x24 {
                guard buffer.count - readOffset >= 4 else { break }
                let channel = buffer[readOffset + 1]
                let payloadLength = (Int(buffer[readOffset + 2]) << 8) |
                    Int(buffer[readOffset + 3])
                guard payloadLength >= 4 else {
                    throw SkyBridgeCameraError.malformedResponse(
                        "an interleaved RTP/RTCP frame is shorter than four bytes"
                    )
                }
                let frameLength = 4 + payloadLength
                guard buffer.count - readOffset >= frameLength else { break }
                let payloadStart = readOffset + 4
                let payload = Data(buffer[payloadStart..<(payloadStart + payloadLength)])
                events.append(.interleaved(.init(channel: channel, payload: payload)))
                try enforceEventLimit(events.count)
                readOffset += frameLength
                continue
            }

            guard let headerEnd = findHeaderTerminator() else {
                if buffer.count - readOffset > limits.maximumHeaderBytes {
                    throw SkyBridgeCameraError.responseHeaderTooLarge(
                        limit: limits.maximumHeaderBytes
                    )
                }
                break
            }
            let headerLength = headerEnd + 4 - readOffset
            guard headerLength <= limits.maximumHeaderBytes else {
                throw SkyBridgeCameraError.responseHeaderTooLarge(
                    limit: limits.maximumHeaderBytes
                )
            }

            let headerData = buffer[readOffset..<headerEnd]
            let parsedHeader = try parseHeader(Data(headerData))
            guard parsedHeader.contentLength <= limits.maximumBodyBytes else {
                throw SkyBridgeCameraError.responseBodyTooLarge(limit: limits.maximumBodyBytes)
            }
            let messageLength = headerLength + parsedHeader.contentLength
            guard buffer.count - readOffset >= messageLength else { break }

            let bodyStart = headerEnd + 4
            let body = Data(buffer[bodyStart..<(bodyStart + parsedHeader.contentLength)])
            events.append(.response(.init(
                version: parsedHeader.version,
                statusCode: parsedHeader.statusCode,
                reasonPhrase: parsedHeader.reasonPhrase,
                headers: parsedHeader.headers,
                body: body
            )))
            try enforceEventLimit(events.count)
            readOffset += messageLength
        }

        compactIfNeeded()
        return events
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        readOffset = 0
    }

    private var unconsumedByteCount: Int { buffer.count - readOffset }

    private func enforceEventLimit(_ count: Int) throws {
        guard count <= limits.maximumEventsPerAppend else {
            throw SkyBridgeCameraError.malformedResponse(
                "a receive batch exceeds \(limits.maximumEventsPerAppend) protocol events"
            )
        }
    }

    private func findHeaderTerminator() -> Int? {
        guard buffer.count - readOffset >= 4 else { return nil }
        let lastStart = buffer.count - 4
        var index = readOffset
        while index <= lastStart {
            if buffer[index] == 13,
               buffer[index + 1] == 10,
               buffer[index + 2] == 13,
               buffer[index + 3] == 10
            {
                return index
            }
            index += 1
        }
        return nil
    }

    private struct ParsedHeader {
        let version: String
        let statusCode: Int
        let reasonPhrase: String
        let headers: [String: [String]]
        let contentLength: Int
    }

    private func parseHeader(_ data: Data) throws -> ParsedHeader {
        guard data.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 <= 126) || $0 == 13 || $0 == 10 }),
              let header = String(data: data, encoding: .ascii)
        else {
            throw SkyBridgeCameraError.malformedResponse(
                "headers contain non-ASCII or control characters"
            )
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw SkyBridgeCameraError.malformedResponse("the status line is missing")
        }
        let status = try parseStatusLine(statusLine)

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else {
                throw SkyBridgeCameraError.malformedResponse(
                    "an empty line appears inside the header block"
                )
            }
            guard line.first != " ", line.first != "\t" else {
                throw SkyBridgeCameraError.malformedResponse(
                    "obsolete folded headers are not accepted"
                )
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw SkyBridgeCameraError.malformedResponse("a header is missing ':'")
            }
            let name = String(line[..<colon]).lowercased()
            guard isHeaderName(name) else {
                throw SkyBridgeCameraError.malformedResponse("a header name is invalid")
            }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }

        let rawLengths = headers["content-length"] ?? []
        var contentLength = 0
        if let first = rawLengths.first {
            guard !first.isEmpty, first.allSatisfy(\.isNumber), let parsed = Int(first) else {
                throw SkyBridgeCameraError.malformedResponse("Content-Length is invalid")
            }
            guard rawLengths.allSatisfy({ $0 == first }) else {
                throw SkyBridgeCameraError.malformedResponse(
                    "conflicting Content-Length headers"
                )
            }
            contentLength = parsed
        }

        return ParsedHeader(
            version: status.version,
            statusCode: status.code,
            reasonPhrase: status.reason,
            headers: headers,
            contentLength: contentLength
        )
    }

    private func parseStatusLine(_ line: String) throws -> (version: String, code: Int, reason: String) {
        guard line.hasPrefix("RTSP/1.0 ") else {
            throw SkyBridgeCameraError.malformedResponse("only RTSP/1.0 is supported")
        }
        let afterVersion = line.dropFirst("RTSP/1.0 ".count)
        let codeText = afterVersion.prefix(3)
        guard codeText.count == 3,
              codeText.allSatisfy(\.isNumber),
              let code = Int(codeText),
              (100...999).contains(code)
        else {
            throw SkyBridgeCameraError.malformedResponse("the status code is invalid")
        }
        let remaining = afterVersion.dropFirst(3)
        guard remaining.isEmpty || remaining.first == " " else {
            throw SkyBridgeCameraError.malformedResponse(
                "the status code and reason phrase are not separated"
            )
        }
        let reason = remaining.isEmpty ? "" : String(remaining.dropFirst())
        return ("RTSP/1.0", code, reason)
    }

    private func isHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 45
        }
    }

    private mutating func compactIfNeeded() {
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 64 * 1_024, readOffset >= buffer.count / 2 {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }
}
