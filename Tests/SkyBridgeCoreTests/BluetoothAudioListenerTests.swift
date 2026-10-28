import CoreBluetooth
import Foundation
import XCTest
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport

@MainActor
final class BluetoothAudioListenerTests: XCTestCase {
    private enum Failure: Error { case revoked, nativeUnpublish, eventTimeout }

    func testRouteIsReturnedOnlyAfterPublicationServiceAndAdvertisingCallbacks() async throws {
        let driver = Driver(); driver.hold = [.publish, .service, .advertise]
        let listener = listener(driver)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let publishing = Task { let route = try await listener.publish(); completed.withLock { $0 = true }; return route }
        try await until { driver.publishCount == 1 }
        XCTAssertFalse(completed.withLock { $0 })
        driver.events?.published(psm: 129, error: nil)
        XCTAssertEqual(driver.added.count, 1); XCTAssertTrue(driver.advertised.isEmpty)
        driver.events?.serviceAdded(error: nil)
        XCTAssertEqual(driver.advertised, driver.added)
        XCTAssertFalse(completed.withLock { $0 })
        driver.completeAdvertising()
        let route = try await publishing.value
        XCTAssertEqual(route.psm, 129); XCTAssertEqual(route.serviceID, driver.advertised.first)
        XCTAssertTrue(completed.withLock { $0 })
        try await listener.closeAndAwait()
        XCTAssertEqual(driver.unpublished, [129]); XCTAssertFalse(driver.isAdvertising); XCTAssertNil(driver.events)
    }

    func testInvalidNativePSMIsStillUnpublishedInsteadOfLeaked() async throws {
        let driver = Driver(); driver.psm = 256
        let listener = listener(driver)
        let error = await failure { try await listener.publish() }
        XCTAssertEqual(error as? AudioBluetoothAttachmentError, .invalidBinding)
        XCTAssertEqual(driver.unpublished, [256]); XCTAssertTrue(driver.added.isEmpty)
        try await listener.closeAndAwait()
    }

    func testLatePublishAfterCancellationIsUnpublishedWithoutAddingService() async throws {
        let driver = Driver(); driver.hold = [.publish]
        let listener = listener(driver)
        let publishing = Task { try await listener.publish() }
        try await until { driver.publishCount == 1 }
        publishing.cancel()
        try await until { driver.stops > 0 }
        XCTAssertTrue(driver.unpublished.isEmpty)
        driver.events?.published(psm: 129, error: nil)
        let error = await failure { try await publishing.value }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(driver.unpublished, [129]); XCTAssertTrue(driver.added.isEmpty)
        try await listener.closeAndAwait()
    }

    func testUnconfirmedLatePublicationKeepsSameOwnerForLaterCleanup() async throws {
        let driver = Driver(); driver.hold = [.publish]
        let listener = listener(driver)
        let publishing = Task { try await listener.publish() }
        try await until { driver.publishCount == 1 }
        publishing.cancel()
        let error = await failure { try await publishing.value }
        if case .cleanupFailed(let primary, let cleanup) = error as? BluetoothAudioListenerError {
            XCTAssertTrue(primary is CancellationError)
            guard case .cleanupUnconfirmed = cleanup as? BluetoothAudioListenerError else { return XCTFail("Missing unconfirmed release") }
        } else { XCTFail("Cleanup timeout was reported as success") }
        XCTAssertNotNil(driver.events)
        driver.events?.published(psm: 129, error: nil)
        try await listener.closeAndAwait()
        XCTAssertEqual(driver.unpublished, [129]); XCTAssertNil(driver.events)
    }

    func testUnpublishFailureIsVisibleAndOnlyExplicitRetryReissuesIt() async throws {
        let driver = Driver(); driver.unpublishError = Failure.nativeUnpublish
        let listener = listener(driver)
        _ = try await listener.publish()
        let error = await failure { try await listener.closeAndAwait() }
        XCTAssertTrue(error is Failure)
        XCTAssertEqual(driver.unpublished, [129])
        driver.unpublishError = nil
        try await listener.closeAndAwait()
        XCTAssertEqual(driver.unpublished, [129, 129]); XCTAssertNil(driver.events)
    }

    func testLateServiceAndAdvertisingCallbacksCannotRestoreStoppedPublication() async throws {
        for held: Driver.Step in [.service, .advertise] {
            let driver = Driver(); driver.hold = [held]
            let listener = listener(driver)
            let publishing = Task { try await listener.publish() }
            try await until { held == .service ? !driver.added.isEmpty : !driver.advertised.isEmpty }
            publishing.cancel()
            try await until { driver.stops > 0 }
            if held == .service { driver.events?.serviceAdded(error: nil) }
            else { driver.completeAdvertising() }
            let error = await failure { try await publishing.value }
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(driver.isAdvertising)
            if held == .service { XCTAssertTrue(driver.advertised.isEmpty) }
            XCTAssertEqual(driver.unpublished, [129])
            try await listener.closeAndAwait()
        }
    }

    func testBadNativeCandidateDoesNotConsumeAttachmentAndValidCandidateCarriesMedia() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        let streamID = try f.packet().streamID
        let listener = BluetoothAudioListener(streamID: streamID, requireCurrent: {}, makeDriver: { driver })
        let route = try await listener.publish()
        let sinkOwner = try attachment(f, role: .sink, route: route)
        let accepting = Task { try await listener.accept(sinkOwner) }
        let bad = try pair()
        XCTAssertTrue(driver.events?.mayAccept(psm: 129) == true)
        driver.events?.opened(bad.1, psm: 129)
        try await bad.0.writeFrame(Data([0]), timeout: .seconds(2))
        try await until { bad.1.isClosed }
        let valid = try pair()
        let source = BluetoothAudioChannel(transport: valid.0, attachment: try attachment(f, role: .source, route: route))
        XCTAssertTrue(driver.events?.mayAccept(psm: 129) == true)
        driver.events?.opened(valid.1, psm: 129)
        try await source.authenticate(requireEffectAuthorization: {})
        try await accepting.value
        let sink = try listener.channel
        XCTAssertFalse(driver.events?.mayAccept(psm: 129) == true)
        XCTAssertFalse(driver.isAdvertising)
        XCTAssertTrue(driver.unpublished.isEmpty, "Keep the PSM while the owned child is active")
        async let incoming = sink.receive(requireEffectAuthorization: {})
        try await source.send(f.packet(), requireEffectAuthorization: {})
        let delivered = try await incoming
        XCTAssertEqual(delivered, try f.packet())
        try await listener.closeAndAwait(); try await source.closeAndAwait()
        XCTAssertEqual(driver.unpublished, [129])
    }

    func testForeignRouteCannotTakePendingListener() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        let listener = BluetoothAudioListener(streamID: try f.packet().streamID, requireCurrent: {}, makeDriver: { driver })
        let route = try await listener.publish()
        let wrong = try AudioBluetoothRoute(serviceID: UUID(), publicationID: route.publicationID, psm: route.psm)
        let error = await failure { try await listener.accept(attachment(f, role: .sink, route: wrong)) }
        guard case .invalidAttachment = error as? BluetoothAudioListenerError else { return XCTFail("Foreign route was accepted") }
        XCTAssertTrue(driver.isAdvertising)
        XCTAssertTrue(driver.events?.mayAccept(psm: 129) == true)
        XCTAssertFalse(driver.events?.mayAccept(psm: 130) == true)
        try await listener.closeAndAwait()
    }

    func testCandidateQueueIsBoundedBeforeAllocatingAdditionalWorkers() async throws {
        let driver = Driver()
        let owned = self.listener(driver)
        _ = try await owned.publish()
        for _ in 0..<4 {
            XCTAssertTrue(driver.events?.mayAccept(psm: 129) == true)
            let candidate = try pair()
            driver.events?.opened(candidate.1, psm: 129)
        }
        XCTAssertFalse(driver.events?.mayAccept(psm: 129) == true)
        try await owned.closeAndAwait()
    }

    func testRevocationDuringPublicationStopsBeforeAdvertising() async throws {
        let current = OSAllocatedUnfairLock(initialState: true), driver = Driver()
        driver.hold = [.service]
        let listener = BluetoothAudioListener(streamID: UUID(), requireCurrent: {
            if !current.withLock({ $0 }) { throw Failure.revoked }
        }, makeDriver: { driver })
        let publishing = Task { try await listener.publish() }
        try await until { !driver.added.isEmpty }
        current.withLock { $0 = false }
        driver.events?.serviceAdded(error: nil)
        let error = await failure { try await publishing.value }
        XCTAssertTrue(error is Failure)
        XCTAssertTrue(driver.advertised.isEmpty); XCTAssertEqual(driver.unpublished, [129])
    }

    func testCancelledConcurrentCleanupCallersWaitForSameNativeAcknowledgment() async throws {
        let driver = Driver(); driver.acknowledgeUnpublish = false
        let listener = listener(driver)
        _ = try await listener.publish()
        let completed = OSAllocatedUnfairLock(initialState: 0)
        let first = Task { try await listener.closeAndAwait(); completed.withLock { $0 += 1 } }
        try await until { driver.unpublished.count == 1 }
        let second = Task { try await listener.closeAndAwait(); completed.withLock { $0 += 1 } }
        first.cancel(); second.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(completed.withLock { $0 }, 0)
        driver.events?.unpublished(psm: 129, error: nil)
        try await first.value; try await second.value
        XCTAssertTrue(first.isCancelled); XCTAssertTrue(second.isCancelled)
        XCTAssertEqual(driver.unpublished, [129]); XCTAssertEqual(completed.withLock { $0 }, 2)
    }

    func testCancelledAcceptanceRetiresPendingAttachmentAndPublication() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        let listener = BluetoothAudioListener(streamID: try f.packet().streamID, requireCurrent: {}, makeDriver: { driver })
        let route = try await listener.publish(), owner = try attachment(f, role: .sink, route: route)
        let accepting = Task { try await listener.accept(owner) }
        await Task.yield()
        accepting.cancel()
        let error = await failure { try await accepting.value }
        XCTAssertTrue(error is CancellationError)
        XCTAssertThrowsError(try owner.handshakeRemainingTime())
        XCTAssertEqual(driver.unpublished, [129])
        try await listener.closeAndAwait()
    }

    private func listener(_ driver: Driver) -> BluetoothAudioListener {
        BluetoothAudioListener(streamID: UUID(), requireCurrent: {}, makeDriver: { driver })
    }
    private func attachment(_ f: BluetoothAudioFixture, role: AudioBluetoothRole, route: AudioBluetoothRoute) throws -> AudioBluetoothAttachment {
        let offer = try AudioStreamingWire.decode(f.bytes(f.offer))
        let routeMessage = AudioStreamingMessage(streamID: offer.streamID, body: .bluetoothRoute(route))
        var n = AudioBluetoothNegotiation(role: role, streamID: offer.streamID)
        if role == .source { try n.prepareSend(offer); try n.commitSend(offer); try n.receive(routeMessage) }
        else { try n.receive(offer); try n.prepareSend(routeMessage); try n.commitSend(routeMessage) }
        let binding = try n.takeBinding()
        let secret = try AudioBluetoothAttachmentSecret(binding: binding, sendKey: f.bytes(role == .source ? f.sendKey : f.receiveKey),
            receiveKey: f.bytes(role == .source ? f.receiveKey : f.sendKey), transcriptHash: f.bytes(f.transcriptHash), suite: f.suite)
        return AudioBluetoothAttachment(binding: binding, secret: secret, requireParentCurrent: {})
    }
    private func pair() throws -> (BluetoothControlFrameTransport, BluetoothControlFrameTransport) {
        var forwardIn: InputStream?, forwardOut: OutputStream?, reverseIn: InputStream?, reverseOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 257, inputStream: &forwardIn, outputStream: &forwardOut)
        Stream.getBoundStreams(withBufferSize: 257, inputStream: &reverseIn, outputStream: &reverseOut)
        let left = try BluetoothControlFrameTransport(input: XCTUnwrap(reverseIn), output: XCTUnwrap(forwardOut))
        let right = try BluetoothControlFrameTransport(input: XCTUnwrap(forwardIn), output: XCTUnwrap(reverseOut))
        addTeardownBlock { left.close(); right.close(); try await left.closeAndAwait(); try await right.closeAndAwait() }
        return (left, right)
    }
    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < end else { throw Failure.eventTimeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func failure<T>(_ action: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> (any Error)? {
        do { _ = try await action(); XCTFail("Expected failure", file: file, line: line); return nil }
        catch { return error }
    }

    private final class Driver: BluetoothAudioPublicationDriver {
        enum Step: Hashable { case publish, service, advertise }
        weak var events: (any BluetoothAudioPublicationEvents)?
        var isAdvertising = false
        var hold: Set<Step> = []
        var psm: UInt16 = 129
        var publishCount = 0, stops = 0
        var added: [UUID] = [], advertised: [UUID] = [], unpublished: [UInt16] = []
        var acknowledgeUnpublish = true
        var unpublishError: (any Error)?
        func start() { events?.stateChanged(.poweredOn) }
        func publish() { publishCount += 1; if !hold.contains(.publish) { events?.published(psm: psm, error: nil) } }
        func addService(id: UUID, psm: UInt16) { added.append(id); if !hold.contains(.service) { events?.serviceAdded(error: nil) } }
        func advertise(id: UUID) { advertised.append(id); if !hold.contains(.advertise) { completeAdvertising() } }
        func completeAdvertising() { isAdvertising = true; events?.advertisingStarted(error: nil) }
        func stopAdvertisingAndRemoveServices() { stops += 1; isAdvertising = false }
        func unpublish(psm: UInt16) {
            unpublished.append(psm)
            if acknowledgeUnpublish { events?.unpublished(psm: psm, error: unpublishError) }
        }
    }
}
