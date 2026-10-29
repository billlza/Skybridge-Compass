import Foundation
import OSLog
import SkyBridgeProtocolCore

enum CrossNetworkConnectionCodeSnapshotStore {
    private struct Snapshot: Codable, Sendable {
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
    private static let writerQueue = DispatchQueue(
        label: "com.skybridge.connection-code-snapshot-writer",
        qos: .utility
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
        let url = snapshotURL()
        writerQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            } catch {
                logger.error(
                    "Connection code snapshot write failed errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
#endif
    }

    static func remove() {
#if os(macOS)
        let url = snapshotURL()
        writerQueue.async {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                logger.error(
                    "Connection code snapshot removal failed errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
#endif
    }

    private static func applicationSupportDirectory() -> URL {
#if os(macOS)
        // Unchanged on macOS: this is an existing on-disk location and moving it would be an
        // unannounced persistence migration.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SkyBridge", isDirectory: true)
#else
        // `homeDirectoryForCurrentUser` is unavailable on iOS; use the container's own
        // Application Support directory.
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("SkyBridge", isDirectory: true)
#endif
    }

    private static func snapshotURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
