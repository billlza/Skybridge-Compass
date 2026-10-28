import Foundation
import CSkyBridgeBootWitness

/// Identifies a continuous-clock epoch; this contains no account authority.
/// The registered App Group is a trusted IPC namespace, not a source of login
/// records. Existing private/shared identity queries exclude its Keychain group.
enum IOSAudioBootWitness {
    enum Failure: Error, LocalizedError, Equatable {
        case native(step: Int32, status: Int32, cleanup: Int32)
        case invalidResult

        var errorDescription: String? { "无法读取本机授权时钟，请稍后重试。" }
    }

    private static let namespace = "group.com.skybridge.compass/ab1"

    static func read() async throws -> UUID {
        try Task.checkCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let manager = FileManager.default
            let directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
                .appendingPathComponent("AudioMembership", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
            let result = try readNative(name: namespace, lock: directory.appendingPathComponent("boot.lock"))
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await operation.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            // The C lock wait is bounded to one second and always releases its
            // descriptors. Cancellation cannot make an unfinished read succeed.
            operation.cancel()
        }
    }

    /// Internal native boundary also exercised with isolated test namespaces.
    /// Production supplies only the fixed name and private application directory.
    static func readNative(name: String, lock: URL) throws -> UUID {
        var result = sb_boot_result()
        let status = name.withCString { name in
            lock.path.withCString { path in sb_boot_read(name, path, &result) }
        }
        guard status == 0, result.system_error == 0, result.cleanup_error == 0 else {
            throw Failure.native(step: result.step, status: result.system_error, cleanup: result.cleanup_error)
        }
        guard [Int32(SB_BOOT_CREATED.rawValue), Int32(SB_BOOT_EXISTING.rawValue),
               Int32(SB_BOOT_RECOVERED.rawValue)].contains(result.kind) else { throw Failure.invalidResult }
        let identifier = UUID(uuid: result.identifier)
        guard identifier != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw Failure.invalidResult
        }
        return identifier
    }
}
