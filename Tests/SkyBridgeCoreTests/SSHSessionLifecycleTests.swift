import Foundation
import XCTest
@testable import SkyBridgeCore

@MainActor
final class SSHSessionLifecycleTests: XCTestCase {
    func testTerminalOutputRetentionIsBoundedAndKeepsNewestOutput() {
        var history = SSHTerminalOutputHistory(
            maximumBytes: 128,
            retainedBytesAfterTrim: 64,
            coalescedChunkByteLimit: 32
        )
        for sequence in 1...10 {
            history.append(
                SSHTerminalOutputBatch(
                    generation: 1,
                    sequence: UInt64(sequence),
                    text: String(repeating: Character(String(sequence % 10)), count: 20)
                )
            )
        }

        XCTAssertLessThanOrEqual(history.byteCount, 128)
        XCTAssertTrue(history.didTruncateEarlierOutput)
        XCTAssertTrue(history.snapshot().hasSuffix(String(repeating: "0", count: 20)))
        XCTAssertEqual(history.replay.batches.last?.sequence, 10)
    }

    func testTerminalOutputReplayChunkCountIsBoundedAcrossManyGenerations() {
        var history = SSHTerminalOutputHistory(
            maximumBytes: 4_096,
            retainedBytesAfterTrim: 3_072,
            coalescedChunkByteLimit: 32,
            maximumChunkCount: 8
        )
        for sequence in 1...100 {
            history.append(
                SSHTerminalOutputBatch(
                    generation: UInt64(sequence),
                    sequence: UInt64(sequence),
                    text: "x"
                )
            )
        }

        XCTAssertEqual(history.replay.batches.count, 8)
        XCTAssertEqual(history.replay.batches.first?.sequence, 93)
        XCTAssertEqual(history.replay.batches.last?.sequence, 100)
        XCTAssertTrue(history.didTruncateEarlierOutput)
    }

    func testTerminalOutputBufferCoalescesConcurrentProducersAndCapsPendingBytes() async throws {
        let generation: UInt64 = 41
        let buffer = SSHTerminalOutputBuffer(
            maximumPendingBytes: 128,
            retainedPendingBytesAfterTrim: 64
        )
        buffer.reset(generation: generation)

        let scheduledDrainCount = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<128 {
                group.addTask {
                    buffer.enqueue("chunk-\(index)-xxxxxxxx", generation: generation)
                }
            }

            var count = 0
            for await didScheduleDrain in group where didScheduleDrain {
                count += 1
            }
            return count
        }

        XCTAssertEqual(scheduledDrainCount, 1)
        let firstBatch = try XCTUnwrap(buffer.drain(generation: generation))
        XCTAssertTrue(firstBatch.hasPrefix(SSHTerminalOutputBuffer.truncationMarker))
        XCTAssertLessThanOrEqual(
            firstBatch.utf8.count,
            SSHTerminalOutputBuffer.truncationMarker.utf8.count + 128
        )

        XCTAssertFalse(buffer.enqueue("next", generation: generation))
        XCTAssertFalse(buffer.enqueue("-same-batch", generation: generation))
        XCTAssertTrue(buffer.acknowledgeDelivery(generation: generation))
        XCTAssertEqual(buffer.drain(generation: generation), "next-same-batch")
        XCTAssertFalse(buffer.acknowledgeDelivery(generation: generation))
    }

    func testTerminalOutputBufferRejectsOldGenerationAfterReset() {
        let buffer = SSHTerminalOutputBuffer()
        buffer.reset(generation: 7)
        XCTAssertTrue(buffer.enqueue("old", generation: 7))

        buffer.reset(generation: 8)

        XCTAssertFalse(buffer.enqueue("late-old", generation: 7))
        XCTAssertNil(buffer.drain(generation: 7))
        XCTAssertTrue(buffer.enqueue("current", generation: 8))
        XCTAssertEqual(buffer.drain(generation: 8), "current")
    }

    func testTCPKeepAliveIdlePolicyIsStrictlyBounded() {
        XCTAssertEqual(SSHKeepAlivePolicy.boundedIdleSeconds(.min), 10)
        XCTAssertEqual(SSHKeepAlivePolicy.boundedIdleSeconds(60), 60)
        XCTAssertEqual(SSHKeepAlivePolicy.boundedIdleSeconds(.max), 3_600)
    }

    func testClearedTerminalHistoryDoesNotReappearForReattachedObserver() async throws {
        let session = SSHSession(host: "camera.home", port: 22, username: "viewer")
        _ = session.$outputText
        session.appendTerminalOutputForLifecycleTesting("old-history")
        let sequenceBeforeClear = session.terminalOutputBatch?.sequence

        session.clearTerminalOutputHistory()

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(session.outputText, "")
        XCTAssertTrue(session.terminalOutputReplay.batches.isEmpty)
        XCTAssertFalse(session.terminalOutputReplay.didTruncateEarlierOutput)
        XCTAssertNil(session.terminalOutputBatch)
        XCTAssertTrue(session.terminalPresentationReplay.batches.isEmpty)
        XCTAssertFalse(session.terminalPresentationReplay.didTruncateEarlierOutput)
        XCTAssertNil(session.terminalPresentationBatch)

        session.appendTerminalOutputForLifecycleTesting("new-history")
        try await waitForCompatibilityOutput("new-history", from: session)
        XCTAssertGreaterThan(
            session.terminalOutputBatch?.sequence ?? 0,
            sequenceBeforeClear ?? .max
        )
    }

    func testClearingDesynchronizedTerminalRetainsWarningAndRejectsLaterPayload() throws {
        let session = SSHSession(host: "camera.home", port: 22, username: "viewer")
        session.appendTerminalOutputForLifecycleTesting(
            "unknown-control-payload",
            inputPrefixWasDropped: true
        )
        XCTAssertEqual(
            session.terminalPresentationBatch?.operations,
            [
                .append(
                    SSHTerminalStyledRun(
                        text: SSHTerminalPresentationPipeline.desynchronizationMarker,
                        style: SSHTerminalTextStyle(foregroundColor: .brightYellow)
                    )
                )
            ]
        )

        session.clearTerminalOutputHistory()

        let persistentWarning = try XCTUnwrap(session.terminalPresentationBatch)
        XCTAssertEqual(session.terminalPresentationReplay.batches, [persistentWarning])
        XCTAssertEqual(
            persistentWarning.operations,
            [
                .append(
                    SSHTerminalStyledRun(
                        text: SSHTerminalPresentationPipeline.desynchronizationMarker,
                        style: SSHTerminalTextStyle(foregroundColor: .brightYellow)
                    )
                )
            ]
        )

        session.appendTerminalOutputForLifecycleTesting("must-remain-hidden")

        XCTAssertEqual(session.terminalPresentationBatch, persistentWarning)
        let visiblePresentationText = session.terminalPresentationReplay.batches
            .flatMap(\.operations)
            .compactMap { operation -> String? in
                guard case .append(let run) = operation else { return nil }
                return run.text
            }
            .joined()
        XCTAssertFalse(visiblePresentationText.contains("must-remain-hidden"))
        XCTAssertTrue(
            session.terminalOutputReplay.batches.map(\.text).joined()
                .contains("must-remain-hidden"),
            "Raw compatibility output remains available but must never reach the terminal surface"
        )
    }

    func testCompatibilityOutputPublisherDoesNotStarveDuringContinuousOutput() async throws {
        let session = SSHSession(host: "camera.home", port: 22, username: "viewer")
        var expected = ""
        var publishedWhileProducerWasActive = false

        // A fixed fragment count paced by Task.sleep is unsafe on loaded hosts where
        // sleeps can overshoot by seconds; produce until the publisher observably
        // fires, bounded only by a generous deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var index = 0
        while clock.now < deadline {
            let fragment = "\(index),"
            index += 1
            expected.append(fragment)
            session.appendTerminalOutputForLifecycleTesting(fragment)
            try await Task.sleep(for: .milliseconds(10))
            if !session.outputText.isEmpty {
                publishedWhileProducerWasActive = true
                break
            }
        }

        XCTAssertTrue(
            publishedWhileProducerWasActive,
            "The compatibility output publisher never fired while output was being produced"
        )
        try await waitForCompatibilityOutput(expected, from: session)
    }

    func testCredentialReconnectAndTransportIdentitySourceContract() throws {
        let source = try sshSessionSource()

        XCTAssertTrue(source.contains("enum SSHConnectionCredential: Sendable"))
        XCTAssertTrue(source.contains("enum SSHReconnectCredential: Sendable"))
        XCTAssertTrue(source.contains("case password(String)"))
        XCTAssertTrue(source.contains("case ed25519Raw(Data)"))
        XCTAssertTrue(source.contains("case pem(String)"))
        XCTAssertTrue(source.contains("reconnectCredential = strategy.reconnectCredential"))
        XCTAssertTrue(source.contains("reconnectCredential.connectionCredential"))
        XCTAssertTrue(source.contains(".connectTimeout(.seconds(Int64(connectionTimeoutSeconds)))"))
        XCTAssertTrue(source.contains("let handshakeTimeoutTask = mainChannel.eventLoop.scheduleTask"))
        XCTAssertFalse(source.contains("connect(password: self.password)"))
        XCTAssertFalse(source.contains("private var password:"))
        XCTAssertFalse(source.contains("password: \"\""))

        XCTAssertTrue(source.contains("private var lifecycleGeneration: UInt64"))
        XCTAssertTrue(source.contains("group === expectedGroup"))
        XCTAssertTrue(source.contains("channel !== expectedMainChannel"))
        XCTAssertTrue(source.contains("childChannel !== expectedChildChannel"))
        XCTAssertTrue(source.contains("struct SSHTransportIdentity: Sendable"))
        XCTAssertTrue(source.contains("return identity.matches("))
        XCTAssertTrue(source.contains("cleanupFailedTransportIfCurrent"))
        XCTAssertTrue(source.contains("scheduleReconnect(expectedGeneration:"))
        XCTAssertTrue(source.contains("SO_KEEPALIVE"))
        XCTAssertTrue(source.contains("TCP_KEEPALIVE"))
        XCTAssertFalse(source.contains("scheduleRepeatedTask"))
        XCTAssertFalse(source.contains("buf.writeString(\" \")"))
    }

    func testPlaintextPasswordIsNotRepresentableAsReconnectCredential() {
        XCTAssertNil(SSHConnectionCredential.password("ephemeral-secret").reconnectCredential)

        let keyCredential = SSHConnectionCredential.ed25519Raw(Data([1, 2, 3]))
        guard case .ed25519Raw(let retainedKey)? = keyCredential.reconnectCredential else {
            return XCTFail("Key credentials should remain eligible for explicit reconnect policy")
        }
        XCTAssertEqual(retainedKey, Data([1, 2, 3]))
    }

    func testPortForwardCompletionGateRejectsEveryStaleTransportDimension() {
        let firstGroup = NSObject()
        let secondGroup = NSObject()
        let firstMainChannel = NSObject()
        let secondMainChannel = NSObject()
        let childChannel = NSObject()
        let identity = SSHTransportIdentity(
            generation: 9,
            groupIdentifier: ObjectIdentifier(firstGroup),
            mainChannelIdentifier: ObjectIdentifier(firstMainChannel)
        )

        XCTAssertTrue(
            identity.matches(
                generation: 9,
                groupIdentifier: ObjectIdentifier(firstGroup),
                mainChannelIdentifier: ObjectIdentifier(firstMainChannel),
                childChannelIdentifier: ObjectIdentifier(childChannel)
            )
        )
        XCTAssertFalse(
            identity.matches(
                generation: 10,
                groupIdentifier: ObjectIdentifier(firstGroup),
                mainChannelIdentifier: ObjectIdentifier(firstMainChannel),
                childChannelIdentifier: nil
            ),
            "A direct channel completing after reconnect must be rejected by generation"
        )
        XCTAssertFalse(
            identity.matches(
                generation: 9,
                groupIdentifier: ObjectIdentifier(secondGroup),
                mainChannelIdentifier: ObjectIdentifier(firstMainChannel),
                childChannelIdentifier: nil
            ),
            "A direct channel from a replaced event-loop group must be rejected"
        )
        XCTAssertFalse(
            identity.matches(
                generation: 9,
                groupIdentifier: ObjectIdentifier(firstGroup),
                mainChannelIdentifier: ObjectIdentifier(secondMainChannel),
                childChannelIdentifier: nil
            ),
            "A direct channel from a replaced SSH main channel must be rejected"
        )
    }

    func testTerminalCleanupOwnsEachEventLoopGroupExactlyOnceAndRejectsStaleGeneration() async {
        let shutdownProbe = SSHEventLoopShutdownProbe()
        let session = SSHSession(
            host: "camera.home",
            port: 22,
            username: "viewer",
            eventLoopGroupWillShutdown: {
                shutdownProbe.recordShutdown()
            }
        )

        let firstIdentity = session.installIdleTransportForLifecycleTesting()
        XCTAssertTrue(session.hasInstalledTransportForLifecycleTesting)

        await session.cleanupTerminalTransportForLifecycleTesting(matching: firstIdentity)
        await session.cleanupTerminalTransportForLifecycleTesting(matching: firstIdentity)

        XCTAssertFalse(session.hasInstalledTransportForLifecycleTesting)
        XCTAssertEqual(shutdownProbe.shutdownCount, 1)

        let secondIdentity = session.installIdleTransportForLifecycleTesting()
        await session.cleanupTerminalTransportForLifecycleTesting(matching: firstIdentity)

        XCTAssertTrue(session.hasInstalledTransportForLifecycleTesting)
        XCTAssertEqual(shutdownProbe.shutdownCount, 1)

        await session.cleanupTerminalTransportForLifecycleTesting(matching: secondIdentity)

        XCTAssertFalse(session.hasInstalledTransportForLifecycleTesting)
        XCTAssertEqual(shutdownProbe.shutdownCount, 2)
    }

    func testRAIIFinalizerClaimsAbandonedEventLoopGroupExactlyOnce() async {
        let shutdownProbe = SSHEventLoopShutdownProbe()
        weak var weakSession: SSHSession?
        var session: SSHSession? = SSHSession(
            host: "camera.home",
            port: 22,
            username: "viewer",
            eventLoopGroupWillShutdown: {
                shutdownProbe.recordShutdown()
            }
        )
        weakSession = session
        _ = session?.installIdleTransportForLifecycleTesting()

        session = nil
        for _ in 0..<100 where weakSession != nil || shutdownProbe.shutdownCount == 0 {
            await Task.yield()
        }

        XCTAssertNil(weakSession)
        XCTAssertEqual(shutdownProbe.shutdownCount, 1)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(
            shutdownProbe.shutdownCount,
            1,
            "The finalizer must transfer one exact event-loop group to shutdown once"
        )
    }

    func testTerminalOutputBatchingSourceContract() throws {
        let source = try sshSessionSource()

        XCTAssertTrue(source.contains("final class SSHTerminalOutputBuffer"))
        XCTAssertTrue(source.contains("scheduleTask(in: .milliseconds(16))"))
        XCTAssertTrue(source.contains("onText(buf, context.eventLoop)"))
        XCTAssertTrue(source.contains("terminalOutputHistory.append(outputBatch)"))
        XCTAssertTrue(source.contains("terminalOutputBatch = outputBatch"))
        XCTAssertTrue(source.contains("terminalPresentationHistory.append(presentationBatch)"))
        XCTAssertTrue(source.contains("terminalPresentationBatch = presentationBatch"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(source.contains("inputPrefixWasDropped: drainedOutput.didDropInputPrefix"))
        XCTAssertTrue(source.contains("@Published public private(set) var outputText: String = \"\""))
        XCTAssertTrue(source.contains("scheduleCompatibilityOutputSnapshot()"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(source.contains("guard terminalOutputSnapshotTask == nil"))
        XCTAssertTrue(source.contains("terminalOutputClearEpoch"))
        XCTAssertTrue(source.contains("acknowledgeDelivery("))
        XCTAssertTrue(source.contains("static let maximumBytes = 1_048_576"))
        XCTAssertTrue(source.contains("outputBuffer.enqueue(buffer, generation: generation)"))
        XCTAssertFalse(source.contains("length: buffer.readableBytes"))
        XCTAssertFalse(source.contains("buffer.getString("))
        XCTAssertFalse(source.contains("SSHOutputRetentionPolicy.appending"))
        XCTAssertFalse(source.contains("while pending.first"))
        XCTAssertFalse(source.contains("Task { @MainActor in self.outputText.append"))
        XCTAssertFalse(source.contains("child.eventLoop.scheduleTask"))
        XCTAssertFalse(source.contains("try? await Task.sleep"))
        XCTAssertFalse(source.contains("syncShutdownGracefully"))
        XCTAssertTrue(source.contains("deinit {"))
        XCTAssertTrue(
            source.contains(
                "shutdownGracefully(queue: DispatchQueue.global(qos: .utility))"
            )
        )
    }

    func testDirectChannelAndTerminalHandlerLifecycleSourceContract() throws {
        let source = try sshSessionSource()
        let directAwait = try XCTUnwrap(
            source.range(of: "let directChannel = try await promise.futureResult.get()")
        )
        let staleGate = try XCTUnwrap(
            source.range(
                of: "guard !Task.isCancelled, isCurrentTransport(transportIdentity)",
                range: directAwait.upperBound..<source.endIndex
            )
        )
        let staleClose = try XCTUnwrap(
            source.range(
                of: "directChannel.close(promise: nil)",
                range: staleGate.upperBound..<source.endIndex
            )
        )
        let staleFailure = try XCTUnwrap(
            source.range(
                of: "throw CancellationError()",
                range: staleClose.upperBound..<source.endIndex
            )
        )
        let directReturn = try XCTUnwrap(
            source.range(
                of: "return directChannel",
                range: staleFailure.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(staleGate.lowerBound, staleClose.lowerBound)
        XCTAssertLessThan(staleClose.lowerBound, staleFailure.lowerBound)
        XCTAssertLessThan(staleFailure.lowerBound, directReturn.lowerBound)
        XCTAssertTrue(
            source.contains("createChannel(promise, channelType: .session) { [weak self] child, type in")
        )
        XCTAssertTrue(
            source.contains("SSHTerminalHandler { [weak self] buffer, eventLoop in")
        )
        XCTAssertTrue(source.contains("await cleanupTerminalTransport("))
        XCTAssertTrue(source.contains("shutdownEventLoopGroup("))
    }

    private func sshSessionSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/SSHSession.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func waitForCompatibilityOutput(
        _ expected: String,
        from session: SSHSession
    ) async throws {
        for _ in 0..<100 {
            if session.outputText == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the compatibility output publisher")
    }
}

private final class SSHEventLoopShutdownProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedShutdownCount = 0

    var shutdownCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedShutdownCount
    }

    func recordShutdown() {
        lock.lock()
        recordedShutdownCount += 1
        lock.unlock()
    }
}
