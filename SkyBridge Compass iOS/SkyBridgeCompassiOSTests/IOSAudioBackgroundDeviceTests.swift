import XCTest
import UIKit
import CryptoKit
@testable import SkyBridgeCompass_iOS

/// Physical SDK admission and owned file I/O only. This does not synthesize
/// audio receipts or claim that a foreground XCTest exercised app suspension.
@MainActor
final class IOSAudioBackgroundDeviceTests: XCTestCase {
    func testNativeContinuedTaskAdmitsRealFileHashAndClosesAfterCancellation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The actual continued-processing scheduler requires a physical device")
        #else
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Continued processing requires iOS 26 or later")
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while UIApplication.shared.applicationState != .active {
            guard ContinuousClock.now < deadline else {
                throw ProbeError.foregroundRequired
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        let permitted = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertTrue(permitted.contains(bundleID + ".audio-file.*"))
        let execution = try IOSAudioBackgroundExecution(identifier: bundleID + ".audio-file." + UUID().uuidString,
            title: "SkyBridge 无声文件检查", scheduler: IOSContinuedAudioTaskScheduler())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-background-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Native file probe cleanup failed: \(error)") }
        }
        let data = waveData(), url = directory.appendingPathComponent("local-hash-only.wav")
        try data.write(to: url)
        let source = try IOSPreparedAudioFile(url: url)
        let state = ProbeState()
        var admitted = false
        do {
            try await execution.start { state.stopped = true }
            admitted = execution.state == .active
            XCTAssertTrue(admitted); XCTAssertTrue(execution.preservesBackgroundWork)
            let content = try await source.prepare(onHashProgress: { bytes, total in
                try await MainActor.run {
                    guard !state.stopped else { throw CancellationError() }
                    state.hashedBytes = bytes
                    execution.update(.init(phase: .inspecting, hashedBytes: bytes, hashTotal: total,
                        transferredBytes: 0, fileBytes: nil, outputFrames: 0, sourceFrames: nil))
                    if let failure = execution.failure { throw failure }
                }
            })
            XCTAssertEqual(content.length, Int64(data.count))
            XCTAssertEqual(state.hashedBytes, content.length)
            XCTAssertEqual(content.digest, Data(SHA256.hash(data: data)))
            XCTAssertEqual(execution.progress.value.fractionCompleted, 0.25, accuracy: 0.0001)
            try await source.close()
            let closed = await source.isClosed; XCTAssertTrue(closed)
            // Deliberately end an incomplete audio operation. Hashing is not a
            // transfer, output progress, or a receiver completion acknowledgement.
            execution.cancel()
            await execution.finish(success: false)
            XCTAssertTrue(state.stopped)
            XCTAssertEqual(execution.state, .failed)
            XCTAssertEqual(execution.failure as? IOSAudioBackgroundError, .cancelled)
            attachReceipt(admitted: admitted, hashedBytes: state.hashedBytes, closed: closed, failure: nil)
        } catch {
            let primary = error
            execution.cancel()
            do { try await source.close() }
            catch { XCTFail("Native probe source cleanup also failed: \(error)") }
            await execution.finish(success: false)
            let closed = await source.isClosed
            attachReceipt(admitted: admitted, hashedBytes: state.hashedBytes, closed: closed, failure: primary)
            throw primary
        }
        #endif
    }

    private enum ProbeError: Error { case foregroundRequired }
    @MainActor private final class ProbeState { var stopped = false; var hashedBytes: Int64 = 0 }

    private func waveData() -> Data {
        let byteCount: UInt32 = 8 * 1024 * 1024
        var bytes = Data()
        func word(_ value: UInt16) { bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(value >> 8)) }
        func dword(_ value: UInt32) { word(UInt16(truncatingIfNeeded: value)); word(UInt16(value >> 16)) }
        bytes.append(contentsOf: "RIFF".utf8); dword(36 + byteCount)
        bytes.append(contentsOf: "WAVEfmt ".utf8); dword(16); word(1); word(2)
        dword(48_000); dword(192_000); word(4); word(16)
        bytes.append(contentsOf: "data".utf8); dword(byteCount)
        bytes.append(Data(repeating: 0, count: Int(byteCount)))
        return bytes
    }

    private func attachReceipt(admitted: Bool, hashedBytes: Int64, closed: Bool, failure: (any Error)?) {
        struct Receipt: Encodable {
            let schemaVersion = 1
            let nativeScheduler = "IOSContinuedAudioTaskScheduler"
            let operatingSystem: String
            let admitted: Bool
            let hashedBytes: Int64
            let sourceClosed: Bool
            let backgroundSwitchTested = false
            let audioPlayed = false
            let systemExpirationCallbackTested = false
            let receiverReceiptReceived = false
            let failureDomain: String?
            let failureCode: Int?
        }
        do {
            let error = failure.map { $0 as NSError }
            let receipt = Receipt(operatingSystem: UIDevice.current.systemVersion, admitted: admitted, hashedBytes: hashedBytes, sourceClosed: closed,
                failureDomain: error?.domain, failureCode: error?.code)
            let attachment = XCTAttachment(data: try JSONEncoder().encode(receipt), uniformTypeIdentifier: "public.json")
            attachment.name = "native-background-file-admission"; attachment.lifetime = .keepAlways; add(attachment)
        } catch { XCTFail("Could not encode native admission evidence: \(error)") }
    }
}
