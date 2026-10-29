import Foundation
import SkyBridgeMessagePersistence

/// Cross-process probe for the messaging repository's sidecar lock.
///
/// XCTest launches this executable as a real second OS process to exercise the
/// `lockf` boundary that same-process tests cannot reach: lock conflicts,
/// lock release on process exit, and recovery of claims abandoned by a dead
/// process. Every verdict is one line of JSON on stdout.
///
/// Usage:
///   MessagingRepositoryLockProbe bootstrap <database-path>
///   MessagingRepositoryLockProbe hold <database-path> <seconds>
///   MessagingRepositoryLockProbe abandon-claim <database-path>
private func emit(_ payload: [String: String]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    ) else {
        FileHandle.standardError.write(Data("probe_encoding_failure\n".utf8))
        exit(70)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@main
struct MessagingRepositoryLockProbeMain {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            emit(["outcome": "usage_error"])
            exit(64)
        }
        let command = arguments[1]
        let databaseURL = URL(fileURLWithPath: arguments[2])
        let repository = SQLiteDeviceMessagingRepository(databaseURL: databaseURL)
        do {
            let snapshot = try await repository.bootstrap()
            switch command {
            case "bootstrap":
                emit([
                    "outcome": "bootstrapped",
                    "generation": String(snapshot.generation),
                ])
                exit(0)

            case "hold":
                guard arguments.count >= 4,
                      let seconds = Double(arguments[3]),
                      seconds > 0, seconds <= 60 else {
                    emit(["outcome": "usage_error"])
                    exit(64)
                }
                emit(["outcome": "holding"])
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                _ = try await repository.currentSnapshot()
                emit(["outcome": "released"])
                exit(0)

            case "abandon-claim":
                // Claim one delivery and exit without resolving it. The row
                // keeps this process's persisted claim identity while process
                // death releases the sidecar lock, exactly like a crash.
                let messageID = UUID()
                let now = Date()
                let message = PersistedMessageRecord(
                    id: messageID,
                    conversationFingerprint: String(repeating: "c", count: 64),
                    targetDeviceID: "probe-device-0001",
                    direction: .outgoing,
                    text: "probe",
                    timestamp: now,
                    deliveryState: .pending
                )
                let intent = PersistedDeliveryIntent(
                    queueID: messageID.uuidString.lowercased(),
                    messageID: messageID,
                    targetDeviceID: "probe-device-0001",
                    messageType: "text",
                    priority: 1,
                    payload: Data("probe".utf8),
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(3_600)
                )
                _ = try await repository.stageOutgoing(message: message, intent: intent)
                let outcome = try await repository.claim(
                    messageID: messageID,
                    ownerToken: UUID(),
                    now: now
                )
                emit([
                    "outcome": "claim_abandoned",
                    "queueID": outcome.claim.intent.queueID,
                ])
                exit(0)

            default:
                emit(["outcome": "usage_error"])
                exit(64)
            }
        } catch let error as DeviceMessagingRepositoryError {
            if case .invalidRecord(let reasonCode) = error,
               reasonCode == "database_owned_by_another_process" {
                emit(["outcome": "lock_conflict"])
                exit(2)
            }
            emit(["outcome": "repository_error", "detail": String(describing: error)])
            exit(1)
        } catch {
            emit(["outcome": "error", "detail": String(describing: error)])
            exit(1)
        }
    }
}
