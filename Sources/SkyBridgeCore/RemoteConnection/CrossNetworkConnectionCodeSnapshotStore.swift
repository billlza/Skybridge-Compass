import Foundation
import OSLog
import SkyBridgeProtocolCore

enum CrossNetworkConnectionCodeSnapshotStore {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let code: String
        let sessionId: String
        let expiresAt: String?
        let leaseMode: String
        let deviceId: String
        let protocolPublicKeyFingerprint: String
        let generatedAt: String
    }

    private static let fileName = "connection-code-latest.json"
    private static let logger = Logger(
        subsystem: "com.skybridge.connection",
        category: "ConnectionCodeSnapshot"
    )

    static func write(
        code: String,
        sessionID: String,
        expiresAt: Date?,
        leaseModeRawValue: String,
        binding: ProtocolIdentityBinding
    ) {
#if os(macOS)
        let formatter = ISO8601DateFormatter()
        let snapshot = Snapshot(
            schemaVersion: 1,
            code: code,
            sessionId: sessionID,
            expiresAt: expiresAt.map { formatter.string(from: $0) },
            leaseMode: leaseModeRawValue,
            deviceId: binding.deviceId,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            generatedAt: formatter.string(from: Date())
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = snapshotURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            logger.debug(
                "connection code snapshot write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
#endif
    }

    static func remove() {
#if os(macOS)
        try? FileManager.default.removeItem(at: snapshotURL())
#endif
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SkyBridge", isDirectory: true)
    }

    private static func snapshotURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
