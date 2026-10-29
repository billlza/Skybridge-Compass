import Foundation

enum RemoteControlSOABindingPolicy {
    static var allowsInsecureLegacyRemoteControl: Bool {
        allowsInsecureLegacyRemoteControl(environment: ProcessInfo.processInfo.environment)
    }

    static func allowsInsecureLegacyRemoteControl(environment: [String: String]) -> Bool {
        #if DEBUG || SKYBRIDGE_TESTING
        let raw = environment["SKYBRIDGE_ALLOW_INSECURE_REMOTE_CONTROL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
        #else
        // A launch environment must never weaken authenticated-channel binding in a product build.
        return false
        #endif
    }

    @available(macOS 14.0, iOS 17.0, *)
    struct Binding: Sendable, Equatable {
        let localPeerId: Data
        let expectedRemotePeerId: Data
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func peerId(for identifier: String?) -> Data? {
        RemoteControlInboundTrustResolver.soaPeerId(for: identifier)
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func binding(
        localDeviceId: String?,
        remoteDeviceId: String?
    ) -> Binding? {
        guard let localPeerId = peerId(for: localDeviceId),
              let expectedRemotePeerId = peerId(for: remoteDeviceId) else {
            return nil
        }
        return Binding(
            localPeerId: localPeerId,
            expectedRemotePeerId: expectedRemotePeerId
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func randomAttemptId() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }
}
