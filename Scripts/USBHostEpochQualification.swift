import CryptoKit
import Foundation
import IOKit
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore

/// Explicit, synthetic real-device check. No product session or audio output.
/// Re-run with a fresh attempt UUID and the SAME registry/attachment to test reopen.
private enum QualificationError: Error { case arguments, attachment, deadline, payload, prematureEnd, trailingBytes, cleanup, epoch }

@main private enum USBHostEpochQualification {
    static func emit(_ value: [String: Any]) throws {
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10]))
    }
    static func canonical(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value,
              value != "00000000-0000-0000-0000-000000000000" else { throw QualificationError.arguments }
        return uuid
    }
    static func requireCurrent(_ id: UInt64, phoneSerial: String, deadline: ContinuousClock.Instant) throws {
        guard ContinuousClock.now < deadline else { throw QualificationError.deadline }
        guard let matching = IORegistryEntryIDMatching(id) else { throw QualificationError.attachment }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { throw QualificationError.attachment }
        let serial = IORegistryEntryCreateCFProperty(entry, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        let released = IOObjectRelease(entry)
        guard released == KERN_SUCCESS else { throw QualificationError.cleanup }
        guard serial == phoneSerial else { throw QualificationError.attachment }
    }
    static func payload(_ attempt: UUID) -> Data {
        var bytes = Array("SBEQ".utf8)
        withUnsafeBytes(of: attempt.uuid) { bytes.append(contentsOf: $0) }
        for index in 20..<900_003 {
            bytes.append(index % 4 == 0 ? 0x7d : index % 4 == 1 ? 0x7e : UInt8(truncatingIfNeeded: index * 31 + 17))
        }
        return Data(bytes)
    }
    static func remaining(_ end: ContinuousClock.Instant) throws -> Duration {
        let left = ContinuousClock.now.duration(to: end)
        guard left > .zero else { throw QualificationError.deadline }; return left
    }
    static func send(_ bytes: Data, to stream: USBHostMultiplexConnection.Stream,
                     authority: @escaping @Sendable () throws -> Void) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        var offset = 0
        while offset < bytes.count {
            let next = min(offset + 16_384, bytes.count)
            try await stream.writeBytes(bytes.subdata(in: offset..<next), timeout: remaining(end), requireEffectAuthorization: authority)
            offset = next
        }
        try await stream.finishSending(timeout: remaining(end))
    }
    static func receive(_ expected: Data, from stream: USBHostMultiplexConnection.Stream) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        var bytes = Data()
        while bytes.count < expected.count {
            switch try await stream.readBytes(maximumBytes: min(16_384, expected.count - bytes.count), timeout: remaining(end)) {
            case .bytes(let chunk): bytes.append(chunk)
            case .end: throw QualificationError.prematureEnd
            }
        }
        guard bytes == expected else { throw QualificationError.payload }
        guard case .end = try await stream.readBytes(maximumBytes: 1, timeout: remaining(end)) else { throw QualificationError.trailingBytes }
    }
    static func describe(_ error: any Error) -> [String: Any] {
        var value: [String: Any] = ["type": String(reflecting: type(of: error)), "description": String(describing: error)]
        if let error = error as? USBHostFailure {
            value["nativePhase"] = error.phase; value["nativeDomain"] = error.domain; value["nativeCode"] = error.nativeCode
        }
        return value
    }
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 6, args[1] == "transfer", let registry = UInt64(args[2]), registry != 0,
                  !args[3].isEmpty, args[3].utf8.count <= 128 else { throw QualificationError.arguments }
            let attachment = try canonical(args[4]), attempt = try canonical(args[5])
            let end = ContinuousClock.now.advanced(by: .seconds(45)), began = ContinuousClock.now
            let authority: @Sendable () throws -> Void = { try requireCurrent(registry, phoneSerial: args[3], deadline: end) }
            try authority()
            let link = try USBHostMultiplexConnection(deviceRegistryID: registry, configuration: .init(linkProfile: .epochV2), requireAttachmentCurrent: authority)
            var ready = false, verified = false
            var phase = "native-open", failurePhase: String?
            var failure: (any Error)?, cleanupFailure: (any Error)?
            var epoch: USBLinkEpochProtocol.Snapshot?
            let bytes = payload(attempt)
            let digest = Data(SHA256.hash(data: bytes))
            do {
                try emit(["event": "starting", "attemptId": args[5], "attachmentId": attachment.uuidString.lowercased(), "registryId": registry, "profile": "epoch-v2"])
                phase = "epoch-start"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await link.start(timeout: .seconds(10))
                epoch = link.epochSnapshot
                guard epoch?.phase == .ready else { throw QualificationError.epoch }; ready = true
                try emit(["event": "ready", "attemptId": args[5], "registryId": registry])
                phase = "payload-open"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                let stream = try await link.openStream(timeout: .seconds(10))
                phase = "payload-send"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await send(bytes, to: stream, authority: authority)
                phase = "payload-receive"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await receive(bytes, from: stream)
                phase = "payload-close"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await stream.closeAndAwait(timeout: .seconds(5))
                phase = "digest-open"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                let acknowledgement = try await link.openStream(timeout: .seconds(10))
                phase = "digest-send"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await send(digest, to: acknowledgement, authority: authority)
                phase = "digest-receive"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await receive(digest, from: acknowledgement)
                phase = "digest-close"; try emit(["event": "phase", "phase": phase, "attemptId": args[5]])
                try await acknowledgement.closeAndAwait(timeout: .seconds(5))
                epoch = link.epochSnapshot; verified = true
            } catch { failure = error; failurePhase = phase }
            let beforeClose = link.protocolSnapshot
            try emit(["event": "before-connection-close", "attemptId": args[5], "phase": phase,
                "logicalOwners": beforeClose.owners, "pendingWriteBytes": beforeClose.pendingWriteBytes,
                "bufferedReceiveBytes": beforeClose.bufferedReceiveBytes, "queuedControlFrames": beforeClose.queuedControlFrames,
                "protocolDispatchPending": beforeClose.dispatchPending, "protocolFailed": beforeClose.failed,
                "epochDispatchPending": link.epochSnapshot?.dispatchPending == true,
                "retired": link.shutdownState.retired])
            link.close()
            do { try await link.closeAndAwait(timeout: .seconds(5)) }
            catch { cleanupFailure = error; if failure == nil { failure = error } }
            let state = link.shutdownState
            let cleanup = state.nativeWorkersExited && state.referencesReleased && state.pumpsJoined && state.logicalOwnersReleased && link.epochSnapshot?.dispatchPending != true
            let completed = ready && verified && cleanup && failure == nil
            let elapsed = began.duration(to: .now).components
            var result: [String: Any] = ["event": "result", "attemptId": args[5], "attachmentId": attachment.uuidString.lowercased(), "registryId": registry,
                "profile": "epoch-v2", "completed": completed, "ready": ready, "echoAndDigestVerified": verified,
                "payloadBytes": bytes.count, "payloadSha256": digest.map { String(format: "%02x", $0) }.joined(),
                "nativeWorkersExited": state.nativeWorkersExited, "referencesReleased": state.referencesReleased,
                "pumpsJoined": state.pumpsJoined, "logicalOwnersReleased": state.logicalOwnersReleased, "cleanupConfirmed": cleanup,
                "epochDispatchPending": link.epochSnapshot?.dispatchPending == true,
                "elapsedSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                "scope": "Synthetic native USB epoch only; no MAIN identity, account, audio or automatic recovery qualification"]
            if let epoch {
                result["discardedRecords"] = epoch.discardedRecords; result["quarantinedRecords"] = epoch.quarantinedRecords
                if let peer = epoch.peer { result["peerNonceSha256"] = SHA256.hash(data: peer.bytes).map { String(format: "%02x", $0) }.joined() }
            }
            if let failure { result["failure"] = describe(failure) }
            if let failurePhase { result["failurePhase"] = failurePhase }
            if let cleanupFailure { result["cleanupFailure"] = describe(cleanupFailure) }
            try emit(result)
            if !completed { exit(1) }
        } catch {
            do { try emit(["event": "failed", "failure": describe(error)]) } catch { exit(2) }
            exit(1)
        }
    }
}
