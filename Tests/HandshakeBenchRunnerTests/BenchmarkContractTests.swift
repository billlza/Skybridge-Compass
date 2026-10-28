import Foundation
import XCTest
@testable import HandshakeBenchRunner
import SkyBridgeCore

@MainActor
final class BenchmarkContractTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testInvalidCountsProfilesAndPathsAreRejected() throws {
        for environment in [
            ["SKYBRIDGE_BENCH_ITERATIONS": "0"],
            ["SKYBRIDGE_BENCH_ITERATIONS": "not-a-number"],
            ["SKYBRIDGE_BENCH_WARMUP": "-1"],
            ["SKYBRIDGE_BENCH_RUNNER_BATCHES": "0"],
            ["SKYBRIDGE_BENCH_COOLDOWN_SECONDS": "-1"],
            ["SKYBRIDGE_BENCH_PROFILE": "typo"],
            ["SKYBRIDGE_BENCH_OUTPUT_SET": "typo"],
            ["SKYBRIDGE_BENCH_INCLUDE_XWING": "maybe"],
            ["SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT": "0"],
            ["ARTIFACT_DATE": "../outside"],
            ["ARTIFACTS_DIR": ""]
        ] {
            XCTAssertThrowsError(try BenchmarkConfiguration(environment: environment), "\(environment)")
        }
    }

    func testComparisonAdmissionAndBalancedOrder() throws {
        XCTAssertThrowsError(try BenchmarkConfiguration(environment: ["SKYBRIDGE_BENCH_PROFILE": "comparison"]))
        XCTAssertThrowsError(try BenchmarkConfiguration(environment: [
            "SKYBRIDGE_BENCH_PROFILE": "comparison", "SB_ENABLE_QPERIAPT": "1",
            "SKYBRIDGE_BENCH_APPLE_ITERATIONS": "3"
        ]))
        let config = try BenchmarkConfiguration(environment: [
            "SKYBRIDGE_BENCH_PROFILE": "comparison", "SB_ENABLE_QPERIAPT": "1",
            "SKYBRIDGE_BENCH_ITERATIONS": "6", "SKYBRIDGE_BENCH_WARMUP": "0"
        ])
        XCTAssertEqual(config.appleIterations, 6)
        XCTAssertEqual(config.warmup, 0)
        let orders = (0..<6).map(BenchmarkConfiguration.comparisonOrder)
        XCTAssertEqual(Set(orders).count, 6)
        for position in 0..<3 {
            for provider in 0..<3 {
                XCTAssertEqual(orders.filter { $0[position] == provider }.count, 2)
            }
        }
    }

    func testStatisticsRejectMissingInvalidAndOverflowSamples() throws {
        for samples: [Double] in [[], [.nan], [.infinity], [-1], [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]] {
            XCTAssertThrowsError(try BenchmarkStatistics(samples: samples))
        }
        let stats = try BenchmarkStatistics(samples: [1, 2, 3, 4, 5])
        XCTAssertEqual(stats.mean, 3)
        XCTAssertEqual(stats.p50, 3)
        XCTAssertEqual(stats.p95, 4)
        XCTAssertEqual(stats.p99, 4)
        XCTAssertEqual(stats.stdDev, sqrt(2), accuracy: 1e-12)
    }

    func testArtifactRunsRemainSeparateAndRawSamplesDecode() throws {
        let root = try temporaryRoot()
        let config = try BenchmarkConfiguration(environment: ["ARTIFACTS_DIR": root.path])
        let first = try BenchmarkArtifacts(configuration: config)
        let second = try BenchmarkArtifacts(configuration: config)
        XCTAssertNotEqual(first.directory, second.directory)
        let sample = BenchmarkSample(sequence: 1, batch: 1, iteration: 1, provider: "provider", suiteWireID: 18,
                                     latencyMS: 1.5, rttMS: 1, messageABytes: 10, messageBBytes: 20, finishedBytes: 30)
        try first.record(sample)
        try first.record(sample)
        let lines = try String(contentsOf: first.directory.appendingPathComponent("samples.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoded = try JSONDecoder().decode(BenchmarkSample.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.suiteWireID, 18)
        XCTAssertEqual(decoded.latencyMS, 1.5)
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("samples.jsonl")).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("completion.json").path))
    }

    func testExplicitArtifactFailuresPropagateWithoutFallback() throws {
        let root = try temporaryRoot()
        let blockedRoot = root.appendingPathComponent("file")
        try Data([1]).write(to: blockedRoot)
        let config = try BenchmarkConfiguration(environment: ["ARTIFACTS_DIR": blockedRoot.path])
        XCTAssertThrowsError(try BenchmarkArtifacts(configuration: config))
        XCTAssertEqual(try Data(contentsOf: blockedRoot), Data([1]))
        let artifacts = try BenchmarkArtifacts(configuration: .init(environment: ["ARTIFACTS_DIR": root.path]))
        let output = artifacts.directory.appendingPathComponent("samples.jsonl")
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        XCTAssertThrowsError(try BenchmarkArtifacts.append(Data([1]), to: output))
        XCTAssertThrowsError(try artifacts.writeSummary(provider: "empty", samples: []))
    }

    func testTransportRejectsMissingReceiverAndClosedUse() async throws {
        let transport = BenchmarkTransport()
        do {
            try await transport.send(to: .init(deviceId: "peer"), data: Data([1]))
            XCTFail("Missing receiver must throw")
        } catch {
            XCTAssertEqual(String(describing: error), BenchmarkError.missingReceiver.description)
        }
        await transport.close()
        do {
            try await transport.send(to: .init(deviceId: "peer"), data: Data([1]))
            XCTFail("Closed transport must throw")
        } catch {
            XCTAssertEqual(String(describing: error), BenchmarkError.closedTransport.description)
        }
    }

    func testTransportCloseReleasesReceiverAndFrames() async throws {
        let transport = BenchmarkTransport()
        var receiver: Receiver? = Receiver()
        weak let observed = receiver
        await transport.setReceiver { [captured = receiver] _, _ in
            guard let captured else { throw BenchmarkError.missingReceiver }
            await captured.receive()
        }
        receiver = nil
        XCTAssertNotNil(observed)
        try await transport.send(to: .init(deviceId: "peer"), data: Data([1]))
        let count = await observed?.count
        XCTAssertEqual(count, 1)
        await transport.close()
        XCTAssertNil(observed)
        let frames = await transport.sentMessages
        XCTAssertEqual(frames.count, 0)
    }

    func testDeadlineReleasesSuspendedOperationBeforeReturning() async throws {
        let gate = PendingOperation()
        do {
            let _: Int = try await HandshakeBenchRunner.withDeadline(timeout: .milliseconds(10), cancel: {
                await gate.cancel()
            }) {
                try await gate.wait()
            }
            XCTFail("Deadline must throw")
        } catch {
            XCTAssertEqual(String(describing: error), BenchmarkError.timeout.description)
        }
        let state = await gate.snapshot()
        XCTAssertTrue(state.cancelled)
        XCTAssertTrue(state.returned)
    }

    func testDeadlinePreservesOperationErrorAndCancelsTimer() async throws {
        let gate = PendingOperation()
        do {
            let _: Int = try await HandshakeBenchRunner.withDeadline(timeout: .seconds(30), cancel: {
                await gate.cancel()
            }) {
                throw BenchmarkError.missingReceiver
            }
            XCTFail("Operation error must propagate")
        } catch {
            XCTAssertEqual(String(describing: error), BenchmarkError.missingReceiver.description)
        }
        let state = await gate.snapshot()
        XCTAssertTrue(state.cancelled)
        let value = try await HandshakeBenchRunner.withDeadline(timeout: .seconds(30), cancel: {}) { 42 }
        XCTAssertEqual(value, 42)
    }
}

private actor Receiver {
    private(set) var count = 0
    func receive() { count += 1 }
}

private actor PendingOperation {
    private var continuation: CheckedContinuation<Int, any Error>?
    private var cancelled = false
    private var returned = false
    func wait() async throws -> Int {
        defer { returned = true }
        return try await withCheckedThrowingContinuation { continuation in
            if cancelled { continuation.resume(throwing: CancellationError()) }
            else { self.continuation = continuation }
        }
    }
    func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
    func snapshot() -> (cancelled: Bool, returned: Bool) { (cancelled, returned) }
}
