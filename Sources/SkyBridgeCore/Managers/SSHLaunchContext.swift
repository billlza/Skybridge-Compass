import Foundation

public struct SSHLaunchRequest: Identifiable, Sendable {
    public let id: UUID
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
}

public struct SSHLaunchPresentation: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

public enum SSHLaunchContextError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest
    case tooManyPendingRequests
    case requestExpired

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The SSH host, port, username, or credential length is invalid."
        case .tooManyPendingRequests:
            return "Too many SSH terminal windows are waiting for credentials."
        case .requestExpired:
            return "The SSH connection request expired before the terminal window opened."
        }
    }
}

/// Bounded, one-shot SSH credential handoff between windows.
///
/// Every request has a unique owner token. A terminal can consume or clear only its own request,
/// so closing an older window cannot erase credentials intended for a newer window. Expiration
/// tasks capture only the UUID, never the password.
@MainActor
public final class SSHLaunchContext: ObservableObject {
    public static let shared = SSHLaunchContext()

    private static let productionCredentialLifetime: Duration = .seconds(30)
    private static let maximumPendingRequestCount = 8
    private let credentialLifetime: Duration
    private var pendingRequests: [UUID: SSHLaunchRequest] = [:]
    private var expirationTasks: [UUID: Task<Void, Never>] = [:]

#if DEBUG || SKYBRIDGE_TESTING
    init(credentialLifetime: Duration = .seconds(30)) {
        self.credentialLifetime = credentialLifetime
    }
#else
    private init() {
        credentialLifetime = SSHLaunchContext.productionCredentialLifetime
    }
#endif

    @discardableResult
    public func configure(
        host: String,
        port: Int,
        username: String,
        password: String
    ) throws -> UUID {
        guard !host.isEmpty,
              host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              host.utf8.count <= 1_024,
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...65_535).contains(port),
              !username.isEmpty,
              username.utf8.count <= 255,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              password.utf8.count <= 16_384 else {
            throw SSHLaunchContextError.invalidRequest
        }
        guard pendingRequests.count < Self.maximumPendingRequestCount else {
            throw SSHLaunchContextError.tooManyPendingRequests
        }

        var requestID = UUID()
        while pendingRequests[requestID] != nil {
            requestID = UUID()
        }
        let request = SSHLaunchRequest(
            id: requestID,
            host: host,
            port: port,
            username: username,
            password: password
        )
        pendingRequests[requestID] = request

        let credentialLifetime = self.credentialLifetime
        expirationTasks[requestID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: credentialLifetime)
            } catch is CancellationError {
                return
            } catch {
                self?.clearPendingCredentials(requestID: requestID)
                return
            }
            self?.clearPendingCredentials(requestID: requestID)
        }
        return requestID
    }

    public func presentation(for requestID: UUID) -> SSHLaunchPresentation? {
        pendingRequests[requestID].map {
            SSHLaunchPresentation(host: $0.host, port: $0.port, username: $0.username)
        }
    }

    public func consumeConnectionRequest(requestID: UUID) -> SSHLaunchRequest? {
        guard let request = pendingRequests.removeValue(forKey: requestID) else { return nil }
        expirationTasks.removeValue(forKey: requestID)?.cancel()
        return request
    }

    public func clearPendingCredentials(requestID: UUID) {
        pendingRequests.removeValue(forKey: requestID)
        expirationTasks.removeValue(forKey: requestID)?.cancel()
    }

    public func clearAllPendingCredentials() {
        pendingRequests.removeAll(keepingCapacity: false)
        let tasks = Array(expirationTasks.values)
        expirationTasks.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
    }
}
