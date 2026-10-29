#if os(macOS)
import CryptoKit
import Foundation
import XCTest
import os
@testable import SkyBridgeCore
@testable import SkyBridgeProtocolCore

/// Real prepared WAVE files, deterministic substitute output/clock. No HAL or audible playback.
@MainActor
final class AudioFilePCMPlaybackTests: XCTestCase {
    func testOriginalPacked24BytesStayOrderedWithinNativeCapacity() async throws {
        let pcm = Data((0..<108).map { UInt8(truncatingIfNeeded: $0 * 47 + 3) })
        let source = try await fixture(pcm: pcm, encoding: .signed24)
        let output = Output(source, capacityFrames: 6, minimumPrefill: 2, retirePerObservation: 1)
        let receipt = try await play(source, output)
        XCTAssertEqual(receipt.sourceFrames, 18)
        XCTAssertEqual(output.state.withLock { $0.bytes }, pcm)
        XCTAssertLessThanOrEqual(output.state.withLock { $0.maximumQueued }, 6)
        XCTAssertEqual(output.state.withLock { $0.starts }, 1)
        XCTAssertEqual(output.state.withLock { $0.finishes }, 1)
        XCTAssertEqual(output.state.withLock { $0.closes }, 0)
        let header = try await source.reader.read(offset: 0, length: 4)
        XCTAssertEqual(header, Data("RIFF".utf8), "Pump does not close its caller's reader")
    }

    func testReadAndEnqueueQuantumIsBoundedAndFrameAligned() async throws {
        let pcm = Data((0..<196_608).map { UInt8(truncatingIfNeeded: $0) })
        let source = try await fixture(pcm: pcm, encoding: .signed16)
        let output = Output(source, capacityFrames: 32_768, minimumPrefill: 128, retirePerObservation: 512)
        _ = try await play(source, output)
        XCTAssertEqual(output.state.withLock { $0.bytes }, pcm)
        let sizes = output.state.withLock { $0.enqueueSizes }
        XCTAssertGreaterThan(sizes.count, 1)
        XCTAssertTrue(sizes.allSatisfy { $0 > 0 && $0 <= 65_536 && $0 % 4 == 0 })
        XCTAssertLessThanOrEqual(output.state.withLock { $0.maximumQueued }, 32_768)
    }

    func testOutputProgressUsesNativeSubmissionsInsteadOfQueuedBytes() async throws {
        let pcm = Data((0..<78).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let source = try await fixture(pcm: pcm, encoding: .signed24)
        let output = Output(source, capacityFrames: 6, minimumPrefill: 4, retirePerObservation: 1)
        let observed = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let nativeState = output.state
        output.afterEnqueue.withLock { $0 = {
            if !nativeState.withLock({ $0.started }) { XCTAssertTrue(observed.withLock { $0.isEmpty }) }
        } }
        let receipt = try await play(source, output, onOutputProgress: { frames in
            XCTAssertEqual(frames, output.state.withLock { $0.submitted })
            observed.withLock { $0.append(frames) }
        })
        XCTAssertEqual(observed.withLock { $0 }, Array(UInt64(1)...13))
        XCTAssertEqual(receipt.sourceFrames, 13)
        XCTAssertEqual(receipt.trailingPaddingFrames, 3)
        XCTAssertEqual(output.state.withLock { $0.bytes }, pcm)
    }

    func testInvalidNativeObservationPublishesNoOutputProgress() async throws {
        let source = try await fixture(pcm: Data(count: 24))
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        output.state.withLock { $0.inventAccepted = true }
        let observed = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        do {
            _ = try await play(source, output, onOutputProgress: { frames in observed.withLock { $0.append(frames) } })
            XCTFail("Invalid native counters were accepted")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidProgress) }
        XCTAssertTrue(observed.withLock { $0.isEmpty })
    }

    func testShortAndEmptyFilesFinishWithoutAnExplicitStart() async throws {
        for frames in [0, 1, 3] {
            let source = try await fixture(pcm: Data(repeating: 0x80, count: frames * 2), encoding: .unsigned8)
            let output = Output(source, capacityFrames: 8, minimumPrefill: 4)
            let receipt = try await play(source, output)
            XCTAssertEqual(receipt.sourceFrames, UInt64(frames))
            XCTAssertEqual(receipt.trailingPaddingFrames, frames == 0 ? 0 : UInt32((4 - frames % 4) % 4))
            XCTAssertEqual(output.state.withLock { $0.starts }, 0)
            XCTAssertEqual(output.state.withLock { $0.finishes }, 1)
            XCTAssertEqual(output.state.withLock { $0.closes }, 0)
        }
    }

    func testSubmittedFramesAreNotCompletionAndPaddingIsNotSource() async throws {
        let source = try await fixture(pcm: Data(count: 4))
        let output = Output(source, capacityFrames: 8, minimumPrefill: 4)
        output.state.withLock { $0.allowCompletion = false }
        let clock = Clock()
        let pauses = OSAllocatedUnfairLock(initialState: 0)
        let observed = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let timing = AudioFilePCMPlayback.Timing(now: clock.now, pause: { duration in
            clock.advance(duration)
            let count = pauses.withLock { $0 += 1; return $0 }
            XCTAssertEqual(output.state.withLock { $0.submitted }, 1)
            XCTAssertEqual(observed.withLock { $0 }, [1], "A full source counter is still not drain completion")
            if count == 2 { output.state.withLock { $0.allowCompletion = true } }
        })
        let receipt = try await play(source, output, timing: timing,
            onOutputProgress: { frames in observed.withLock { $0.append(frames) } })
        XCTAssertEqual(pauses.withLock { $0 }, 2)
        XCTAssertEqual(receipt.sourceFrames, 1); XCTAssertEqual(receipt.trailingPaddingFrames, 3)
    }

    func testTransientBusyRetriesEachEffectWithoutDuplicatingSamples() async throws {
        let pcm = Data((0..<24).map(UInt8.init)), source = try await fixture(pcm: pcm)
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        output.state.withLock { $0.busyRemaining = [.enqueue: 1, .start: 1, .finishInput: 1] }
        let receipt = try await play(source, output)
        XCTAssertEqual(receipt.sourceFrames, 6); XCTAssertEqual(output.state.withLock { $0.bytes }, pcm)
        XCTAssertEqual(output.state.withLock { $0.starts }, 1); XCTAssertEqual(output.state.withLock { $0.finishes }, 1)
        XCTAssertEqual(output.state.withLock { $0.enqueueSizes.reduce(0, +) }, pcm.count)
    }

    func testEveryNativeBusyWaitHasADeadlineAndLeavesCleanupToCaller() async throws {
        for operation in [Operation.enqueue, .start, .finishInput] {
            let source = try await fixture(pcm: Data(count: 24))
            let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
            output.state.withLock { $0.alwaysBusy = operation }
            let expected: AudioFilePCMPlaybackError.Wait
            switch operation { case .enqueue: expected = .enqueue; case .start: expected = .start; case .finishInput: expected = .finishInput }
            do { _ = try await play(source, output, timing: Clock(step: .seconds(1)).timing); XCTFail("Busy wait did not terminate") }
            catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .timedOut(expected)) }
            XCTAssertEqual(output.state.withLock { $0.closes }, 0)
        }
    }

    func testNativeStallAndLateDrainCompletionAreDistinctTimeouts() async throws {
        let source = try await fixture(pcm: Data(count: 48))
        let stalled = Output(source, capacityFrames: 4, minimumPrefill: 2, retirePerObservation: 0)
        do { _ = try await play(source, stalled, timing: Clock(step: .seconds(6)).timing); XCTFail("Stalled queue succeeded") }
        catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .timedOut(.outputProgress)) }
        XCTAssertEqual(stalled.state.withLock { $0.finishes }, 0)
        let late = Output(source, capacityFrames: 16, minimumPrefill: 2)
        late.state.withLock { $0.allowCompletion = false }
        let clock = Clock()
        let timing = AudioFilePCMPlayback.Timing(now: clock.now, pause: { _ in
            clock.advance(.seconds(181)); late.state.withLock { $0.allowCompletion = true }
        })
        do { _ = try await play(source, late, timing: timing); XCTFail("Completion after deadline succeeded") }
        catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .timedOut(.drain)) }
        XCTAssertEqual(late.state.withLock { $0.submitted }, 12)
    }

    func testBadNativeCountersAndPrematureCompletionCannotProduceReceipt() async throws {
        let source = try await fixture(pcm: Data(count: 40))
        for mode in 0..<3 {
            let output = Output(source, capacityFrames: mode == 2 ? 16 : 2, minimumPrefill: 1, retirePerObservation: 1)
            output.state.withLock {
                if mode == 0 { $0.inventAccepted = true }
                if mode == 1 { $0.regressOnObservation = 5 }
                if mode == 2 { $0.completeWithoutSubmission = true; $0.retirePerObservation = 0 }
            }
            // For the final case all input fits, so only drain-state/count validation is exercised.
            do {
                _ = try await AudioFilePCMPlayback.play(reader: source.reader, metadata: source.metadata, output: output,
                    prepared: output.prepared(), ownerID: source.owner, requireAuthorization: {}, timing: Clock().timing)
                XCTFail("Invalid native evidence succeeded")
            } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidProgress) }
        }
    }

    func testOutputLossAndNativeErrorsPropagateWithoutClosingResources() async throws {
        let source = try await fixture(pcm: Data(count: 24))
        let lost = Output(source, capacityFrames: 4, minimumPrefill: 2)
        lost.state.withLock { $0.failOnObservation = 3 }
        do { _ = try await play(source, lost); XCTFail("Lost output succeeded") }
        catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .outputLost) }
        let native = Output(source, capacityFrames: 4, minimumPrefill: 2)
        native.state.withLock { $0.enqueueError = .nativeFailure }
        do { _ = try await play(source, native); XCTFail("Native error swallowed") }
        catch { XCTAssertEqual(error as? FixtureError, .nativeFailure) }
        XCTAssertEqual(native.state.withLock { $0.closes }, 0)
    }

    func testAuthorizationLossAfterAcceptedBytesNeverReplaysTheEffect() async throws {
        let source = try await fixture(pcm: Data(count: 24))
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        do {
            _ = try await play(source, output, authorization: {
                // Even an authorization error named busy must not be treated as native busy.
                if output.state.withLock({ !$0.bytes.isEmpty }) { throw CoreAudioExactPcmOutputError.busy }
            })
            XCTFail("Revoked effect returned success")
        } catch { XCTAssertEqual(error as? CoreAudioExactPcmOutputError, .busy) }
        XCTAssertEqual(output.state.withLock { $0.enqueueAttempts }, 1)
        XCTAssertEqual(output.state.withLock { $0.bytes.count }, 16)
        XCTAssertEqual(output.state.withLock { $0.starts }, 0)
        XCTAssertEqual(output.state.withLock { $0.closes }, 0)
    }

    func testCancellationAfterEnqueuePropagatesAndDoesNotSealOrClose() async throws {
        let source = try await fixture(pcm: Data(count: 24))
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        output.afterEnqueue.withLock { $0 = { withUnsafeCurrentTask { $0?.cancel() } } }
        let task = Task { try await AudioFilePCMPlayback.play(reader: source.reader, metadata: source.metadata,
            output: output, prepared: output.prepared(), ownerID: source.owner, requireAuthorization: {}, timing: Clock().timing) }
        do { _ = try await task.value; XCTFail("Cancelled pump succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(output.state.withLock { $0.bytes.count }, 16)
        XCTAssertEqual(output.state.withLock { $0.finishes }, 0); XCTAssertEqual(output.state.withLock { $0.closes }, 0)
        _ = try await source.reader.read(offset: 0, length: 4)
    }

    func testRevocationWhileWaitingStopsBeforeAnotherReadOrEffect() async throws {
        let source = try await fixture(pcm: Data(count: 48))
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2, retirePerObservation: 0)
        let revoked = OSAllocatedUnfairLock(initialState: false), clock = Clock()
        let timing = AudioFilePCMPlayback.Timing(now: clock.now, pause: { duration in
            clock.advance(duration); revoked.withLock { $0 = true }
        })
        do {
            _ = try await play(source, output, timing: timing, authorization: {
                if revoked.withLock({ $0 }) { throw FixtureError.revoked }
            })
            XCTFail("Revoked wait succeeded")
        } catch { XCTAssertEqual(error as? FixtureError, .revoked) }
        XCTAssertEqual(output.state.withLock { $0.bytes.count }, 16)
        XCTAssertEqual(output.state.withLock { $0.finishes }, 0)
    }

    func testClosedPreparedReaderErrorIsNotTurnedIntoEOF() async throws {
        let source = try await fixture(pcm: Data(count: 4))
        try await source.reader.close()
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        do { _ = try await play(source, output); XCTFail("Closed file became clean EOF") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
        XCTAssertEqual(output.state.withLock { $0.enqueueAttempts }, 0); XCTAssertEqual(output.state.withLock { $0.finishes }, 0)
    }

    func testNonFiniteFloatIsRejectedBeforeEnqueueWhileFiniteBitsArePreserved() async throws {
        let cases: [(AudioStreamingPCMFormat.Encoding, [UInt64])] = [
            (.float32, [0x7f80_0000, 0xff80_0000, 0x7fc1_2345]),
            (.float64, [0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, 0x7ff8_0000_0000_1234])
        ]
        for (encoding, patterns) in cases {
            let width = Int(encoding.containerBits / 8)
            for pattern in patterns {
                let source = try await fixture(pcm: Data(count: width) + little(pattern, width: width), encoding: encoding)
                let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
                do { _ = try await play(source, output); XCTFail("Non-finite sample reached output") }
                catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError,
                                       .nonFiniteSample(byteOffset: source.metadata.pcmByteOffset + UInt64(width))) }
                XCTAssertEqual(output.state.withLock { $0.enqueueAttempts }, 0)
            }
            let sign: UInt64 = width == 4 ? 0x8000_0000 : 0x8000_0000_0000_0000
            let pcm = little(sign, width: width) + little(1, width: width) // Negative zero and smallest subnormal.
            let source = try await fixture(pcm: pcm, encoding: encoding)
            let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
            _ = try await play(source, output)
            XCTAssertEqual(output.state.withLock { $0.bytes }, pcm)
        }
    }

    func testPreparedFormatCapacityAndMetadataRangeAreValidatedBeforeEffects() async throws {
        let source = try await fixture(pcm: Data(count: 4))
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        for capacity in [-1, 0, 3, 1_048_580] {
            let prepared = CoreAudioExactPcmPreparedOutput(endpointUID: "fixture", format: source.metadata.format,
                receiveCapacityBytes: capacity, minimumPrefillFrames: 2)
            do {
                _ = try await AudioFilePCMPlayback.play(reader: source.reader, metadata: source.metadata, output: output,
                    prepared: prepared, ownerID: source.owner, requireAuthorization: {})
                XCTFail("Invalid capacity accepted")
            } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidPreparedOutput) }
        }
        let other = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .signed16,
                                                 declaredValidBits: 16, waveChannelMask: 3)
        do {
            _ = try await AudioFilePCMPlayback.play(reader: source.reader, metadata: source.metadata, output: output,
                prepared: .init(endpointUID: "fixture", format: other, receiveCapacityBytes: 16, minimumPrefillFrames: 2),
                ownerID: source.owner, requireAuthorization: {})
            XCTFail("Different output format accepted")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidPreparedOutput) }
        let invalid = AudioWavePCMMetadata(format: source.metadata.format, pcmByteOffset: UInt64.max, pcmByteCount: 4)
        do {
            _ = try await AudioFilePCMPlayback.play(reader: source.reader, metadata: invalid, output: output,
                prepared: output.prepared(), ownerID: source.owner, requireAuthorization: {})
            XCTFail("Invalid metadata range accepted")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidDescriptor) }
        XCTAssertEqual(output.state.withLock { $0.enqueueAttempts }, 0)
        XCTAssertEqual(output.state.withLock { $0.finishes }, 0)
    }

    func testWrongOwnerCannotFeedOrStartPreparedOutput() async throws {
        let source = try await fixture(pcm: Data(count: 24))
        let output = Output(source, capacityFrames: 4, minimumPrefill: 2)
        do {
            _ = try await AudioFilePCMPlayback.play(reader: source.reader, metadata: source.metadata, output: output,
                prepared: output.prepared(), ownerID: UUID(), requireAuthorization: {})
            XCTFail("Wrong owner accepted")
        } catch { XCTAssertEqual(error as? CoreAudioExactPcmOutputError, .wrongOwner) }
        XCTAssertTrue(output.state.withLock { $0.bytes.isEmpty })
        XCTAssertEqual(output.state.withLock { $0.starts + $0.finishes + $0.closes }, 0)
    }

    func testValidatedFLACUsesBoundedPumpAndPreservesExactGoldenSamples() async throws {
        for name in ["golden-20-2", "reference-true32-stereo"] {
            let source = try await AudioFlacTestFixture.prepare(name, in: self)
            let file = try await AudioValidatedFlacFile.validate(reader: source.reader,
                                                               requireAuthorization: {})
            let owner = UUID()
            let output = Output(owner: owner, format: source.metadata.decodedFormat,
                                capacityFrames: 9_000, minimumPrefill: 128, retirePerObservation: 2_048)
            let receipt = try await AudioFilePCMPlayback.play(file: file, output: output, prepared: output.prepared(),
                ownerID: owner, requireAuthorization: {}, timing: Clock().timing)
            XCTAssertEqual(output.state.withLock { $0.bytes }, try AudioFlacTestFixture.resource(name, extension: "pcm"))
            XCTAssertEqual(receipt.sourceFrames, file.receipt.sourceFrames)
            XCTAssertLessThanOrEqual(output.state.withLock { $0.maximumQueued }, 9_000)
            XCTAssertTrue(output.state.withLock { $0.enqueueSizes.allSatisfy { $0 > 0 && $0 <= 65_536 } })
            XCTAssertEqual(output.state.withLock { $0.finishes }, 1)
            XCTAssertEqual(output.state.withLock { $0.closes }, 0, "Outer session still owns native output cleanup")
            let signature = try await source.reader.read(offset: 0, length: 4)
            XCTAssertEqual(signature, Data("fLaC".utf8))
        }
    }

    func testValidatedALACUsesTheExistingBoundedPumpAndPreservesExactSamples() async throws {
        for name in ["44100-1-s16", "48000-2-s20", "48000-2-s24", "96000-2-s32"] {
            let source = try await AudioAlacTestFixture.prepare(name, in: self)
            let file = try await AudioValidatedAlacFile.validate(reader: source.reader, requireAuthorization: {})
            let owner = UUID()
            let output = Output(owner: owner, format: file.metadata.decodedFormat, capacityFrames: 900,
                                minimumPrefill: 4, retirePerObservation: 2048)
            let receipt = try await AudioFilePCMPlayback.play(file: file, output: output, prepared: output.prepared(),
                ownerID: owner, requireAuthorization: {}, timing: Clock().timing)
            XCTAssertEqual(output.state.withLock { $0.bytes }, try AudioAlacTestFixture.resource(name, extension: "pcm"))
            XCTAssertEqual(receipt.sourceFrames, file.receipt.sourceFrames)
            XCTAssertLessThanOrEqual(output.state.withLock { $0.maximumQueued }, 900)
            XCTAssertTrue(output.state.withLock { $0.enqueueSizes.allSatisfy { $0 > 0 && $0 <= 65_536 } })
            XCTAssertEqual(output.state.withLock { $0.finishes }, 1)
            XCTAssertEqual(output.state.withLock { $0.closes }, 0)
        }
    }

    func testValidatedALACStillRequiresExactOutputAndActualDrain() async throws {
        let source = try await AudioAlacTestFixture.prepare("44100-2-s24", in: self)
        let file = try await AudioValidatedAlacFile.validate(reader: source.reader, requireAuthorization: {})
        let owner = UUID(), format = file.metadata.decodedFormat
        let output = Output(owner: owner, format: format, capacityFrames: 128, minimumPrefill: 4)
        let different = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .signed24,
                                                    declaredValidBits: 24, waveChannelMask: 3)
        do {
            _ = try await AudioFilePCMPlayback.play(file: file, output: output,
                prepared: .init(endpointUID: "fixture", format: different, receiveCapacityBytes: 768, minimumPrefillFrames: 4),
                ownerID: owner, requireAuthorization: {})
            XCTFail("ALAC bypassed exact output format")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidPreparedOutput) }
        XCTAssertEqual(output.state.withLock { $0.enqueueAttempts }, 0)
        output.state.withLock { $0.allowCompletion = false }
        do {
            _ = try await AudioFilePCMPlayback.play(file: file, output: output, prepared: output.prepared(),
                ownerID: owner, requireAuthorization: {}, timing: Clock(step: .seconds(181)).timing)
            XCTFail("ALAC EOF masqueraded as native output drain")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .timedOut(.drain)) }
        XCTAssertEqual(output.state.withLock { $0.submitted }, file.receipt.sourceFrames)
    }

    func testValidatedFLACStillRequiresExactOutputAndActualDrain() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let file = try await AudioValidatedFlacFile.validate(reader: source.reader,
                                                           requireAuthorization: {})
        let owner = UUID(), format = source.metadata.decodedFormat
        let output = Output(owner: owner, format: format, capacityFrames: 128, minimumPrefill: 4)
        let different = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .signed24,
                                                    declaredValidBits: 24, waveChannelMask: 3)
        do {
            _ = try await AudioFilePCMPlayback.play(file: file, output: output,
                prepared: .init(endpointUID: "fixture", format: different, receiveCapacityBytes: 768, minimumPrefillFrames: 4),
                ownerID: owner, requireAuthorization: {})
            XCTFail("FLAC bypassed exact output format")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .invalidPreparedOutput) }
        XCTAssertEqual(output.state.withLock { $0.enqueueAttempts }, 0)
        output.state.withLock { $0.allowCompletion = false }
        do {
            _ = try await AudioFilePCMPlayback.play(file: file, output: output, prepared: output.prepared(),
                ownerID: owner, requireAuthorization: {}, timing: Clock(step: .seconds(181)).timing)
            XCTFail("Decoder EOF masqueraded as native drain completion")
        } catch { XCTAssertEqual(error as? AudioFilePCMPlaybackError, .timedOut(.drain)) }
        XCTAssertEqual(output.state.withLock { $0.submitted }, file.receipt.sourceFrames)
    }

    private func play(_ source: Fixture, _ output: Output, timing: AudioFilePCMPlayback.Timing? = nil,
                      authorization: @escaping @Sendable () throws -> Void = {},
                      onOutputProgress: (@Sendable (UInt64) -> Void)? = nil) async throws -> AudioFilePCMPlaybackReceipt {
        try await AudioFilePCMPlayback.play(reader: source.reader, metadata: source.metadata, output: output,
            prepared: output.prepared(), ownerID: source.owner, requireAuthorization: authorization, timing: timing ?? Clock().timing,
            onOutputProgress: onOutputProgress)
    }

    private struct Fixture: Sendable {
        let owner: UUID
        let reader: PreparedOutboundFileReadSession
        let metadata: AudioWavePCMMetadata
    }
    private enum FixtureError: Error, Sendable, Equatable { case nativeFailure, revoked }
    private enum Operation: Sendable, Hashable { case enqueue, start, finishInput }
    private final class Clock: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        private let step: Duration?
        init(step: Duration? = nil) { self.step = step }
        func now() -> ContinuousClock.Instant { value.withLock { $0 } }
        func advance(_ duration: Duration) { value.withLock { $0 = $0.advanced(by: duration) } }
        var timing: AudioFilePCMPlayback.Timing {
            .init(now: now, pause: { [self] duration in advance(step ?? duration); await Task.yield() })
        }
    }

    private final class Output: AudioCaptureOutput {
        struct State: Sendable {
            var bytes = Data(), enqueueSizes: [Int] = []
            var accepted: UInt64 = 0, submitted: UInt64 = 0, maximumQueued: UInt64 = 0
            var started = false, finished = false, allowCompletion = true
            var starts = 0, finishes = 0, closes = 0, observations = 0, enqueueAttempts = 0
            var busyRemaining: [Operation: Int] = [:]
            var alwaysBusy: Operation?
            var enqueueError: FixtureError?
            var retirePerObservation: UInt64 = .max
            var inventAccepted = false, completeWithoutSubmission = false
            var regressOnObservation: Int?, failOnObservation: Int?
        }
        let state: OSAllocatedUnfairLock<State>
        let afterEnqueue = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let owner: UUID, format: AudioStreamingPCMFormat, capacityFrames: UInt64, minimumPrefill: UInt32
        convenience init(_ source: Fixture, capacityFrames: UInt64, minimumPrefill: UInt32, retirePerObservation: UInt64 = .max) {
            self.init(owner: source.owner, format: source.metadata.format, capacityFrames: capacityFrames,
                      minimumPrefill: minimumPrefill, retirePerObservation: retirePerObservation)
        }
        init(owner: UUID, format: AudioStreamingPCMFormat, capacityFrames: UInt64, minimumPrefill: UInt32,
             retirePerObservation: UInt64 = .max) {
            self.owner = owner; self.format = format; self.capacityFrames = capacityFrames
            self.minimumPrefill = minimumPrefill
            var value = State(); value.retirePerObservation = retirePerObservation
            state = OSAllocatedUnfairLock(initialState: value)
        }
        func prepared() -> CoreAudioExactPcmPreparedOutput {
            .init(endpointUID: "fixture", format: format, receiveCapacityBytes: Int(capacityFrames) * Int(format.bytesPerFrame),
                  minimumPrefillFrames: minimumPrefill)
        }
        func prepare(endpointUID: String, format: AudioStreamingPCMFormat) throws -> CoreAudioExactPcmPreparedOutput {
            XCTFail("Pump must not prepare another output"); throw FixtureError.nativeFailure
        }
        private func requireOwner(_ id: UUID) throws { guard id == owner else { throw CoreAudioExactPcmOutputError.wrongOwner } }
        private func requireNotBusy(_ operation: Operation, _ value: inout State) throws {
            if value.alwaysBusy == operation { throw CoreAudioExactPcmOutputError.busy }
            if let count = value.busyRemaining[operation], count > 0 {
                value.busyRemaining[operation] = count - 1; throw CoreAudioExactPcmOutputError.busy
            }
        }
        func enqueue(_ bytes: Data, ownerID: UUID) throws {
            try requireOwner(ownerID)
            try state.withLock { value in
                value.enqueueAttempts += 1; try requireNotBusy(.enqueue, &value)
                if let error = value.enqueueError { throw error }
                let frames = UInt64(bytes.count) / UInt64(format.bytesPerFrame)
                guard !value.finished, bytes.count % Int(format.bytesPerFrame) == 0,
                      value.accepted - value.submitted + frames <= capacityFrames else { throw AudioFilePCMPlaybackError.invalidProgress }
                value.bytes.append(bytes); value.enqueueSizes.append(bytes.count); value.accepted += frames
                value.maximumQueued = max(value.maximumQueued, value.accepted - value.submitted)
            }
            afterEnqueue.withLock { $0 }?()
        }
        func start(ownerID: UUID) throws {
            try requireOwner(ownerID)
            try state.withLock { value in
                try requireNotBusy(.start, &value)
                guard !value.started, value.accepted - value.submitted >= UInt64(minimumPrefill) else {
                    throw CoreAudioExactPcmOutputError.insufficientPrefill
                }
                value.started = true; value.starts += 1
            }
        }
        func finishInput(ownerID: UUID, expectedSourceFrames: UInt64) throws {
            try requireOwner(ownerID)
            try state.withLock { value in
                try requireNotBusy(.finishInput, &value)
                guard !value.finished, expectedSourceFrames == value.accepted else { throw CoreAudioExactPcmOutputError.sourceCountMismatch }
                value.finished = true; value.finishes += 1
                if value.accepted > 0 { value.started = true }
            }
        }
        func observe() throws -> AudioCaptureOutputObservation {
            state.withLock { value in
                value.observations += 1
                if value.started {
                    value.submitted += min(value.retirePerObservation, value.accepted - value.submitted)
                }
                let completed = value.finished && (value.completeWithoutSubmission || value.submitted == value.accepted && value.allowCompletion)
                let observed: AudioCaptureOutputObservation.State
                if value.observations == value.failOnObservation { observed = .failed }
                else if completed { observed = .completed }
                else if value.finished { observed = .draining }
                else { observed = value.started ? .running : .prepared }
                let padding = value.finished && value.accepted > 0
                    ? UInt32((UInt64(minimumPrefill) - value.accepted % UInt64(minimumPrefill)) % UInt64(minimumPrefill)) : 0
                return .init(state: observed, acceptedSourceFrames: value.accepted + (value.inventAccepted ? 1 : 0),
                    submittedSourceFrames: value.observations == value.regressOnObservation ? 0 : value.submitted,
                    trailingPaddingFrames: padding)
            }
        }
        func close(ownerID: UUID) -> AudioOutputCleanupOutcome {
            state.withLock { $0.closes += 1 }
            return .init(state: .released, diagnostics: [], preservedExternalChanges: [])
        }
    }

    private func fixture(pcm: Data, encoding: AudioStreamingPCMFormat.Encoding = .signed16) async throws -> Fixture {
        let format = try AudioStreamingPCMFormat(sampleRate: 44_100, channels: 2, encoding: encoding,
                                                 declaredValidBits: encoding.containerBits, waveChannelMask: 3)
        var fmt = little(0xfffe, width: 2) + little(2, width: 2) + little(44_100, width: 4)
        fmt.append(little(UInt64(44_100) * UInt64(format.bytesPerFrame), width: 4))
        fmt.append(little(UInt64(format.bytesPerFrame), width: 2)); fmt.append(little(UInt64(encoding.containerBits), width: 2))
        fmt.append(little(22, width: 2)); fmt.append(little(UInt64(encoding.containerBits), width: 2)); fmt.append(little(3, width: 4))
        fmt.append(little(encoding.isFloatingPoint ? 3 : 1, width: 4))
        fmt.append(Data([0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]))
        let body = Data("WAVEfmt ".utf8) + little(UInt64(fmt.count), width: 4) + fmt + Data("data".utf8) + little(UInt64(pcm.count), width: 4) + pcm
        let wave = Data("RIFF".utf8) + little(UInt64(body.count), width: 4) + body
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-file-pump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.wav"); try wave.write(to: url, options: .withoutOverwriting)
        let reader = try await PreparedOutboundFileReadSession.prepare(url: url, maximumSize: Int64(wave.count),
            sourcePolicy: .ownedSingleLinkStableMetadata, expectedSHA256: Data(SHA256.hash(data: wave)))
        addTeardownBlock { try await reader.close() }
        let metadata = try await AudioWavePCMFile.inspect(fileSize: UInt64(reader.metadata.fileSize)) { offset, count in
            try await reader.read(offset: offset, length: count)
        }
        return .init(owner: UUID(), reader: reader, metadata: metadata)
    }
    private func little(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
#endif
