import XCTest
import Foundation
import Network
import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

/// Real source ownership and native audio carrier, with controlled Finished,
/// registry and classic receipt inputs. Actual TCP is covered separately.
@MainActor
final class IOSOriginalFileSendSessionTests: XCTestCase {
    func testNativeOutputProgressCannotReplaceFileAndPlaybackReceipts() async throws {
        try await withFixture(supportsOutputProgress: true) { f in
            let sender = f.start()
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.phase == .awaitingOutput }
            try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat)))
            try f.reply(.fileOutputProgress(sourceFrames: 128))
            try await waitUntil { sender.outputSourceFrames == 128 }
            try f.reply(.fileOutputProgress(sourceFrames: 128))
            try f.reply(.fileOutputProgress(sourceFrames: 256))
            try await waitUntil { sender.outputSourceFrames == 256 }
            XCTAssertNil(sender.receipt); XCTAssertFalse(f.finished)
            try f.reply(.playbackComplete(sourceFrames: 256, trailingPaddingFrames: 0))
            let receipt = try await f.result()
            XCTAssertEqual(receipt.sourceFrames, 256); XCTAssertEqual(f.sentBytes, f.wave)
            try await f.assertClosed()
        }
    }

    func testNativeOutputProgressRejectsUnnegotiatedAndPrematureReports() async throws {
        for mode in 0..<3 {
            try await withFixture(supportsOutputProgress: mode != 0) { f in
                let sender = f.start(); try await f.waitForOffer()
                if mode != 1 {
                    try f.reply(.accept(receiveWindowBytes: 0))
                    try await waitUntil { sender.phase == .awaitingOutput }
                }
                if mode == 0 { try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat))) }
                try f.reply(.fileOutputProgress(sourceFrames: 1))
                try await f.expectFailure(.protocolViolation)
                XCTAssertNil(sender.outputSourceFrames)
                try await f.assertClosed()
            }
        }
    }

    func testNativeOutputProgressRejectsRegressingAndBeyondSourceCounters() async throws {
        for invalid in [UInt64(127), UInt64(257)] {
            try await withFixture(supportsOutputProgress: true) { f in
                let sender = f.start(); try await f.waitForOffer()
                try f.reply(.accept(receiveWindowBytes: 0)); try await waitUntil { sender.phase == .awaitingOutput }
                try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat)))
                try f.reply(.fileOutputProgress(sourceFrames: 128))
                try await waitUntil { sender.outputSourceFrames == 128 }
                try f.reply(.fileOutputProgress(sourceFrames: invalid))
                try await f.expectFailure(.protocolViolation)
                XCTAssertEqual(sender.outputSourceFrames, 128)
                try await f.assertClosed()
            }
        }
    }

    func testNativeOutputProgressDoesNotExtendTheCompletionDeadline() async throws {
        try await withFixture(supportsOutputProgress: true) { f in
            let anchor = ContinuousClock.now
            f.clock.withLock { $0.instant = anchor }
            var options = IOSOriginalFileSendSession.Options(); options.completionGrace = .milliseconds(50)
            let sender = f.start(options: options); try await f.waitForOffer()
            try f.reply(.accept(receiveWindowBytes: 0)); try await waitUntil { sender.phase == .awaitingOutput }
            try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat)))
            try await waitUntil { sender.phase == .awaitingPlayback }
            f.clock.withLock { $0.instant = anchor.advanced(by: .milliseconds(40)) }
            try f.reply(.fileOutputProgress(sourceFrames: 128))
            try await waitUntil { sender.outputSourceFrames == 128 }
            f.clock.withLock { $0.instant = anchor.advanced(by: .milliseconds(60)) }
            try await f.expectFailure(.timedOut)
            XCTAssertNil(sender.receipt)
            try await f.assertClosed()
        }
    }

    func testPlaybackRenewsTheSameLeaseOnlyAfterAcceptanceAndKeepsFileBytes() async throws {
        try await withFixture { f in
            let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: f.authorization)
            f.membership = membership
            let sender = f.start()
            try await f.waitForOffer()
            XCTAssertEqual(membership.renewalCalls, 0)
            let oldExpiry = try XCTUnwrap(sender.authorizationExpiresAt)
            let oldID = try XCTUnwrap(membership.lease).evidence.id
            try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.authorizationRenewalState == .waiting && membership.renewalCalls == 1 }
            XCTAssertNotEqual(membership.lease?.evidence.id, oldID)
            XCTAssertGreaterThan(try XCTUnwrap(sender.authorizationExpiresAt), oldExpiry)
            try await waitUntil { sender.phase == .awaitingOutput }
            let format = try XCTUnwrap(sender.sourceFormat)
            try f.reply(.outputReady(format)); try f.reply(.playbackComplete(sourceFrames: 256, trailingPaddingFrames: 0))
            let receipt = try await f.result()
            XCTAssertEqual(receipt.format, format); XCTAssertEqual(f.sentBytes, f.wave)
            XCTAssertEqual(membership.renewalCalls, 1)
            try await f.assertClosed()
        }
    }

    func testStopClosesSourceAndChannelBeforeJoiningAnUncooperativeRenewal() async throws {
        try await withFixture { f in
            let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: f.authorization)
            let gate = IOSPlaybackRenewalGate()
            membership.renewalGate = gate; f.membership = membership
            defer { gate.finish() }
            let sender = f.start()
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { gate.arrived }
            sender.stop()
            try await waitUntil { gate.cancelled && f.connection.isClosed && !f.channel.isCurrentForMembership() }
            let closed = await f.source.isClosed
            XCTAssertTrue(closed); XCTAssertFalse(f.finished)
            gate.finish()
            try await f.expectFailure(.userStopped)
            XCTAssertEqual(membership.renewalCalls, 1); XCTAssertNil(sender.receipt)
            try await f.assertClosed()
        }
    }

    func testUSBQualificationRequiresExactRunAndPublicPeerIdentity() throws {
        let configuration: [String: String] = [
            "SKYBRIDGE_AUDIO_SMOKE_RUN_ID": "00000000-0000-4000-8000-000000000001",
            "SKYBRIDGE_AUDIO_SMOKE_TARGET_DEVICE_ID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            "SKYBRIDGE_AUDIO_SMOKE_TARGET_FINGERPRINT": String(repeating: "a", count: 64)
        ]
        let parsed = try LocalAudioFileSmokeHarness.Configuration(environment: configuration)
        XCTAssertEqual(parsed.basename, "usb-audio-00000000-0000-4000-8000-000000000001")
        for key in configuration.keys {
            var missing = configuration; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try LocalAudioFileSmokeHarness.Configuration(environment: missing))
        }
        for value in ["../sample", "00000000-0000-0000-0000-000000000000"] {
            var invalid = configuration; invalid["SKYBRIDGE_AUDIO_SMOKE_RUN_ID"] = value
            XCTAssertThrowsError(try LocalAudioFileSmokeHarness.Configuration(environment: invalid))
        }
        var invalid = configuration
        invalid["SKYBRIDGE_AUDIO_SMOKE_TARGET_FINGERPRINT"] = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try LocalAudioFileSmokeHarness.Configuration(environment: invalid))
    }

    func testUSBQualificationSampleIsFiniteQuiet24BitPCMWithExplicitStereoLayout() async throws {
        let bytes = LocalAudioFileSmokeHarness.sampleWave()
        XCTAssertEqual(bytes.count, 288_068)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try bytes.write(to: url, options: .withoutOverwriting)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        let source = try IOSPreparedAudioFile(url: url)
        do {
            let prepared = try await source.prepare()
            XCTAssertEqual(prepared.frameCount, 48_000)
            XCTAssertEqual(prepared.format, try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2,
                encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3))
            var peak: Int32 = 0
            for index in stride(from: 68, to: bytes.count, by: 6) {
                func sample(_ offset: Int) -> Int32 {
                    let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                    return Int32(bitPattern: value << 8) >> 8
                }
                let left = sample(index), right = sample(index + 3)
                XCTAssertEqual(left, -right)
                peak = max(peak, abs(left))
            }
            XCTAssertEqual(peak, 240)
            XCTAssertEqual(Array(bytes[68..<74]), [0, 0, 0, 0, 0, 0])
            XCTAssertEqual(Array(bytes.suffix(6)), [0, 0, 0, 0, 0, 0])
            try await source.close()
        } catch {
            try await source.close()
            throw error
        }
    }

    func testSharedFailureDiagnosticSeparatesMembershipFromLeaseWithoutServerDetails() {
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: AudioAccountProviderError.contradicted),
                       "provider.contradicted")
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: AudioMembershipLeaseFailure.accountChanged),
                       "lease.account_changed")
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: AudioStreamingChannelError.staleOwner),
                       "channel.stale_owner")
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: AudioStreamingChannelError.unexpectedStream),
                       "channel.unexpected_stream")
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: AudioStreamingChannelError.closed),
                       "channel.closed")
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: AudioStreamingChannelError.fileTransferMismatch),
                       "channel.file_transfer_mismatch")
        let privateError = NSError(domain: "private-server-scope", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Bearer private-token; device-private-id"])
        XCTAssertEqual(AudioPlaybackFailureDiagnostic.label(for: privateError), "type.NSError")
    }

    func testFilePickerSeparatesOriginalALACContainerFromBluetoothTypes() throws {
        let types = DeviceAudioPlaybackView.originalFileTypes
        XCTAssertEqual(types.count, 3); XCTAssertTrue(types.contains(.wav)); XCTAssertTrue(types.contains(.mpeg4Audio))
        let flac = try XCTUnwrap(types.first { $0.identifier == "org.xiph.flac" })
        XCTAssertTrue(flac.conforms(to: .audio)); XCTAssertEqual(flac.preferredFilenameExtension, "flac")
        XCTAssertEqual(DeviceAudioPlaybackView.bluetoothFileTypes.count, 2)
        XCTAssertFalse(DeviceAudioPlaybackView.bluetoothFileTypes.contains(.mpeg4Audio))
    }

    func testALACRequiresItsOwnPeerCapabilityAndRejectsOtherM4ACodecsBeforeOffer() async throws {
        for (bytes, support) in [(try IOSAudioALACFixture.data(), false),
                                 (try IOSAudioALACFixture.nonALACSampleEntry(), true)] {
            try await withFixture(sourceBytes: bytes, supportsFLAC: true, supportsALAC: support) { f in
                _ = f.start()
                try await f.expectFailure(.unsupportedSource)
                XCTAssertTrue(f.frames.isEmpty); XCTAssertEqual(f.transferCalls, 0)
                try await f.assertClosed()
            }
        }
    }

    func testALACKeepsContainerBytesAndEverySupportedValidBitDepth() async throws {
        let formats: [(Int, AudioStreamingPCMFormat.Encoding)] =
            [(16, .signed16), (20, .signed24), (24, .signed24), (32, .signed32)]
        for (bits, encoding) in formats {
            let bytes = try IOSAudioALACFixture.data(bits: bits)
            try await withFixture(sourceBytes: bytes, supportsALAC: true) { f in
                let sender = f.start()
                try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
                try await waitUntil { sender.phase == .awaitingOutput }
                let expected = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2,
                    encoding: encoding, declaredValidBits: UInt8(bits), waveChannelMask: 3)
                XCTAssertEqual(sender.sourceFormat, expected)
                try f.reply(.outputReady(expected))
                try f.reply(.playbackComplete(sourceFrames: 4_817, trailingPaddingFrames: 3))
                let receipt = try await f.result()
                XCTAssertEqual(receipt.format, expected); XCTAssertEqual(receipt.sourceFrames, 4_817)
                XCTAssertEqual(f.sentBytes, bytes); try await f.assertClosed()
            }
        }
    }

    func testALACOutputFailureAndChangedFormatCannotBecomePlaybackSuccess() async throws {
        for mismatchedFormat in [false, true] {
            try await withFixture(sourceBytes: IOSAudioALACFixture.data(), supportsALAC: true) { f in
                let sender = f.start()
                try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
                try await waitUntil { sender.phase == .awaitingOutput }
                if mismatchedFormat {
                    let changed = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2,
                        encoding: .signed16, declaredValidBits: 16, waveChannelMask: 3)
                    try f.reply(.outputReady(changed))
                } else { try f.reply(.stop(.unsupportedOutput)) }
                try await f.expectFailure(mismatchedFormat ? .protocolViolation : .unsupportedOutput)
                XCTAssertNil(sender.receipt); try await f.assertClosed()
            }
        }
    }

    func testALACUsesBoundedReceiverValidationDeadline() async throws {
        try await withFixture(sourceBytes: IOSAudioALACFixture.data(), supportsALAC: true) { f in
            let time = ContinuousClock.now
            f.clock.withLock { $0.instant = time }
            var options = IOSOriginalFileSendSession.Options()
            options.outputTimeout = .milliseconds(100); options.flacOutputTimeout = .seconds(2)
            options.pollInterval = .milliseconds(5)
            let sender = f.start(options: options)
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.phase == .awaitingOutput }
            let before = f.clock.withLock { $0.reads }
            f.clock.withLock { $0.instant = time.advanced(by: .seconds(1)) }
            try await waitUntil { f.clock.withLock { $0.reads } > before }
            XCTAssertFalse(f.finished, "ALAC requires full receiver validation before output")
            f.clock.withLock { $0.instant = time.advanced(by: .seconds(2)) }
            try await f.expectFailure(.timedOut); try await f.assertClosed()
        }
    }

    func testFLACNeedsExactPeerCapabilityAndFiniteSampleCountBeforeOffer() async throws {
        for (support, unknown) in [(false, false), (true, true)] {
            try await withFixture(sourceBytes: IOSAudioFLACFixture.data(unknownFrames: unknown), supportsFLAC: support) { f in
                _ = f.start()
                try await f.expectFailure(.unsupportedSource)
                XCTAssertTrue(f.frames.isEmpty); XCTAssertEqual(f.transferCalls, 0)
                try await f.assertClosed()
            }
        }
    }

    func testFLACPreservesEncodedBytesAndChecksExactDecodedOutputDeclaration() async throws {
        let bytes = try IOSAudioFLACFixture.data()
        try await withFixture(sourceBytes: bytes, supportsFLAC: true) { f in
            let sender = f.start()
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.phase == .awaitingOutput }
            let expected = try AudioStreamingPCMFormat(sampleRate: 44_100, channels: 2, encoding: .signed32,
                declaredValidBits: 32, waveChannelMask: 3)
            XCTAssertEqual(sender.sourceFormat, expected)
            try f.reply(.outputReady(expected)); try f.reply(.playbackComplete(sourceFrames: 31, trailingPaddingFrames: 1))
            let receipt = try await f.result()
            XCTAssertEqual(receipt.format, expected); XCTAssertEqual(receipt.sourceFrames, 31)
            XCTAssertEqual(f.sentBytes, bytes); try await f.assertClosed()
        }
        try await withFixture(sourceBytes: bytes, supportsFLAC: true) { f in
            _ = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            let changed = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .signed32,
                                                      declaredValidBits: 32, waveChannelMask: 3)
            try f.reply(.outputReady(changed))
            try await f.expectFailure(.protocolViolation); try await f.assertClosed()
        }
    }

    func testFLACHasItsOwnBoundedValidationWaitBeforeOutputReady() async throws {
        try await withFixture(sourceBytes: IOSAudioFLACFixture.data(), supportsFLAC: true) { f in
            let time = ContinuousClock.now
            f.clock.withLock { $0.instant = time }
            var options = IOSOriginalFileSendSession.Options()
            options.outputTimeout = .milliseconds(100); options.flacOutputTimeout = .seconds(2)
            options.pollInterval = .milliseconds(5)
            let sender = f.start(options: options)
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.phase == .awaitingOutput }
            let before = f.clock.withLock { $0.reads }
            f.clock.withLock { $0.instant = time.advanced(by: .seconds(1)) }
            try await waitUntil { f.clock.withLock { $0.reads } > before }
            XCTAssertFalse(f.finished, "FLAC must not use the shorter WAVE output deadline")
            f.clock.withLock { $0.instant = time.advanced(by: .seconds(2)) }
            try await f.expectFailure(.timedOut); try await f.assertClosed()
        }
    }

    func testPlaybackSheetProducesNativeLightAndLargeTextDarkSnapshots() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKeyAndVisible() }
        let hosting = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        let target = IOSAudioPlaybackTarget(deviceID: "presentation-fixture", name: "Studio Computer",
            identity: try AudioProtocolIdentity(deviceID: "presentation-fixture", algorithm: .ed25519,
                fingerprint: String(repeating: "ab", count: 32)), sources: [.originalFile, .systemCapture])
        for large in [false, true] {
            let service = IOSDeviceAudioPlaybackService()
            let view = DeviceAudioPlaybackView(target: target, service: service,
                openChannel: { XCTFail("Rendering opened a network session"); throw AudioStreamingChannelError.unavailable },
                captureAvailability: large ? .systemUnavailable : .available)
                .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
            window.overrideUserInterfaceStyle = large ? .dark : .light
            hosting.rootView = AnyView(view)
            try await attachAudioPlaybackSnapshot(window: window,
                name: large ? "audio-playback-dark-large-text" : "audio-playback-light", to: self)
            if large {
                // A wide iPad can fit the entire page. Exercise the scroll tail
                // in an explicit compact viewport, keeping the full-size image above.
                hosting.rootView = AnyView(view.frame(width: 390, height: 600))
                try await attachAudioPlaybackSnapshot(window: window,
                    name: "audio-playback-dark-large-text-bottom", scrollToEnd: true, to: self)
            }
            XCTAssertFalse(service.isRunning); XCTAssertNil(service.operation)
            XCTAssertNil(service.captureSource); XCTAssertNil(service.captureOperation)
        }
    }

    func testOutputAndCompletionBeforeClassicReceiptCannotFinishTheOperation() async throws {
        try await withFixture { f in
            let gate = FileSessionGate(); f.transferGate = gate
            let sender = f.start()
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await gate.waitForArrival()
            let format = try XCTUnwrap(sender.sourceFormat)
            try f.reply(.outputReady(format)); try f.reply(.playbackComplete(sourceFrames: 256, trailingPaddingFrames: 7))
            await Task.yield()
            XCTAssertNil(sender.receipt); XCTAssertFalse(f.finished)
            gate.finish()
            let result = try await f.result()
            XCTAssertEqual(result.sourceFrames, 256); XCTAssertEqual(result.trailingPaddingFrames, 7)
            XCTAssertEqual(result.format, format); XCTAssertEqual(result.file.receivedBytes, Int64(f.wave.count))
            XCTAssertEqual(sender.phase, .completed); XCTAssertEqual(f.sentBytes, f.wave)
            try await f.assertClosed()
        }
    }

    func testClassicReceiptAloneDoesNotClaimOutputOrPlayback() async throws {
        try await withFixture { f in
            let sender = f.start()
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.phase == .awaitingOutput }
            XCTAssertNil(sender.receipt); XCTAssertFalse(f.finished)
            try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat)))
            try await waitUntil { sender.phase == .awaitingPlayback }
            XCTAssertNil(sender.receipt)
            try f.reply(.playbackComplete(sourceFrames: 256, trailingPaddingFrames: 0))
            _ = try await f.result(); try await f.assertClosed()
        }
    }

    func testDeclineClosesPreparedSourceWithoutStartingFileTransferOrEchoingStop() async throws {
        try await withFixture { f in
            _ = f.start(); try await f.waitForOffer()
            try f.reply(.stop(.receiverDeclined))
            try await f.expectFailure(.receiverDeclined)
            XCTAssertEqual(f.transferCalls, 0); XCTAssertEqual(f.frames.count, 1)
            try await f.assertClosed()
        }
    }

    func testInvalidAcceptanceOrCaptureControlFailsWithoutFileSuccess() async throws {
        for body in [AudioStreamingMessage.Body.accept(receiveWindowBytes: 64), .credit(retiredBytes: 0)] {
            try await withFixture { f in
                _ = f.start(); try await f.waitForOffer(); try f.reply(body)
                try await f.expectFailure(.protocolViolation)
                XCTAssertEqual(f.transferCalls, 0); try await f.assertClosed()
            }
        }
    }

    func testDuplicateAcceptCannotStartASecondFileTransfer() async throws {
        try await withFixture { f in
            let gate = FileSessionGate(); f.transferGate = gate
            _ = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await gate.waitForArrival(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { f.sender?.phase == .stopping }
            gate.finish(); try await f.expectFailure(.protocolViolation)
            XCTAssertEqual(f.transferCalls, 1); try await f.assertClosed()
        }
    }

    func testOutputMustExactlyMatchRatePrecisionEncodingAndLayout() async throws {
        let formats = [
            try AudioStreamingPCMFormat(sampleRate: 44_100, channels: 2, encoding: .signed16, declaredValidBits: 16, waveChannelMask: nil),
            try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .signed16, declaredValidBits: 15, waveChannelMask: nil),
            try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .float32, declaredValidBits: 32, waveChannelMask: nil),
            try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .signed16, declaredValidBits: 16, waveChannelMask: 3)
        ]
        for format in formats {
            try await withFixture { f in
                let sender = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
                try await waitUntil { sender.phase == .awaitingOutput }
                try f.reply(.outputReady(format)); try await f.expectFailure(.protocolViolation)
                try await f.assertClosed()
            }
        }
    }

    func testPrematureOrWrongFrameCompletionCannotReturnSuccess() async throws {
        for readyFirst in [false, true] {
            try await withFixture { f in
                let sender = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
                try await waitUntil { sender.phase == .awaitingOutput }
                if readyFirst { try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat))) }
                try f.reply(.playbackComplete(sourceFrames: readyFirst ? 255 : 256, trailingPaddingFrames: 0))
                try await f.expectFailure(.protocolViolation); try await f.assertClosed()
            }
        }
    }

    func testFileReceiptMustConfirmTheExactOfferedIdentifierLengthAndDigest() async throws {
        for mismatch in 0..<4 {
            try await withFixture { f in
                f.receiptTransform = { r in TransferReceipt(transferId: mismatch == 0 ? UUID().uuidString : r.transferId,
                    success: mismatch != 3, receivedBytes: r.receivedBytes + (mismatch == 1 ? 1 : 0),
                    fileHash: mismatch == 2 ? String(repeating: "a", count: 64) : r.fileHash) }
                _ = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
                try await f.expectFailure(.contentMismatch); try await f.assertClosed()
            }
        }
    }

    func testLeaseForAnotherChannelIsRejectedBeforeSourceReadOrOffer() async throws {
        for mismatch in 0..<3 {
            try await withFixture { f in
                f.wrongOwner = mismatch == 0; f.wrongLocal = mismatch == 1; f.wrongPeer = mismatch == 2
                _ = f.start(); try await f.expectFailure(.accountRevoked)
                XCTAssertEqual(f.sender?.failure?.underlying as? IOSOriginalFileSendError, .leaseBindingMismatch)
                XCTAssertEqual(f.frames.count, 0); XCTAssertEqual(f.scope.withLock { $0.started }, 0)
                try await f.assertClosed(expectedScopeCount: 0)
            }
        }
    }

    func testRevocationWhileAwaitingAcceptanceSendsOnlyTerminalControl() async throws {
        try await withFixture { f in
            _ = f.start(); try await f.waitForOffer(); f.authorization.revoke()
            try await f.expectFailure(.accountRevoked)
            XCTAssertEqual(f.transferCalls, 0); XCTAssertEqual(f.frames.count, 2)
            try await f.assertClosed()
        }
    }

    func testCancellationWaitsForTheActualNoncooperativeFileWorkerBeforeClosingSource() async throws {
        try await withFixture { f in
            let gate = FileSessionGate(); f.transferGate = gate
            let sender = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await gate.waitForArrival(); sender.stop()
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertFalse(f.finished)
            let sourceClosed = await f.source.isClosed
            XCTAssertFalse(sourceClosed, "A still-running reader retains the source")
            gate.finish(); try await f.expectFailure(.userStopped); try await f.assertClosed()
        }
    }

    func testChannelReplacementWhileFileWorkerIsRunningCannotUseReplacement() async throws {
        try await withFixture { f in
            let gate = FileSessionGate(); f.transferGate = gate
            _ = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await gate.waitForArrival(); f.session.invalidate()
            try await waitUntil { f.sender?.phase == .stopping }
            gate.finish(); try await f.expectFailure(.sessionReplaced)
            XCTAssertEqual(f.sentBytes.count, 0); try await f.assertClosed()
        }
    }

    func testAcceptanceAndOutputWaitsHaveBoundedDeadlines() async throws {
        for accept in [false, true] {
            try await withFixture { f in
                var options = IOSOriginalFileSendSession.Options()
                options.acceptanceTimeout = .milliseconds(50); options.outputTimeout = .milliseconds(50)
                options.pollInterval = .milliseconds(5)
                _ = f.start(options: options); try await f.waitForOffer()
                if accept { try f.reply(.accept(receiveWindowBytes: 0)) }
                try await f.expectFailure(.timedOut); try await f.assertClosed()
            }
        }
    }

    func testPlaybackReportsCannotHideAStalledClassicTransfer() async throws {
        try await withFixture { f in
            let gate = FileSessionGate(); f.transferGate = gate
            var options = IOSOriginalFileSendSession.Options()
            options.transferTimeout = .milliseconds(50); options.pollInterval = .milliseconds(5)
            let sender = f.start(options: options)
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0)); try await gate.waitForArrival()
            try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat)))
            try f.reply(.playbackComplete(sourceFrames: 256, trailingPaddingFrames: 0))
            try await waitUntil { sender.phase == .stopping }
            XCTAssertFalse(f.finished); XCTAssertNil(sender.receipt)
            gate.finish(); try await f.expectFailure(.timedOut); try await f.assertClosed()
        }
    }

    func testOutputReadyDoesNotExtendTheNativeCompletionDeadline() async throws {
        try await withFixture { f in
            var options = IOSOriginalFileSendSession.Options()
            options.completionGrace = .milliseconds(50); options.pollInterval = .milliseconds(5)
            let sender = f.start(options: options)
            try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await waitUntil { sender.phase == .awaitingOutput }
            try f.reply(.outputReady(XCTUnwrap(sender.sourceFormat)))
            try await f.expectFailure(.timedOut); try await f.assertClosed()
        }
    }

    func testCleanupFailureRetainsSourceAndRequiresExplicitRetry() async throws {
        try await withFixture { f in
            f.failSourceCleanup = true
            let sender = f.start(); try await f.waitForOffer(); try f.reply(.accept(receiveWindowBytes: 0))
            try await f.expectFailure(.sourceFailed)
            XCTAssertTrue(sender.cleanupPending)
            let before = await f.source.isClosed; XCTAssertFalse(before)
            XCTAssertEqual(f.scope.withLock { $0.stopped }, 0)
            try await sender.retryCleanup()
            XCTAssertFalse(sender.cleanupPending); XCTAssertEqual(sender.phase, .failed)
            XCTAssertNil(sender.receipt); try await f.assertClosed()
        }
    }

    func testSecondRunCannotTakeResourcesFromTheFirst() async throws {
        try await withFixture { f in
            let sender = f.start(); try await f.waitForOffer()
            do { _ = try await sender.run(); XCTFail("single-use operation started twice") }
            catch { XCTAssertEqual(error as? IOSOriginalFileSendError, .alreadyStarted) }
            XCTAssertFalse(f.finished); XCTAssertEqual(f.frames.count, 1)
            f.running?.cancel(); try await f.expectFailure(.userStopped); try await f.assertClosed()
        }
    }

    func testStoppedBeforeRunCannotReadOrSend() async throws {
        try await withFixture { f in
            let sender = f.makeSender(); sender.stop(); f.launch(sender)
            try await f.expectFailure(.userStopped)
            XCTAssertEqual(f.frames.count, 0); try await f.assertClosed(expectedScopeCount: 0)
        }
    }

    func testProductOwnerKeepsBusyUntilTheActualWorkerEndsAndRejectsAnotherStart() async throws {
        try await withFixture { f in
            let gate = FileSessionGate(); f.transferGate = gate
            let service = IOSDeviceAudioPlaybackService(makeSession: { [weak f] source, channel in
                f?.serviceSource = source
                return IOSOriginalFileSendSession(renewMembership: nil, source: source, channel: channel,
                    authorize: { try makeControlledAudioMembershipLease(channel: $0) },
                    transfer: { source, _, _, authorize, _ in
                        _ = try await source.claimForSending()
                        await gate.wait()
                        try authorize()
                        throw IOSOriginalFileSendError.stopped
                    })
            })
            f.service = service
            let target = IOSAudioPlaybackTarget(deviceID: "selected-peer", name: "Computer", identity: f.channel.remoteIdentity, sources: [.originalFile])
            try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target, openChannel: { f.channel })
            try await f.waitForOffer()
            let operation = try XCTUnwrap(service.operation)
            XCTAssertEqual(try f.session.receive(.init(streamID: operation.streamID, body: .accept(receiveWindowBytes: 0))), .delivered)
            try await gate.waitForArrival()
            var openedReplacement = false
            XCTAssertThrowsError(try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target,
                openChannel: { openedReplacement = true; return f.channel })) {
                    XCTAssertEqual($0 as? IOSDeviceAudioPlaybackError, .busy)
                }
            XCTAssertFalse(openedReplacement)
            service.stop()
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(service.isRunning)
            let held = try XCTUnwrap(f.serviceSource)
            let closedBeforeWorkerExit = await held.isClosed; XCTAssertFalse(closedBeforeWorkerExit)
            gate.finish(); await service.stopAndWait()
            XCTAssertFalse(service.isRunning); XCTAssertFalse(service.cleanupPending)
            XCTAssertNotNil(service.lastError); XCTAssertNil(operation.receipt)
            let closed = await held.isClosed; XCTAssertTrue(closed)
        }
    }

    func testProductOwnerRetainsFailedCleanupAndBlocksSelectionUntilExplicitRetry() async throws {
        try await withFixture { f in
            let service = IOSDeviceAudioPlaybackService(makeSession: { [weak f] source, channel in
                f?.serviceSource = source
                return IOSOriginalFileSendSession(renewMembership: nil, source: source, channel: channel,
                    authorize: { try makeControlledAudioMembershipLease(channel: $0) },
                    transfer: { source, _, _, authorize, _ in
                        _ = try await source.claimForSending(); try authorize()
                        throw IOSAudioFileTransferCleanupError(primary: "injected close failure", connectionFailure: nil,
                            sourceFailure: "source retained")
                    })
            })
            f.service = service
            let target = IOSAudioPlaybackTarget(deviceID: "selected-peer", name: "Computer", identity: f.channel.remoteIdentity, sources: [.originalFile])
            try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target, openChannel: { f.channel })
            try await f.waitForOffer()
            let operation = try XCTUnwrap(service.operation)
            XCTAssertEqual(try f.session.receive(.init(streamID: operation.streamID, body: .accept(receiveWindowBytes: 0))), .delivered)
            try await waitUntil { !service.isRunning }
            XCTAssertTrue(service.cleanupPending); XCTAssertTrue(service.operation === operation)
            XCTAssertThrowsError(try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target,
                openChannel: { XCTFail("Cleanup-pending owner permitted another channel"); return f.channel })) {
                    XCTAssertEqual($0 as? IOSDeviceAudioPlaybackError, .cleanupPending)
                }
            try await service.retryCleanup()
            XCTAssertFalse(service.cleanupPending); XCTAssertEqual(operation.phase, .failed)
            XCTAssertNotNil(service.lastError); XCTAssertNil(operation.receipt)
            let closed = await f.serviceSource?.isClosed; XCTAssertEqual(closed, true)
        }
    }

    func testBackgroundFileContinuesThroughAppSwitchAndCompletesOnlyWithNativeReceipt() async throws {
        try await withFixture(supportsOutputProgress: true) { f in
            let scheduler = ControlledAudioBackgroundScheduler()
            let background = try IOSAudioBackgroundExecution(identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Audio test", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background }, makeSession: { source, _ in
                f.serviceSource = source; return f.makeSender(sourceOverride: source)
            })
            f.service = service
            let target = IOSAudioPlaybackTarget(deviceID: "selected-peer", name: "Computer",
                                                identity: f.channel.remoteIdentity, sources: [.originalFile])
            try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target, openChannel: { f.channel })
            // Same actor turn: the request worker has not had a chance to run.
            service.didEnterBackground()
            XCTAssertEqual(service.backgroundState, .requesting)
            try await waitUntil { scheduler.submitting }
            let handle = scheduler.launch()
            try await f.waitForOffer(); let operation = try XCTUnwrap(service.operation); f.sender = operation
            let format = try XCTUnwrap(operation.sourceFormat)
            service.didEnterBackground(); service.presentationDidDisappear(isBackground: true)
            XCTAssertTrue(service.isRunning); XCTAssertEqual(service.backgroundState, .active)
            try f.reply(.accept(receiveWindowBytes: 0)); try f.reply(.outputReady(format))
            try await waitUntil { operation.phase == .awaitingPlayback }
            try f.reply(.fileOutputProgress(sourceFrames: 256))
            try await waitUntil { operation.workProgress.outputFrames == 256 }
            XCTAssertTrue(service.isRunning); XCTAssertNil(operation.receipt); XCTAssertTrue(handle.completions.isEmpty)
            XCTAssertEqual(background.progress.value.fractionCompleted, 0.75, accuracy: 0.0001)
            try f.reply(.playbackComplete(sourceFrames: 256, trailingPaddingFrames: 0))
            try await waitUntil { !service.isRunning }
            XCTAssertEqual(handle.completions, [true]); XCTAssertNotNil(operation.receipt)
            XCTAssertEqual(service.backgroundState, .finished); XCTAssertNil(service.lastError)
            let closed = await f.serviceSource?.isClosed; XCTAssertEqual(closed, true)
        }
    }

    func testSystemExpirationWaitsForActualFileWorkerBeforeCompletingBackgroundTask() async throws {
        try await withFixture(supportsOutputProgress: true) { f in
            let gate = FileSessionGate(); f.transferGate = gate
            let scheduler = ControlledAudioBackgroundScheduler()
            let background = try IOSAudioBackgroundExecution(identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Audio test", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background }, makeSession: { source, _ in
                f.serviceSource = source; return f.makeSender(sourceOverride: source)
            })
            f.service = service
            let target = IOSAudioPlaybackTarget(deviceID: "selected-peer", name: "Computer",
                                                identity: f.channel.remoteIdentity, sources: [.originalFile])
            try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target, openChannel: { f.channel })
            try await waitUntil { scheduler.submitting }; let handle = scheduler.launch()
            try await f.waitForOffer(); f.sender = service.operation
            try f.reply(.accept(receiveWindowBytes: 0)); try await gate.waitForArrival()
            handle.expire(); service.didEnterBackground()
            try await waitUntil { service.operation?.phase == .stopping }
            XCTAssertTrue(service.isRunning); XCTAssertTrue(service.isPresentationLocked)
            XCTAssertTrue(handle.completions.isEmpty)
            let held = await f.serviceSource?.isClosed; XCTAssertEqual(held, false)
            gate.finish(); await service.stopAndWait()
            XCTAssertEqual(handle.completions, [false]); XCTAssertNil(service.operation?.receipt)
            XCTAssertEqual(service.lastError as? IOSAudioBackgroundError, .expired)
            let closed = await f.serviceSource?.isClosed; XCTAssertEqual(closed, true)
        }
    }

    func testRejectedBackgroundSubmissionClosesSourceWithoutSendingAnOffer() async throws {
        try await withFixture(supportsOutputProgress: true) { f in
            let scheduler = ControlledAudioBackgroundScheduler(); scheduler.submissionError = .registrationRejected
            let background = try IOSAudioBackgroundExecution(identifier: "com.skybridge.compass.ios.audio-file." + UUID().uuidString,
                title: "Audio test", scheduler: scheduler)
            let service = IOSDeviceAudioPlaybackService(makeBackgroundExecution: { background }, makeSession: { source, _ in
                f.serviceSource = source; return f.makeSender(sourceOverride: source)
            })
            f.service = service
            let target = IOSAudioPlaybackTarget(deviceID: "selected-peer", name: "Computer",
                                                identity: f.channel.remoteIdentity, sources: [.originalFile])
            try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target, openChannel: { f.channel })
            try await waitUntil { !service.isRunning }
            XCTAssertTrue(f.frames.isEmpty); XCTAssertEqual(f.transferCalls, 0)
            XCTAssertEqual(service.lastError as? IOSAudioBackgroundError, .registrationRejected)
            XCTAssertFalse(service.cleanupPending)
            let closed = await f.serviceSource?.isClosed; XCTAssertEqual(closed, true)
        }
    }

    func testOriginalFileWithoutBackgroundOwnerStopsWhenAppEntersBackground() async throws {
        try await withFixture { f in
            let service = IOSDeviceAudioPlaybackService(makeSession: { [weak f] source, channel in
                f?.serviceSource = source
                return IOSOriginalFileSendSession(renewMembership: nil, source: source, channel: channel,
                    authorize: { try makeControlledAudioMembershipLease(channel: $0) })
            })
            f.service = service
            let target = IOSAudioPlaybackTarget(deviceID: "selected-peer", name: "Computer",
                                                identity: f.channel.remoteIdentity, sources: [.originalFile])
            try service.start(url: f.directory.appendingPathComponent("unchanged.wav"), target: target,
                              openChannel: { f.channel })
            try await f.waitForOffer()
            service.didEnterBackground()
            try await waitUntil { !service.isRunning }
            XCTAssertEqual(service.operation?.failure?.reason, .userStopped)
            XCTAssertNil(service.operation?.receipt); XCTAssertFalse(service.isPresentationLocked)
            let source = try XCTUnwrap(f.serviceSource)
            let closed = await source.isClosed; XCTAssertTrue(closed)
        }
    }

    private func withFixture(sourceBytes: Data? = nil, supportsFLAC: Bool = false, supportsALAC: Bool = false,
                             supportsOutputProgress: Bool = false,
                             _ body: @MainActor (FileSessionFixture) async throws -> Void) async throws {
        let f = try FileSessionFixture(sourceBytes: sourceBytes, supportsFLAC: supportsFLAC, supportsALAC: supportsALAC,
            supportsOutputProgress: supportsOutputProgress)
        do { try await body(f); try await f.close() }
        catch {
            let primary = error
            do { try await f.close() } catch { XCTFail("Fixture cleanup also failed: \(error)") }
            throw primary
        }
    }
}

@MainActor
private final class FileSessionFixture {
    let source: IOSPreparedAudioFile
    let channel: IOSAudioChannel
    let session: IOSAudioSession
    let connection = IOSAudioFileConnection()
    let authorization = AccountAudioAuthorization()
    let directory: URL
    let wave: Data
    let scope = OSAllocatedUnfairLock(initialState: (started: 0, stopped: 0))
    let clock = OSAllocatedUnfairLock(initialState: (instant: ContinuousClock.Instant?.none, reads: 0))
    let frameStore: FileSessionFrames
    var frames: [Data] { frameStore.values }
    var transferGate: FileSessionGate?
    var wrongOwner = false
    var wrongLocal = false
    var wrongPeer = false
    var failSourceCleanup = false
    var receiptTransform: (TransferReceipt) -> TransferReceipt = { $0 }
    var transferCalls = 0
    var sentBytes = Data()
    var sender: IOSOriginalFileSendSession?
    var membership: IOSPlaybackMembershipFixture?
    var service: IOSDeviceAudioPlaybackService?
    var serviceSource: IOSPreparedAudioFile?
    var running: Task<IOSOriginalFileSendReceipt, Error>?
    var finished = false
    private var watchdog: Task<Void, Never>?
    private var removed = false

    init(sourceBytes: Data? = nil, supportsFLAC: Bool = false, supportsALAC: Bool = false,
         supportsOutputProgress: Bool = false) throws {
        let frames = FileSessionFrames(); frameStore = frames
        let local = try ProtocolIdentityBinding(deviceId: "file-session-ios-local", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x19, count: 32))
        let keys = SkyBridgeCompass_iOS.SessionKeys(sendKey: Data(repeating: 0x21, count: 32),
            receiveKey: Data(repeating: 0x43, count: 32), negotiatedSuite: .qperiaptABI2PolicyBound,
            role: .initiator, transcriptHash: Data(repeating: 0x65, count: 32))
        let generation = UUID()
        let peer = IOSAudioPeerSnapshot(generation: generation, sessionID: keys.sessionId,
            identity: try AudioProtocolIdentity(deviceID: "file-session-desktop-peer", algorithm: .ed25519,
                fingerprint: String(repeating: "ab", count: 32)),
            capabilities: Set([AudioStreamingWire.fileReceiveCapability]
                + (supportsFLAC ? [AudioStreamingWire.flacFileReceiveCapability] : [])
                + (supportsALAC ? [AudioStreamingWire.alacFileReceiveCapability] : [])
                + (supportsOutputProgress ? [AudioStreamingWire.fileOutputProgressReportCapability] : [])),
            filePort: 2345, acceptedMaterialDigest: Data(repeating: 0x34, count: 32))
        session = try IOSAudioSession(generation: generation, keys: keys, localIdentity: local, peer: peer,
            fileRoute: .network(.hostPort(host: "127.0.0.1", port: 2345)), requireConnection: {},
            sendFrame: { frame, completion in frames.values.append(frame); completion.completeWrite(.success(())) },
            cancelTransport: { XCTFail("An audio operation closed the shared MAIN transport") })
        channel = try session.open(requiringFingerprint: peer.identity.fingerprint)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-session-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var bytes = Data()
        func ascii(_ s: String) { bytes.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { bytes.append(UInt8(truncatingIfNeeded: n)); bytes.append(UInt8(n >> 8)) }
        func u32(_ n: UInt32) { u16(UInt16(truncatingIfNeeded: n)); u16(UInt16(n >> 16)) }
        ascii("RIFF"); u32(36 + 1024); ascii("WAVEfmt "); u32(16); u16(1); u16(2)
        u32(48_000); u32(192_000); u16(4); u16(16); ascii("data"); u32(1024)
        bytes.append(contentsOf: (0..<1024).map { UInt8(truncatingIfNeeded: $0) })
        if let sourceBytes { bytes = sourceBytes }
        wave = bytes
        let url = directory.appendingPathComponent("unchanged.wav")
        do {
            try bytes.write(to: url)
            let scope = self.scope
            source = try IOSPreparedAudioFile(url: url, startScope: { _ in scope.withLock { $0.started += 1 }; return true },
                stopScope: { _ in scope.withLock { $0.stopped += 1 } })
        } catch { try FileManager.default.removeItem(at: directory); throw error }
    }

    func makeSender(options: IOSOriginalFileSendSession.Options = .init(), sourceOverride: IOSPreparedAudioFile? = nil) -> IOSOriginalFileSendSession {
        let clock = clock
        let renewal: IOSAudioMembershipRenewal?
        if let membership {
            renewal = { channel, lease in try await membership.renew(channel, lease) }
        } else { renewal = nil }
        return IOSOriginalFileSendSession(renewMembership: renewal,
            source: sourceOverride ?? source, channel: channel, connection: connection, options: options,
            now: { clock.withLock { value in value.reads += 1; return value.instant ?? .now } },
            authorize: { [weak self] channel in
                guard let self else { throw CancellationError() }
                if let membership { return try await membership.authorize(channel) }
                return try makeControlledAudioMembershipLease(channel: channel, authorization: authorization,
                    ownerID: wrongOwner ? UUID() : channel.ownerID,
                    localOverride: wrongLocal ? AudioProtocolIdentity(deviceID: "different-ios-local-identity", algorithm: .ed25519,
                        fingerprint: String(repeating: "cd", count: 32)) : nil,
                    peerOverride: wrongPeer ? AudioProtocolIdentity(deviceID: "different-desktop-peer-identity", algorithm: .ed25519,
                        fingerprint: String(repeating: "ef", count: 32)) : nil)
            }, transfer: { [weak self] source, _, connection, authorize, progress in
                guard let self else { throw CancellationError() }
                transferCalls += 1
                let content = try await source.claimForSending()
                if let transferGate { await transferGate.wait() }
                try authorize()
                if failSourceCleanup {
                    throw IOSAudioFileTransferCleanupError(primary: "injected cleanup boundary",
                        connectionFailure: nil, sourceFailure: "reader close unconfirmed")
                }
                sentBytes = try await content.reader.read(offset: 0, length: Int(content.length))
                await progress(content.length, content.length)
                try authorize()
                try await source.close(); try await connection.close()
                return receiptTransform(TransferReceipt(transferId: content.transferID, success: true,
                    receivedBytes: content.length, fileHash: content.digest.map { String(format: "%02x", $0) }.joined()))
            })
    }

    func start(options: IOSOriginalFileSendSession.Options = .init()) -> IOSOriginalFileSendSession {
        let sender = makeSender(options: options); launch(sender); return sender
    }
    func launch(_ sender: IOSOriginalFileSendSession) {
        self.sender = sender
        running = Task { [self] in defer { finished = true }; return try await sender.run() }
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) }
            catch is CancellationError { return }
            catch { XCTFail("Test watchdog failed: \(error)"); return }
            guard let self, !finished else { return }
            XCTFail("File session exceeded the test deadline")
            sender.stop(); transferGate?.finish()
        }
    }
    func waitForOffer() async throws { try await waitUntil { self.frames.count == 1 } }
    func reply(_ body: AudioStreamingMessage.Body) throws {
        let sender = try XCTUnwrap(sender)
        XCTAssertEqual(try session.receive(.init(streamID: sender.streamID, body: body)), .delivered)
    }
    func result() async throws -> IOSOriginalFileSendReceipt { try await XCTUnwrap(running).value }
    func expectFailure(_ reason: AudioStreamingStopReason) async throws {
        do { _ = try await result(); XCTFail("Expected failure \(reason)") }
        catch let error as IOSOriginalFileSendFailure { XCTAssertEqual(error.reason, reason) }
        XCTAssertEqual(sender?.phase, .failed); XCTAssertNil(sender?.receipt)
    }
    func assertClosed(expectedScopeCount: Int = 1) async throws {
        XCTAssertTrue(connection.isClosed)
        let sourceClosed = await source.isClosed; XCTAssertTrue(sourceClosed)
        XCTAssertEqual(scope.withLock { $0.started }, expectedScopeCount)
        XCTAssertEqual(scope.withLock { $0.stopped }, expectedScopeCount)
        XCTAssertThrowsError(try channel.requireCurrent())
    }
    func close() async throws {
        watchdog?.cancel()
        membership?.renewalGate?.finish()
        running?.cancel(); sender?.stop(); transferGate?.finish()
        await service?.stopAndWait()
        if let serviceSource { try await serviceSource.close() }
        if let running { _ = await running.result }
        try await connection.close(); try await source.close(); channel.close(); session.invalidate()
        if !removed { try FileManager.default.removeItem(at: directory); removed = true }
    }
}

@MainActor
private final class FileSessionFrames { var values: [Data] = [] }

@MainActor
private final class FileSessionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false
    private(set) var arrived = false
    func wait() async {
        arrived = true
        if completed { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForArrival() async throws { try await waitUntil { self.arrived } }
    func finish() { completed = true; let value = continuation; continuation = nil; value?.resume() }
}

@MainActor
private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
        if ContinuousClock.now >= until { throw IOSOriginalFileSendError.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Hosted native SwiftUI presentation, including the actual scrollable tail.
/// Controlled presentation fixtures never request system capture permission.
@MainActor
func attachAudioPlaybackSnapshot(window: UIWindow, name: String,
                                 scrollToEnd: Bool = false, to test: XCTestCase) async throws {
    try await Task.sleep(for: .milliseconds(350)); window.layoutIfNeeded()
    if scrollToEnd {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let containers = descendants(window).compactMap { $0 as? UIScrollView }
        let geometry = containers.map { "\(String(reflecting: type(of: $0))) enabled=\($0.isScrollEnabled) frame=\($0.frame) bounds=\($0.bounds) content=\($0.contentSize) inset=\($0.adjustedContentInset)" }
        let diagnostic = XCTAttachment(string: "window=\(window.bounds) root=\(String(describing: window.rootViewController?.view.frame))\n" + geometry.joined(separator: "\n"))
        diagnostic.name = name + "-scroll-geometry"; diagnostic.lifetime = .keepAlways; test.add(diagnostic)
        let scroll = try XCTUnwrap(containers
            .filter { $0.isScrollEnabled && $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom > $0.bounds.height }
            .max { $0.contentSize.height < $1.contentSize.height })
        let initialOffset = scroll.contentOffset.y
        var reachedEnd = false
        // Lazy List measurements can refine many large-text rows as scrolling
        // realizes them. Wait for a stable measured end, within a finite deadline,
        // rather than assuming exactly four jumps have materialized every footer.
        let deadline = ContinuousClock.now + .seconds(3)
        var stableObservations = 0
        var observations: [String] = []
        while ContinuousClock.now < deadline {
            let end = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: end), animated: false)
            try await Task.sleep(for: .milliseconds(50)); window.layoutIfNeeded()
            let actualEnd = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            observations.append("requested=\(end) measured=\(actualEnd) offset=\(scroll.contentOffset.y)")
            if abs(actualEnd - end) < 0.5 && abs(scroll.contentOffset.y - actualEnd) < 0.5 {
                stableObservations += 1
                if stableObservations == 2 { reachedEnd = true; break }
            } else { stableObservations = 0 }
        }
        let settling = XCTAttachment(string: observations.joined(separator: "\n"))
        settling.name = name + "-settling"; settling.lifetime = .keepAlways; test.add(settling)
        XCTAssertTrue(reachedEnd, "The list did not settle at its actual bottom")
        XCTAssertGreaterThan(scroll.contentOffset.y, initialOffset)
        let endGeometry = XCTAttachment(string: "offset=\(scroll.contentOffset) content=\(scroll.contentSize) bounds=\(scroll.bounds) inset=\(scroll.adjustedContentInset)")
        endGeometry.name = name + "-end-geometry"; endGeometry.lifetime = .keepAlways; test.add(endGeometry)
    }
    let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
    }
    let attachment = XCTAttachment(image: rendered)
    attachment.name = name; attachment.lifetime = .keepAlways; test.add(attachment)
}

/// Only a test issuer. Product callers obtain evidence from the live provider.
@MainActor
func makeControlledAudioMembershipLease(channel: IOSAudioChannel,
    authorization: AccountAudioAuthorization = AccountAudioAuthorization(), ownerID: UUID? = nil,
    localOverride: AudioProtocolIdentity? = nil, peerOverride: AudioProtocolIdentity? = nil) throws -> AudioMembershipLease {
    let local = try localOverride ?? AudioProtocolIdentity(channel.localIdentityBindingForAccountRequest())
    let peer = peerOverride ?? channel.remoteIdentity
    let account = try AudioAccountIdentity(authority: "https://account.example.invalid", tenantID: "fixture", userID: "user")
    let wall: Int64 = 1_000_000, now = ContinuousClock.now
    let rows = [local, peer].map { identity in AccountDeviceRecord(deviceId: identity.deviceID, deviceName: nil,
        status: "active", protocolSigningAlgorithm: identity.algorithm.rawValue, protocolPublicKeyFingerprint: identity.fingerprint,
        platformRawValue: nil, deviceModel: nil, osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil,
        capabilities: [], registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
        presenceUpdatedAtEpochMilliseconds: nil, online: true, isCaller: identity == local) }
    let response = AccountDeviceListSnapshot(generatedAtEpochMilliseconds: wall, callerDeviceId: local.deviceID,
        truncated: false, devices: rows, accountScope: account.serverScope)
    let evidence = try AudioAccountMembership.verifyFreshResponse(response, account: account, local: local, peer: peer,
        requestStartedMilliseconds: wall, receivedMilliseconds: wall, requestStartedMonotonic: now, receivedMonotonic: now)
    return try AudioMembershipLease(evidence: evidence, ownerID: ownerID ?? channel.ownerID,
        account: account, local: local, peer: peer, wallMilliseconds: { wall },
        isAccountCurrent: { authorization.isCurrent }, isPeerCurrent: channel.isCurrentForMembership)
}


/// Real shared store and native carrier with controlled authenticated registry
/// data. The initial evidence is aged to one minute before expiry; no device or
/// account credentials are read, and no wall-clock hour is simulated as hardware proof.
@MainActor
final class IOSPlaybackMembershipFixture {
    let channel: IOSAudioChannel
    let context: AudioAccountContext
    let local: AudioProtocolIdentity
    let clock = IOSPlaybackMembershipClock()
    var renewalGate: IOSPlaybackRenewalGate?
    var renewalFailure: (any Error)?
    private(set) var renewalCalls = 0
    private(set) var lease: AudioMembershipLease?
    private lazy var store = AudioAccountMembershipStore(currentContext: { [weak self] in
        guard let self else { throw CancellationError() }; return context
    }, fetch: { [weak self] _, _ in
        guard let self else { throw CancellationError() }
        if lease != nil {
            if let renewalGate { await renewalGate.wait() }
            if let renewalFailure { throw renewalFailure }
        }
        let identities = [local, channel.remoteIdentity]
        let rows = identities.map { identity in AccountDeviceRecord(deviceId: identity.deviceID, deviceName: nil,
            status: "active", protocolSigningAlgorithm: identity.algorithm.rawValue,
            protocolPublicKeyFingerprint: identity.fingerprint, platformRawValue: nil, deviceModel: nil,
            osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil, capabilities: [],
            registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
            presenceUpdatedAtEpochMilliseconds: nil, online: true, isCaller: identity == local) }
        return AccountDeviceListSnapshot(generatedAtEpochMilliseconds: clock.wall, callerDeviceId: local.deviceID,
            truncated: false, devices: rows, accountScope: context.account.serverScope)
    }, wall: { [clock] in clock.wall }, monotonic: { [clock] in clock.monotonic },
       isCallerInactive: { _ in false },
       isTemporaryFetchFailure: AudioMembershipRequestFailurePolicy.isTemporaryNetworkError)

    init(channel: IOSAudioChannel, authorization: AccountAudioAuthorization) throws {
        self.channel = channel
        local = try AudioProtocolIdentity(channel.localIdentityBindingForAccountRequest())
        context = AudioAccountContext(authorization: authorization,
            account: try AudioAccountIdentity(authority: "https://playback.example.invalid", tenantID: "fixture", userID: "user"))
    }
    private func binding(_ value: IOSAudioChannel) throws -> AudioAccountChannelBinding {
        guard value === channel else { throw AudioStreamingChannelError.staleOwner }
        return AudioAccountChannelBinding(ownerID: value.ownerID,
            localIdentity: try value.localIdentityBindingForAccountRequest(), remoteIdentity: value.remoteIdentity,
            requireCurrent: { try value.requireCurrent() }, isCurrent: value.isCurrentForMembership)
    }
    func authorize(_ value: IOSAudioChannel) async throws -> AudioMembershipLease {
        let result = try await store.lease(for: binding(value)); lease = result
        clock.becomeCurrent()
        return result
    }
    func renew(_ value: IOSAudioChannel, _ current: AudioMembershipLease) async throws -> AudioMembershipLease {
        XCTAssertTrue(current === lease); renewalCalls += 1
        return try await store.renew(for: binding(value), continuing: current)
    }
}

final class IOSPlaybackMembershipClock: Sendable {
    private let offset = OSAllocatedUnfairLock(initialState: Int64(-3_540_000))
    var wall: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) + offset.withLock { $0 } }
    var monotonic: ContinuousClock.Instant { ContinuousClock.now.advanced(by: .milliseconds(offset.withLock { $0 })) }
    func becomeCurrent() { offset.withLock { $0 = 0 } }
}

@MainActor
final class IOSPlaybackRenewalGate {
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private(set) var arrived = false
    var cancelled: Bool { cancellation.withLock { $0 } }
    private var ended = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        arrived = true
        let cancellation = cancellation
        await withTaskCancellationHandler {
            if ended { return }
            await withCheckedContinuation { waiting = $0 }
        } onCancel: { cancellation.withLock { $0 = true } }
    }
    func finish() { ended = true; let value = waiting; waiting = nil; value?.resume() }
}
