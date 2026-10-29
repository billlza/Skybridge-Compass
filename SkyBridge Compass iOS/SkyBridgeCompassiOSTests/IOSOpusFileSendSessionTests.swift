import XCTest
import CryptoKit
import CoreBluetooth
import Foundation
import SwiftUI
import UIKit
import SkyBridgeOpus
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport
@testable import SkyBridgeCompass_iOS

/// Real selected-file reads, native conversion/Opus, MAIN envelopes, child
/// handshake/AEAD and Foundation stream workers. Output acknowledgements are
/// controlled: these tests do not claim radio, speaker or background acceptance.
@MainActor
final class IOSOpusFileSendSessionTests: XCTestCase {
    func testNativePairingFailureRemainsTransportFailureAndClosesResources() async throws {
        try await withFixture { f in
            f.connectFailure = BluetoothAudioNativeFailure(operation: .readPSM,
                underlying: NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientEncryption.rawValue))
            let sender = try f.start()
            try await f.failure(.sessionReplaced)
            let failure = try XCTUnwrap(sender.failure)
            XCTAssertTrue(failure.isNativeBluetoothFailure)
            let native = try XCTUnwrap(failure.underlying as? BluetoothAudioNativeFailure)
            XCTAssertEqual(native.diagnosticLabel, "native.read_psm.bluetooth.att.15")
            XCTAssertEqual(f.link?.receivedPackets, 0)
            try await f.assertClosed()
        }
    }

    func testNativeCallbackFailuresKeepTheirTransportCategory() async throws {
        for operation in BluetoothAudioNativeFailure.Operation.allCases {
            try await withFixture { f in
                f.connectFailure = BluetoothAudioNativeFailure(operation: operation,
                    underlying: NSError(domain: CBErrorDomain, code: CBError.unknown.rawValue))
                let sender = try f.start()
                try await f.failure(.sessionReplaced)
                XCTAssertEqual(sender.failure?.isNativeBluetoothFailure, true)
                try await f.assertClosed()
            }
        }
        let sourceFailure = IOSOpusFileSendFailure(reason: .sourceFailed,
            underlying: IOSOpusFileSourceError.queueCapacity, cleanupFailures: [])
        XCTAssertFalse(sourceFailure.isNativeBluetoothFailure)
    }

    func testQualificationOptionsStayWithinFiniteExistingProfiles() throws {
        var environment = [
            "SKYBRIDGE_AUDIO_SMOKE_RUN_ID": "00000000-0000-4000-8000-000000000001",
            "SKYBRIDGE_AUDIO_SMOKE_TARGET_DEVICE_ID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            "SKYBRIDGE_AUDIO_SMOKE_TARGET_FINGERPRINT": String(repeating: "a", count: 64)
        ]
        let defaults = try LocalAudioFileSmokeHarness.Configuration(environment: environment)
        XCTAssertEqual(defaults.bluetoothSeconds, 1); XCTAssertEqual(defaults.bluetoothBitrate, 128_000)
        environment["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_SECONDS"] = "60"
        environment["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_BITRATE"] = "192000"
        let selected = try LocalAudioFileSmokeHarness.Configuration(environment: environment)
        XCTAssertEqual(selected.bluetoothSeconds, 60); XCTAssertEqual(selected.bluetoothBitrate, 192_000)
        environment["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_SECONDS"] = "600"
        XCTAssertEqual(try LocalAudioFileSmokeHarness.Configuration(environment: environment).bluetoothSeconds, 600)
        for value in ["0", "601", "060", "-1", "60.0"] {
            var invalid = environment; invalid["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_SECONDS"] = value
            XCTAssertThrowsError(try LocalAudioFileSmokeHarness.Configuration(environment: invalid))
        }
        for value in ["0", "64000", "128001", "4294967296", "0128000"] {
            var invalid = environment; invalid["SKYBRIDGE_AUDIO_SMOKE_BLUETOOTH_BITRATE"] = value
            XCTAssertThrowsError(try LocalAudioFileSmokeHarness.Configuration(environment: invalid))
        }
    }

    func testCreditTimingRetainsWaitWhenTimeoutCancelsTheSender() async throws {
        try await withFixture { f in
            f.sendCredits = false
            var options = IOSOpusFileSendSession.Options()
            options.recordsTiming = true
            options.creditTimeout = .milliseconds(250)
            let sender = try f.start(options: options)
            try await f.failure(.timedOut)
            XCTAssertEqual(sender.timing.credit.count, 1)
            XCTAssertGreaterThan(sender.timing.credit.total, .zero)
            XCTAssertEqual(f.link?.receivedPackets, 16)
            try await f.assertClosed()
        }
    }

    func testSustainedQualificationFixtureMatchesNativeFailureInput() throws {
        XCTAssertEqual(try LocalAudioFileSmokeHarness.bluetoothSampleWave(seconds: 1), LocalAudioFileSmokeHarness.sampleWave())
        let data = try LocalAudioFileSmokeHarness.bluetoothSampleWave(seconds: 60)
        XCTAssertEqual(data.count, 17_280_068)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "b48648bef1923bb420285483e2b710ef3adacd0fc39aef77d3b26ca29be7b452")
        for invalid in [0, -1, 2, 601] {
            XCTAssertThrowsError(try LocalAudioFileSmokeHarness.bluetoothSampleWave(seconds: invalid))
        }
    }

    func testEagerEndAfterValidatedPlaybackReceiptDoesNotReplaceSuccess() async throws {
        try await withFixture { f in
            f.endAfterPlayback = true
            let sender = try f.start()
            let receipt = try await f.result()
            XCTAssertEqual(receipt.sourceFrames, 48_000)
            XCTAssertEqual(sender.phase, .completed)
            XCTAssertEqual(f.link?.readsAfterTerminal, 0, "The final validated receipt ends the media reader")
            try await f.assertClosed()
        }
    }

    func testEndBeforePlaybackReceiptRemainsFailureAfterContentVerification() async throws {
        try await withFixture { f in
            f.endAfterContent = true
            _ = try f.start()
            try await f.failure(.sessionReplaced)
            XCTAssertEqual(f.link?.readsAfterTerminal, 1)
            try await f.assertClosed()
        }
    }

    func testLeaseRenewalStartsAfterOutputReadinessAndKeepsTheSameEffectLease() async throws {
        try await withFixture { f in
            let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: AccountAudioAuthorization())
            f.membership = membership; f.holdOutput = true
            let sender = try f.start()
            try await until { f.link?.acceptWritten == true }
            XCTAssertEqual(membership.renewalCalls, 0)
            let lease = try XCTUnwrap(f.lease), oldID = lease.evidence.id
            try XCTUnwrap(f.link).holdOutput = false
            _ = try await f.result()
            XCTAssertEqual(membership.renewalCalls, 1)
            XCTAssertTrue(f.lease === lease)
            XCTAssertNotEqual(lease.evidence.id, oldID)
            XCTAssertEqual(sender.phase, .completed)
            try await f.assertClosed()
        }
    }

    func testStopClosesFileAndBluetoothBeforeJoiningDelayedRenewal() async throws {
        try await withFixture { f in
            let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: AccountAudioAuthorization())
            let gate = IOSPlaybackRenewalGate(); membership.renewalGate = gate; f.membership = membership
            f.sendCredits = false
            defer { gate.finish() }
            let sender = try f.start()
            try await until { gate.arrived }
            sender.stop()
            try await until { gate.cancelled && f.link?.closed == true && !f.channel.isCurrentForMembership() }
            let state = await sender.source.snapshot()
            XCTAssertTrue(state.resourcesReleased); XCTAssertFalse(f.finished)
            gate.finish()
            try await f.failure(.userStopped)
            try await f.assertClosed()
        }
    }

    func testFileReachesVerifiedDecodeAndBothReceiptsThroughAuthenticatedChild() async throws {
        try await withFixture { f in
            let sender = try f.start()
            let receipt = try await f.result()
            let link = try XCTUnwrap(f.link)
            XCTAssertEqual(receipt.sourceFrames, 48_000)
            XCTAssertEqual(link.decodedFrames, 48_000)
            XCTAssertEqual(receipt.originalFormat.declaredValidBits, 24)
            XCTAssertEqual(receipt.transmittedFormat.bitrate, 128_000)
            XCTAssertEqual(receipt.buffering, .legacy)
            XCTAssertEqual(receipt.encodedBytes, receipt.packetCount * 320)
            XCTAssertEqual(receipt.sha256, Data(SHA256.hash(data: link.compressed)))
            XCTAssertEqual(sender.phase, .completed)
            XCTAssertNotNil(sender.receipt)
            XCTAssertEqual(sender.workProgress.totalPackets, receipt.packetCount)
            XCTAssertEqual(sender.workProgress.sentPackets, receipt.packetCount)
            XCTAssertEqual(sender.workProgress.retiredPackets, receipt.packetCount)
            XCTAssertEqual(sender.workProgress.phase, .completed)
            XCTAssertEqual(f.mainMessages.count, 1)
            guard case .opusOffer = f.mainMessages.first?.body else { return XCTFail("Media leaked onto MAIN") }
            try await f.assertClosed()
        }
    }

    func testBufferedCapabilitySelectsBoundOfferAndKeepsExactReceipts() async throws {
        try await withFixture(buffered: true) { f in
            f.endAfterPlayback = true
            let sender = try f.start(), receipt = try await f.result()
            let link = try XCTUnwrap(f.link)
            XCTAssertEqual(receipt.buffering, .bufferedFile)
            XCTAssertEqual(receipt.originalFormat.declaredValidBits, 24)
            XCTAssertEqual(receipt.transmittedFormat.bitrate, 128_000)
            XCTAssertEqual(receipt.sourceFrames, 48_000)
            XCTAssertEqual(link.decodedFrames, receipt.sourceFrames)
            XCTAssertEqual(receipt.encodedBytes, receipt.packetCount * 320)
            XCTAssertEqual(receipt.sha256, Data(SHA256.hash(data: link.compressed)))
            XCTAssertEqual(f.mainMessages.count, 1)
            guard case .bufferedOpusFileOffer = f.mainMessages.first?.body else { return XCTFail("Buffered offer was not selected") }
            XCTAssertEqual(sender.phase, .completed)
            XCTAssertEqual(link.readsAfterTerminal, 0)
            try await f.assertClosed()
        }
    }

    func testBufferedSenderStopsAtSixtyFourPacketsWithoutPlayedCredit() async throws {
        try await withFixture(buffered: true, seconds: 60) { f in
            f.sendCredits = false
            var options = IOSOpusFileSendSession.Options(); options.creditTimeout = .milliseconds(250)
            _ = try f.start(options: options)
            try await f.failure(.timedOut)
            XCTAssertEqual(f.link?.receivedPackets, 64)
            XCTAssertFalse(f.link?.endReceived ?? true)
            try await f.assertClosed()
        }
    }

    func testBufferedOfferRejectsLegacyAcceptBeforeSourceEncoding() async throws {
        try await withFixture(buffered: true) { f in
            f.acceptWindowPackets = 16
            let sender = try f.start()
            try await f.failure(.protocolViolation)
            let state = await sender.source.snapshot()
            XCTAssertEqual(state.sourceFramesRead, 0)
            XCTAssertEqual(f.link?.receivedPackets, 0)
            try await f.assertClosed()
        }
    }

    func testBufferedFutureCreditFailsAndCannotTriggerEnd() async throws {
        try await withFixture(buffered: true, seconds: 60) { f in
            f.invalidCredit = true; _ = try f.start()
            try await f.failure(.protocolViolation)
            XCTAssertFalse(f.link?.endReceived ?? true)
            try await f.assertClosed()
        }
    }

    func testAcceptanceWithoutOutputReadinessDoesNotReadOrEncodePCM() async throws {
        try await withFixture { f in
            f.holdOutput = true
            let sender = try f.start()
            try await until { f.link?.acceptWritten == true }
            try await Task.sleep(for: .milliseconds(80))
            let state = await sender.source.snapshot()
            XCTAssertEqual(state.sourceFramesRead, 0); XCTAssertEqual(state.returnedPackets, 0)
            XCTAssertEqual(f.link?.receivedPackets, 0)
            sender.stop()
            try await f.failure(.userStopped); try await f.assertClosed()
        }
    }

    func testNoCreditLimitsNativeDeliveryToSixteenPacketsAndTimesOut() async throws {
        try await withFixture { f in
            f.sendCredits = false
            var options = IOSOpusFileSendSession.Options(); options.creditTimeout = .milliseconds(250)
            _ = try f.start(options: options)
            try await f.failure(.timedOut)
            XCTAssertEqual(f.link?.receivedPackets, 16)
            XCTAssertFalse(f.link?.endReceived ?? true)
            try await f.assertClosed()
        }
    }

    func testFuturePacketCreditIsRejectedWithoutEndOrReceipt() async throws {
        try await withFixture { f in
            f.invalidCredit = true; _ = try f.start()
            try await f.failure(.protocolViolation)
            XCTAssertFalse(f.link?.endReceived ?? true)
            try await f.assertClosed()
        }
    }

    func testWrongCompressedContentReceiptFailsAfterRealFileEncoding() async throws {
        try await withFixture { f in
            f.badDigest = true; _ = try f.start()
            try await f.failure(.contentMismatch)
            XCTAssertTrue(f.link?.endReceived ?? false)
            try await f.assertClosed()
        }
    }

    func testPlaybackCompletionBeforeContentVerificationCannotSucceed() async throws {
        try await withFixture { f in
            f.prematurePlayback = true; _ = try f.start()
            try await f.failure(.protocolViolation)
            try await f.assertClosed()
        }
    }

    func testEndSendFailureCannotBeHiddenByEarlyPeerCompletion() async throws {
        try await withFixture { f in
            f.endWriteFailure = true; _ = try f.start()
            try await f.failure(.sourceFailed)
            XCTAssertTrue(f.link?.peerReceiptWritten ?? false)
            try await f.assertClosed()
        }
    }

    func testReceiverDeclineClosesFileWithoutCreatingBluetoothLink() async throws {
        try await withFixture { f in
            f.frames.reply = { offer in
                XCTAssertEqual(try f.session.receive(.init(streamID: offer.streamID, body: .stop(.receiverDeclined))), .delivered)
            }
            _ = try f.start()
            try await f.failure(.receiverDeclined)
            XCTAssertNil(f.link)
            try await f.assertClosed()
        }
    }

    func testAccountRevocationStopsAWindowBlockedFileAndClosesTheSameOwners() async throws {
        try await withFixture { f in
            f.sendCredits = false
            let sender = try f.start()
            try await until { f.link?.receivedPackets == 16 }
            try XCTUnwrap(f.lease).revoke()
            try await f.failure(.accountRevoked)
            XCTAssertEqual(f.link?.receivedPackets, 16)
            XCTAssertThrowsError(try sender.source.requireEffectCurrent())
            try await f.assertClosed()
        }
    }

    func testMainReplacementWhileAwaitingOutputStopsTheExactChild() async throws {
        try await withFixture { f in
            f.holdOutput = true; _ = try f.start()
            try await until { f.link?.acceptWritten == true }
            f.session.invalidate()
            try await f.failure(.sessionReplaced)
            try await f.assertClosed()
        }
    }

    func testWrongOwnerLeaseDoesNotPublishOfferOrCreateRadioOwner() async throws {
        try await withFixture { f in
            f.wrongLeaseOwner = true; _ = try f.start()
            try await f.failure(.accountRevoked)
            XCTAssertNil(f.link); XCTAssertTrue(f.mainMessages.isEmpty)
            try await f.assertClosed()
        }
    }

    func testCleanupFailureRetainsLinkUntilAnExplicitRetry() async throws {
        try await withFixture { f in
            f.closeFailures = 1
            let sender = try f.start()
            try await f.failure(.sourceFailed)
            XCTAssertTrue(sender.cleanupPending); XCTAssertNil(sender.receipt)
            XCTAssertEqual(f.link?.closeAttempts, 1)
            try await sender.retryCleanup()
            XCTAssertFalse(sender.cleanupPending); XCTAssertEqual(f.link?.closeAttempts, 2)
            XCTAssertEqual(sender.phase, .failed); XCTAssertNil(sender.receipt)
            try await f.assertClosed()
        }
    }

    func testOwnedBackgroundTaskKeepsBluetoothFileAndRequiresItsFinalReceipt() async throws {
        try await withFixture { f in
            f.holdOutput = true
            let scheduler = ControlledAudioBackgroundScheduler()
            let background = try IOSAudioBackgroundExecution(
                identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Bluetooth file fixture", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background },
                makeBluetoothSession: { _, _ in try f.makeSender() })
            let target = IOSAudioPlaybackTarget(deviceID: "fixture", name: "Desktop", identity: f.channel.remoteIdentity,
                sources: [.bluetoothFile])
            try service.startBluetoothFile(url: f.url, target: target, openChannel: { f.channel })
            service.didEnterBackground()
            do {
                try await until { scheduler.submitting || !service.isRunning }
                XCTAssertTrue(scheduler.submitting, "A selected Bluetooth file must request its owned background task before sending")
                guard scheduler.submitting else {
                    await service.stopAndWait(); try await f.assertClosed(); return
                }
                let handle = scheduler.launch()
                try await until { f.link?.acceptWritten == true }
                XCTAssertTrue(service.isRunning)
                XCTAssertEqual(service.backgroundState, .active)
                XCTAssertTrue(handle.completions.isEmpty)
                XCTAssertNil(service.bluetoothOperation?.receipt)
                try XCTUnwrap(f.link).holdOutput = false
                try await until { !service.isRunning }
                XCTAssertEqual(service.bluetoothOperation?.phase, .completed)
                XCTAssertNotNil(service.bluetoothOperation?.receipt)
                XCTAssertEqual(handle.completions, [true])
                XCTAssertEqual(service.backgroundState, .finished)
                try await f.assertClosed()
            } catch {
                await service.stopAndWait()
                throw error
            }
        }
    }

    func testBackgroundExpirationStopsBluetoothAndClosesItsExactResources() async throws {
        try await withFixture { f in
            f.holdOutput = true
            let scheduler = ControlledAudioBackgroundScheduler()
            let background = try IOSAudioBackgroundExecution(
                identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Bluetooth expiration fixture", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background },
                makeBluetoothSession: { _, _ in try f.makeSender() })
            let target = IOSAudioPlaybackTarget(deviceID: "fixture", name: "Desktop", identity: f.channel.remoteIdentity,
                sources: [.bluetoothFile])
            try service.startBluetoothFile(url: f.url, target: target, openChannel: { f.channel })
            do {
                try await until { scheduler.submitting }; let handle = scheduler.launch()
                try await until { f.link?.acceptWritten == true }
                service.didEnterBackground(); handle.expire()
                try await until { !service.isRunning }
                XCTAssertEqual(service.backgroundFailure as? IOSAudioBackgroundError, .expired)
                XCTAssertEqual(handle.completions, [false])
                XCTAssertNil(service.bluetoothOperation?.receipt)
                XCTAssertFalse(service.isPresentationLocked)
                try await f.assertClosed()
            } catch { await service.stopAndWait(); throw error }
        }
    }

    func testRejectedBluetoothBackgroundTaskCannotSendAnOfferOrOpenRadio() async throws {
        try await withFixture { f in
            let scheduler = ControlledAudioBackgroundScheduler(); scheduler.submissionError = .registrationRejected
            let background = try IOSAudioBackgroundExecution(
                identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Bluetooth rejected fixture", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background },
                makeBluetoothSession: { _, _ in try f.makeSender() })
            let target = IOSAudioPlaybackTarget(deviceID: "fixture", name: "Desktop", identity: f.channel.remoteIdentity,
                sources: [.bluetoothFile])
            try service.startBluetoothFile(url: f.url, target: target, openChannel: { f.channel })
            do {
                try await until { !service.isRunning }
                XCTAssertTrue(scheduler.submitting)
                XCTAssertEqual(service.backgroundFailure as? IOSAudioBackgroundError, .registrationRejected)
                XCTAssertTrue(f.mainMessages.isEmpty); XCTAssertNil(f.link)
                XCTAssertNil(service.bluetoothOperation?.receipt)
                try await f.assertClosed()
            } catch { await service.stopAndWait(); throw error }
        }
    }

    func testBluetoothCleanupFailureCannotCompleteTheBackgroundTaskSuccessfully() async throws {
        try await withFixture { f in
            f.closeFailures = 1
            let scheduler = ControlledAudioBackgroundScheduler()
            let background = try IOSAudioBackgroundExecution(
                identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Bluetooth close fixture", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background },
                makeBluetoothSession: { _, _ in try f.makeSender() })
            let target = IOSAudioPlaybackTarget(deviceID: "fixture", name: "Desktop", identity: f.channel.remoteIdentity,
                sources: [.bluetoothFile])
            try service.startBluetoothFile(url: f.url, target: target, openChannel: { f.channel })
            do {
                try await until { scheduler.submitting }; let handle = scheduler.launch()
                try await until { !service.isRunning }
                XCTAssertTrue(service.cleanupPending); XCTAssertTrue(service.isPresentationLocked)
                XCTAssertNil(service.bluetoothOperation?.receipt)
                XCTAssertEqual(handle.completions, [false])
                XCTAssertEqual(service.backgroundState, .failed)
                try await service.retryCleanup()
                XCTAssertFalse(service.cleanupPending); XCTAssertEqual(handle.completions, [false])
                try await f.assertClosed()
            } catch { await service.stopAndWait(); throw error }
        }
    }

    func testServiceWithoutSystemTaskStopsBluetoothWhenEnteringBackground() async throws {
        try await withFixture { f in
            f.holdOutput = true
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { nil },
                makeBluetoothSession: { _, _ in try f.makeSender() })
            let target = IOSAudioPlaybackTarget(deviceID: "fixture", name: "Desktop", identity: f.channel.remoteIdentity,
                sources: [.bluetoothFile])
            try service.startBluetoothFile(url: f.url, target: target, openChannel: { f.channel })
            XCTAssertTrue(service.isPresentationLocked)
            try await until { f.link?.acceptWritten == true }
            service.didEnterBackground()
            try await until { !service.isRunning }
            XCTAssertEqual(service.bluetoothOperation?.failure?.reason, .userStopped)
            XCTAssertNil(service.bluetoothOperation?.receipt)
            XCTAssertFalse(service.isPresentationLocked)
            try await f.assertClosed()
        }
    }

    func testBluetoothReceiptShowsOriginalAndCompressedFormatsInNativePage() async throws {
        try await withFixture { f in
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { nil },
                makeBluetoothSession: { _, _ in try f.makeSender() })
            let target = IOSAudioPlaybackTarget(deviceID: "fixture", name: "Studio Computer", identity: f.channel.remoteIdentity,
                sources: [.originalFile, .systemCapture, .bluetoothFile])
            try service.startBluetoothFile(url: f.url, target: target, openChannel: { f.channel })
            try await until { !service.isRunning }
            XCTAssertNotNil(service.bluetoothOperation?.receipt)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            let view = DeviceAudioPlaybackView(target: target, service: service,
                openChannel: { XCTFail("Rendering opened a second channel"); throw TestFailure.unexpected }, captureAvailability: .available)
            let hosting = UIHostingController(rootView: AnyView(view))
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            try await attachAudioPlaybackSnapshot(window: window, name: "bluetooth-file-receipt-ipad", to: self)
            window.overrideUserInterfaceStyle = .dark
            hosting.rootView = AnyView(view.environment(\.dynamicTypeSize, .accessibility1).frame(width: 390, height: 600))
            try await attachAudioPlaybackSnapshot(window: window, name: "bluetooth-file-compact-large-text", to: self)
            try await attachAudioPlaybackSnapshot(window: window, name: "bluetooth-file-compact-large-text-bottom", scrollToEnd: true, to: self)
            try await f.assertClosed()
        }
    }

    private func withFixture(buffered: Bool = false, seconds: Int = 1,
                             _ body: @MainActor (OpusFileFixture) async throws -> Void) async throws {
        let f = try OpusFileFixture(buffered: buffered, seconds: seconds)
        do { try await body(f); try await f.close() }
        catch {
            let primary = error
            do { try await f.close() } catch { XCTFail("Fixture cleanup failed: \(error)") }
            throw primary
        }
    }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestFailure.deadline }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private enum TestFailure: Error { case deadline, unexpected, injectedClose }

@MainActor
private final class OpusFileFixture {
    let session: IOSAudioSession
    let channel: IOSAudioChannel
    let keys: SkyBridgeCompass_iOS.SessionKeys
    let url: URL
    let frames: OpusMainFrames
    var mainMessages: [AudioStreamingMessage] { frames.messages }
    var link: OpusTestLink?
    var lease: AudioMembershipLease?
    var membership: IOSPlaybackMembershipFixture?
    var sender: IOSOpusFileSendSession?
    var task: Task<IOSOpusFileSendReceipt, Error>?
    var holdOutput = false, sendCredits = true, invalidCredit = false
    var badDigest = false, prematurePlayback = false, wrongLeaseOwner = false, endWriteFailure = false
    var endAfterPlayback = false, endAfterContent = false
    var closeFailures = 0
    var connectFailure: (any Error)?
    var acceptWindowPackets: UInt32?
    var finished = false

    init(buffered: Bool = false, seconds: Int = 1) throws {
        let local = try ProtocolIdentityBinding(deviceId: "opus-ios-fixture", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x19, count: 32))
        let keys = SkyBridgeCompass_iOS.SessionKeys(sendKey: Data(repeating: 0x21, count: 32),
            receiveKey: Data(repeating: 0x43, count: 32), negotiatedSuite: .qperiaptABI2PolicyBound,
            role: .initiator, transcriptHash: Data(repeating: 0x65, count: 32))
        self.keys = keys
        let generation = UUID(), frames = OpusMainFrames(keys: keys); self.frames = frames
        let peer = IOSAudioPeerSnapshot(generation: generation, sessionID: keys.sessionId,
            identity: try AudioProtocolIdentity(deviceID: "opus-desktop-fixture", algorithm: .ed25519,
                fingerprint: String(repeating: "ab", count: 32)),
            capabilities: Set([AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability] +
                (buffered ? [AudioStreamingWire.bufferedOpusFileReceiveCapability] : [])),
            filePort: nil, acceptedMaterialDigest: Data(repeating: 0x34, count: 32))
        session = try IOSAudioSession(generation: generation, keys: keys, localIdentity: local, peer: peer,
            fileRoute: nil, requireConnection: {}, sendFrame: { data, completion in frames.receive(data, completion) },
            cancelTransport: { XCTFail("Audio must not cancel the shared MAIN socket") })
        channel = try session.open(requiringFingerprint: peer.identity.fingerprint)
        url = FileManager.default.temporaryDirectory.appendingPathComponent("opus-session-\(UUID()).wav")
        try LocalAudioFileSmokeHarness.bluetoothSampleWave(seconds: seconds).write(to: url, options: .withoutOverwriting)
        frames.reply = { [weak self] offer in
            guard let self else { throw TestFailure.unexpected }
            let route = try AudioBluetoothRoute(serviceID: UUID(), publicationID: UUID(), psm: 0x81)
            XCTAssertEqual(try session.receive(.init(streamID: offer.streamID, body: .bluetoothRoute(route))), .delivered)
        }
    }
    func makeSender(options: IOSOpusFileSendSession.Options = .init()) throws -> IOSOpusFileSendSession {
        let value = try IOSOpusFileSendSession(url: url, channel: channel, renewMembership: membership?.renew, options: options,
            authorize: { [self] channel in
                let value: AudioMembershipLease
                if let membership { value = try await membership.authorize(channel) }
                else { value = try makeControlledAudioMembershipLease(channel: channel, ownerID: wrongLeaseOwner ? UUID() : nil) }
                lease = value; return value
            }, makeLink: { [self] attachment, effect in
                let value = try OpusTestLink(attachment: attachment, keys: keys, effect: effect,
                    holdOutput: holdOutput, sendCredits: sendCredits, invalidCredit: invalidCredit,
                    badDigest: badDigest, prematurePlayback: prematurePlayback, closeFailures: closeFailures,
                    endWriteFailure: endWriteFailure)
                value.endAfterPlayback = endAfterPlayback; value.endAfterContent = endAfterContent
                value.acceptWindowPackets = acceptWindowPackets
                value.connectFailure = connectFailure
                link = value; return value
            })
        sender = value; return value
    }
    func start(options: IOSOpusFileSendSession.Options = .init()) throws -> IOSOpusFileSendSession {
        let value = try makeSender(options: options)
        task = Task { [self] in defer { finished = true }; return try await value.run() }; return value
    }
    func result() async throws -> IOSOpusFileSendReceipt { try await XCTUnwrap(task).value }
    func failure(_ reason: AudioStreamingStopReason) async throws {
        do { _ = try await result(); XCTFail("Expected failure \(reason)") }
        catch let value as IOSOpusFileSendFailure { XCTAssertEqual(value.reason, reason, "\(value)") }
        XCTAssertEqual(sender?.phase, .failed); XCTAssertNil(sender?.receipt)
    }
    func assertClosed() async throws {
        let sender = try XCTUnwrap(sender), state = await sender.source.snapshot()
        XCTAssertTrue(state.resourcesReleased); XCTAssertFalse(state.cleanupPending)
        XCTAssertFalse(sender.cleanupPending)
        if let link { XCTAssertTrue(link.closed) }
        XCTAssertThrowsError(try channel.requireCurrent())
    }
    func close() async throws {
        membership?.renewalGate?.finish()
        sender?.stop(); task?.cancel()
        if let task { _ = await task.result }
        if let sender { try await sender.source.close() }
        if let link { link.closeFailures = 0; try await link.closeAndAwait() }
        channel.close(); session.invalidate()
        frames.reply = nil; sender = nil; task = nil; link = nil
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor
private final class OpusMainFrames {
    let keys: SkyBridgeCompass_iOS.SessionKeys
    var messages: [AudioStreamingMessage] = []
    var reply: (@MainActor (AudioStreamingMessage) throws -> Void)?
    init(keys: SkyBridgeCompass_iOS.SessionKeys) { self.keys = keys }
    func receive(_ frame: Data, _ completion: AudioStreamingSendCompletion) {
        do {
            let ciphertext = try SkyBridgeCompass_iOS.TrafficPadding.unwrapIfNeeded(Data(frame.dropFirst(4)),
                label: "opus-file-test", maximumOutputByteCount: P2PControlFramePolicy.maximumBodyByteCount)
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: keys.sendKey))
            let message = try XCTUnwrap(AudioStreamingLANEnvelope.decodeIfPresent(plaintext))
            messages.append(message)
            completion.completeWrite(.success(()))
            if message.body.opusOfferParameters != nil { try reply?(message) }
        } catch { completion.completeWrite(.failure(error)); XCTFail("MAIN fixture failed: \(error)") }
    }
}

@MainActor
private final class OpusTestLink: IOSBluetoothAudioSendLink {
    let binding: AudioBluetoothBinding
    let source: BluetoothAudioChannel, sink: BluetoothAudioChannel
    let effect: @Sendable () throws -> Void
    var holdOutput: Bool
    let sendCredits: Bool, invalidCredit: Bool, badDigest: Bool, prematurePlayback: Bool, endWriteFailure: Bool
    var closeFailures: Int
    var closeAttempts = 0, receivedPackets: UInt64 = 0, decodedFrames: UInt64 = 0
    var compressed = Data(), acceptWritten = false, endReceived = false, closed = false, peerReceiptWritten = false
    var endAfterPlayback = false, endAfterContent = false, terminalDelivered = false
    var readsAfterTerminal = 0
    var acceptWindowPackets: UInt32?
    var peer: Task<Void, Error>?
    var connectFailure: (any Error)?
    init(attachment: AudioBluetoothAttachment, keys: SkyBridgeCompass_iOS.SessionKeys,
         effect: @escaping @Sendable () throws -> Void, holdOutput: Bool, sendCredits: Bool,
         invalidCredit: Bool, badDigest: Bool, prematurePlayback: Bool, closeFailures: Int, endWriteFailure: Bool) throws {
        binding = attachment.binding; self.effect = effect; self.holdOutput = holdOutput
        self.sendCredits = sendCredits; self.invalidCredit = invalidCredit; self.badDigest = badDigest
        self.prematurePlayback = prematurePlayback; self.closeFailures = closeFailures
        self.endWriteFailure = endWriteFailure
        var negotiation = AudioBluetoothNegotiation(role: .sink, streamID: binding.offer.streamID)
        try negotiation.receive(binding.offer); try negotiation.prepareSend(binding.route); try negotiation.commitSend(binding.route)
        let sinkBinding = try negotiation.takeBinding()
        let secret = try AudioBluetoothAttachmentSecret(binding: sinkBinding, sendKey: keys.receiveKey,
            receiveKey: keys.sendKey, transcriptHash: keys.transcriptHash, suite: keys.negotiatedSuite.wireId)
        let sinkAttachment = AudioBluetoothAttachment(binding: sinkBinding, secret: secret, requireParentCurrent: effect)
        var i1: InputStream?, o1: OutputStream?, i2: InputStream?, o2: OutputStream?
        Stream.getBoundStreams(withBufferSize: 8192, inputStream: &i1, outputStream: &o1)
        Stream.getBoundStreams(withBufferSize: 8192, inputStream: &i2, outputStream: &o2)
        source = BluetoothAudioChannel(transport: BluetoothControlFrameTransport(input: try XCTUnwrap(i1), output: try XCTUnwrap(o2)), attachment: attachment)
        sink = BluetoothAudioChannel(transport: BluetoothControlFrameTransport(input: try XCTUnwrap(i2), output: try XCTUnwrap(o1)), attachment: sinkAttachment)
    }
    func connect() async throws {
        if let connectFailure { throw connectFailure }
        async let a: Void = source.authenticate(requireEffectAuthorization: effect)
        async let b: Void = sink.authenticate(requireEffectAuthorization: effect)
        _ = try await (a, b)
        peer = Task { try await driveReceiver() }
    }
    func send(_ message: AudioStreamingMessage, authorize: @escaping @Sendable () throws -> Void) async throws {
        try await source.send(message, requireEffectAuthorization: authorize)
        if case .opusEnd = message.body, endWriteFailure {
            try await until { self.peerReceiptWritten }
            throw TestFailure.unexpected
        }
    }
    func receive(authorize: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage {
        // A receiver can close immediately after writing the terminal control.
        // Make EOF already available to the next receive, without a scheduler delay.
        if terminalDelivered { readsAfterTerminal += 1; throw BluetoothControlStreamError.unexpectedEnd }
        let message = try await source.receive(timeout: .seconds(3), requireEffectAuthorization: authorize)
        switch message.body {
        case .playbackComplete where endAfterPlayback: terminalDelivered = true
        case .contentVerified where endAfterContent: terminalDelivered = true
        default: break
        }
        return message
    }
    func closeAndAwait() async throws {
        closeAttempts += 1
        if closeFailures > 0 { closeFailures -= 1; throw TestFailure.injectedClose }
        peer?.cancel()
        try await source.closeAndAwait(); try await sink.closeAndAwait()
        if let peer { _ = await peer.result }; peer = nil; closed = true
    }
    private func reply(_ body: AudioStreamingMessage.Body) async throws {
        try await sink.send(.init(streamID: binding.offer.streamID, body: body), requireEffectAuthorization: effect)
    }
    private func driveReceiver() async throws {
        guard let parameters = binding.offer.body.opusOfferParameters else { throw TestFailure.unexpected }
        let profile = parameters.format, windowPackets = parameters.buffering.windowPackets
        try await reply(.accept(receiveWindowBytes: (acceptWindowPackets ?? windowPackets) * profile.packetBytes)); acceptWritten = true
        while holdOutput { try await Task.sleep(for: .milliseconds(5)) }
        try await reply(.opusOutputReady)
        let config = try await sink.receive(requireEffectAuthorization: effect)
        guard case .opusConfiguration(let skip) = config.body else { throw TestFailure.unexpected }
        let decoder = try SkyBridgeOpusStreamDecoder(format: .init(channels: Int(profile.channels), bitrate: Int(profile.bitrate), preSkipFrames: Int(skip)))
        while true {
            let message = try await sink.receive(requireEffectAuthorization: effect)
            switch message.body {
            case .opusData(let sequence, let data):
                XCTAssertEqual(sequence, receivedPackets)
                if let chunk = try decoder.append(packet: data, sequence: sequence) { decodedFrames += UInt64(chunk.frameCount) }
                receivedPackets += 1; compressed.append(data)
                // Exceeds every legal pre-credit send under the negotiated window,
                // including an additional packet in flight before this reply is read.
                if invalidCredit { try await reply(.credit(retiredBytes: UInt64(windowPackets + 1) * UInt64(profile.packetBytes))); return }
                if sendCredits { try await reply(.credit(retiredBytes: UInt64(compressed.count))) }
            case .opusEnd(let frames, let count, let total, let hash):
                endReceived = true
                XCTAssertEqual(count, receivedPackets); XCTAssertEqual(total, UInt64(compressed.count))
                XCTAssertEqual(hash, Data(SHA256.hash(data: compressed)))
                let completion = try decoder.finish(expectedPCMFrames: frames)
                decodedFrames += UInt64(completion.finalChunk.frameCount)
                if prematurePlayback { try await reply(.playbackComplete(sourceFrames: frames, trailingPaddingFrames: 0)); return }
                try await reply(.contentVerified(totalBytes: total, sha256: badDigest ? Data(repeating: 0xEE, count: 32) : hash))
                if !badDigest {
                    try await reply(.playbackComplete(sourceFrames: frames, trailingPaddingFrames: 0))
                    peerReceiptWritten = true
                }
                return
            default: throw TestFailure.unexpected
            }
        }
    }
}
