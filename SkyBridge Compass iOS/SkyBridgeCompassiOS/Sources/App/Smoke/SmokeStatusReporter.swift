#if DEBUG || SKYBRIDGE_TESTING
import Darwin
import Foundation

@available(iOS 17.0, *)
struct SmokeArtifactBasename: Sendable, Equatable {
    enum ValidationError: LocalizedError, Sendable, Equatable {
        case missing
        case invalid

        var errorDescription: String? {
            switch self {
            case .missing:
                return "smoke artifact basename is missing"
            case .invalid:
                return "smoke artifact basename is invalid"
            }
        }
    }

    static let maximumUTF8Length = 128
    private static let allowedASCII = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    let value: String

    init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ValidationError.missing
        }
        guard value == rawValue,
              value != ".",
              value != "..",
              value.utf8.count <= Self.maximumUTF8Length,
              value.unicodeScalars.allSatisfy(Self.allowedASCII.contains),
              !value.contains("/"),
              !value.contains("\\") else {
            throw ValidationError.invalid
        }
        self.value = value
    }

    static func resolve(
        environmentValue: String?,
        defaultValue: String? = nil
    ) throws -> SmokeArtifactBasename? {
        guard let rawValue = environmentValue ?? defaultValue else { return nil }
        return try SmokeArtifactBasename(rawValue)
    }

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(value, isDirectory: false)
    }
}

@available(iOS 17.0, *)
enum SmokeArtifactFileIO {
    private enum SinkError: LocalizedError {
        case systemCallFailed(operation: String, code: Int32)
        case terminalFailure

        var errorDescription: String? {
            switch self {
            case .systemCallFailed(let operation, let code):
                return "smoke status sink \(operation) failed (errno=\(code))"
            case .terminalFailure:
                return "smoke status sink is in a terminal failure state"
            }
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var terminalPaths: Set<String> = []
        var protectionAttributeConfiguredPaths: Set<String> = []
    }

    private static let state = State()

    static func resetProtectedFile(at url: URL) throws {
        state.lock.lock()
        defer { state.lock.unlock() }

        do {
            try writeProtectedDataUnlocked(Data(), to: url)
            state.terminalPaths.remove(url.path)
        } catch {
            state.terminalPaths.insert(url.path)
            state.protectionAttributeConfiguredPaths.remove(url.path)
            throw error
        }
    }

    static func replaceProtectedData(_ data: Data, at url: URL) throws {
        state.lock.lock()
        defer { state.lock.unlock() }

        do {
            try writeProtectedDataUnlocked(data, to: url)
            state.terminalPaths.remove(url.path)
        } catch {
            state.terminalPaths.insert(url.path)
            state.protectionAttributeConfiguredPaths.remove(url.path)
            throw error
        }
    }

    static func appendProtectedData(_ data: Data, to url: URL) throws {
        state.lock.lock()
        defer { state.lock.unlock() }

        guard !state.terminalPaths.contains(url.path) else {
            throw SinkError.terminalFailure
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw SinkError.systemCallFailed(operation: "open", code: errno)
            }

            var operationError: Error?
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
                state.protectionAttributeConfiguredPaths.insert(url.path)
                try writeAll(data, to: descriptor)
            } catch {
                operationError = error
            }

            let closeResult = Darwin.close(descriptor)
            if let operationError {
                throw operationError
            }
            guard closeResult == 0 else {
                throw SinkError.systemCallFailed(operation: "close", code: errno)
            }
        } catch {
            state.terminalPaths.insert(url.path)
            state.protectionAttributeConfiguredPaths.remove(url.path)
            throw error
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1, errno == EINTR {
                    continue
                }
                throw SinkError.systemCallFailed(
                    operation: "write",
                    code: written == 0 ? EIO : errno
                )
            }
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    static func hasTerminalFailure(at url: URL) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.terminalPaths.contains(url.path)
    }

    static func hasConfiguredProtectionAttribute(at url: URL) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.protectionAttributeConfiguredPaths.contains(url.path)
    }
#endif

    private static func writeProtectedDataUnlocked(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        state.protectionAttributeConfiguredPaths.insert(url.path)
    }
}

@available(iOS 17.0, *)
/// Thread-safe because the URL is immutable, reporter sequencing uses `lock`, and all
/// cross-reporter file mutation is serialized by `SmokeArtifactFileIO`.
final class SmokeStatusReporter: @unchecked Sendable {
    let statusURL: URL?
    private let stdoutMirrorDescriptor: Int32?
    private let lock = NSLock()

    init(statusURL: URL?) {
        self.statusURL = statusURL
        stdoutMirrorDescriptor = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil
            ? STDOUT_FILENO
            : nil
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(statusURL: URL?, stdoutMirrorDescriptor: Int32?) {
        self.statusURL = statusURL
        self.stdoutMirrorDescriptor = stdoutMirrorDescriptor
    }
#endif

    func reset() throws {
        guard let statusURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try SkyBridgeDiagnosticTrace.resetStatusArtifacts(primaryStatusURL: statusURL)
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        lock.lock()
        defer { lock.unlock() }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatted = "[\(formatter.string(from: Date()))] \(line)\n"
        let data = Data(formatted.utf8)

        do {
            try SmokeArtifactFileIO.appendProtectedData(data, to: statusURL)
        } catch {
            SkyBridgeLogger.shared.error("Smoke status sink entered terminal failure state")
            return
        }

        if let stdoutMirrorDescriptor {
            do {
                try SmokeArtifactFileIO.writeAll(data, to: stdoutMirrorDescriptor)
            } catch {
                SkyBridgeLogger.shared.warning("Smoke status stdout mirror failed")
            }
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    var hasTerminalWriteFailure: Bool {
        guard let statusURL else { return false }
        return SmokeArtifactFileIO.hasTerminalFailure(at: statusURL)
    }
#endif
}

@available(iOS 17.0, *)
func writeProtectedData(_ data: Data, to url: URL) throws {
    try SmokeArtifactFileIO.replaceProtectedData(data, at: url)
}
#endif
