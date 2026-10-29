import Foundation

struct RTSPResponse: Sendable, Equatable {
    let version: String
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: [String]]
    let body: Data

    init(
        version: String,
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: [String]],
        body: Data
    ) {
        self.version = version
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    func headerValues(named name: String) -> [String] {
        headers[name.lowercased()] ?? []
    }

    func firstHeaderValue(named name: String) -> String? {
        headerValues(named: name).first
    }

    var cSeq: Int? {
        guard let raw = firstHeaderValue(named: "cseq")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty,
              raw.allSatisfy(\.isNumber)
        else { return nil }
        return Int(raw)
    }
}

struct RTSPInterleavedFrame: Sendable, Equatable {
    let channel: UInt8
    let payload: Data

    init(channel: UInt8, payload: Data) {
        self.channel = channel
        self.payload = payload
    }
}

enum RTSPWireEvent: Sendable, Equatable {
    case response(RTSPResponse)
    case interleaved(RTSPInterleavedFrame)
}

public struct RTSPCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String

    public var description: String { "RTSPCredentials(<redacted>)" }
    public var debugDescription: String { description }

    public init(username: String, password: String) throws {
        guard !username.isEmpty else {
            throw SkyBridgeCameraError.invalidEndpoint("the camera username is empty")
        }
        guard username.utf8.count <= 256 else {
            throw SkyBridgeCameraError.invalidEndpoint("the camera username exceeds 256 bytes")
        }
        guard username.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            throw SkyBridgeCameraError.invalidEndpoint(
                "the camera username must contain printable ASCII only"
            )
        }
        guard password.utf8.count <= 1_024 else {
            throw SkyBridgeCameraError.invalidEndpoint("the camera password exceeds 1024 bytes")
        }
        guard username.utf8.allSatisfy({ $0 != 13 && $0 != 10 }),
              password.utf8.allSatisfy({ $0 != 13 && $0 != 10 })
        else {
            throw SkyBridgeCameraError.invalidEndpoint("credentials contain a line break")
        }
        guard !username.contains(":") else {
            throw SkyBridgeCameraError.invalidEndpoint(
                "the camera username must not contain ':'"
            )
        }
        self.username = username
        self.password = password
    }
}
