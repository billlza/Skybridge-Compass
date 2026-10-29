#if os(macOS)
import Foundation
import XCTest

@testable import SkyBridgeMessagePersistence

/// Exercises the sidecar `lockf` boundary against a real second OS process
/// (the `MessagingRepositoryLockProbe` executable built by this package).
/// Same-process tests cannot reach these branches because the coordinator
/// deduplicates locks within one process.
final class SQLiteRepositoryCrossProcessLockTests: XCTestCase {
    func testSecondProcessBootstrapFailsClosedWhileThisProcessHoldsTheLock() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        let probe = try Self.launchProbe(
            arguments: ["bootstrap", fixture.databaseURL.path]
        )
        let outcome = try await probe.collectVerdicts()
        XCTAssertEqual(outcome.exitStatus, 2)
        XCTAssertEqual(outcome.verdicts.last?["outcome"], "lock_conflict")
    }

    func testBootstrapFailsClosedWhileSecondProcessHoldsTheLockAndRecoversAfterExit() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }

        let probe = try Self.launchProbe(
            arguments: ["hold", fixture.databaseURL.path, "30"]
        )
        let holding = try await probe.nextVerdict()
        XCTAssertEqual(holding["outcome"], "holding")

        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await repository.bootstrap()
            XCTFail("Bootstrap must fail closed while another process owns the store")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "database_owned_by_another_process")
            )
        }

        // Process death releases the lock without any cooperative cleanup.
        probe.process.terminate()
        _ = try await probe.collectVerdicts()
        let snapshot = try await repository.bootstrap()
        XCTAssertEqual(snapshot.messages, [])
    }

    func testClaimAbandonedByDeadProcessIsRecoveredOnNextBootstrap() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }

        let probe = try Self.launchProbe(
            arguments: ["abandon-claim", fixture.databaseURL.path]
        )
        let outcome = try await probe.collectVerdicts()
        XCTAssertEqual(outcome.exitStatus, 0)
        let abandoned = try XCTUnwrap(outcome.verdicts.last)
        XCTAssertEqual(abandoned["outcome"], "claim_abandoned")
        let queueID = try XCTUnwrap(abandoned["queueID"])

        // The probe process is dead, so its persisted claim identity no
        // longer maps to a live lock holder: bootstrap must return the
        // claimed intent to pending with the claim identity cleared.
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let snapshot = try await repository.bootstrap()
        let recovered = try XCTUnwrap(snapshot.deliveryIntents.first {
            $0.queueID == queueID
        })
        XCTAssertEqual(recovered.state, .pending)
        XCTAssertNil(recovered.receiptDeadline)
        XCTAssertEqual(
            try rawSQLiteScalar(
                at: fixture.databaseURL,
                sql: """
                SELECT COUNT(*) FROM delivery_intents
                 WHERE queue_id = '\(queueID)'
                   AND claim_owner IS NULL
                   AND claim_process_id IS NULL
                   AND claim_instance_id IS NULL
                """
            ),
            1
        )

        // The recovered intent is claimable by this process.
        let reclaimed = try await repository.claim(
            messageID: recovered.messageID,
            ownerToken: UUID()
        )
        XCTAssertEqual(reclaimed.claim.intent.queueID, queueID)
    }

    func testProbeBootstrapSucceedsOnUncontestedStore() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }

        let probe = try Self.launchProbe(
            arguments: ["bootstrap", fixture.databaseURL.path]
        )
        let outcome = try await probe.collectVerdicts()
        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertEqual(outcome.verdicts.last?["outcome"], "bootstrapped")

        // The probe exited, so this process can take the lock immediately.
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
    }

    // MARK: - Probe process plumbing

    private struct ProbeLaunchFailure: Error, CustomStringConvertible {
        let description: String
    }

    private final class ProbeHandle {
        let process: Process
        private var lineIterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
        private let exitStatuses: AsyncStream<Int32>

        init(
            process: Process,
            standardOutput: FileHandle,
            exitStatuses: AsyncStream<Int32>
        ) {
            self.process = process
            self.lineIterator = standardOutput.bytes.lines.makeAsyncIterator()
            self.exitStatuses = exitStatuses
        }

        /// Reads the next JSON verdict line the probe emits.
        func nextVerdict() async throws -> [String: String] {
            guard let line = try await lineIterator.next() else {
                throw ProbeLaunchFailure(
                    description: "probe exited before emitting a verdict"
                )
            }
            return try Self.decodeVerdict(line)
        }

        /// Drains every remaining verdict, waits for the probe to exit, and
        /// returns the verdicts paired with the real process exit status.
        func collectVerdicts() async throws -> (
            verdicts: [[String: String]],
            exitStatus: Int32
        ) {
            var verdicts: [[String: String]] = []
            while let line = try await lineIterator.next() {
                verdicts.append(try Self.decodeVerdict(line))
            }
            for await status in exitStatuses {
                return (verdicts, status)
            }
            throw ProbeLaunchFailure(description: "probe exit status unavailable")
        }

        private static func decodeVerdict(_ line: String) throws -> [String: String] {
            guard let verdict = try JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: String] else {
                throw ProbeLaunchFailure(description: "malformed probe verdict: \(line)")
            }
            return verdict
        }
    }

    private static func launchProbe(arguments: [String]) throws -> ProbeHandle {
        let probeURL = try productsDirectory()
            .appendingPathComponent("MessagingRepositoryLockProbe")
        guard FileManager.default.isExecutableFile(atPath: probeURL.path) else {
            throw ProbeLaunchFailure(
                description: "probe executable missing at \(probeURL.path)"
            )
        }
        let process = Process()
        process.executableURL = probeURL
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        // Registered before launch so the exit status can never be missed,
        // no matter how quickly the probe terminates.
        let exitStatuses = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        return ProbeHandle(
            process: process,
            standardOutput: stdout.fileHandleForReading,
            exitStatuses: exitStatuses
        )
    }

    /// The build products directory that contains both this test bundle and
    /// the probe executable target it depends on.
    private static func productsDirectory() throws -> URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        throw ProbeLaunchFailure(description: "no .xctest bundle in runtime")
    }
}
#endif
