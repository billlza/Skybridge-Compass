// Local fixture for Kotlin interoperability with the actual byte owner and multiplex pumps.
// Only native acquisition/I/O is substituted with a bounded loopback socket. No USB/auth/audio claim.
import CryptoKit
import Darwin
import Foundation
import SkyBridgeProtocolCore
import os
@testable import SkyBridgeAppleTransport

private enum NativePeerError: Error { case arguments, timedOut, invalidData, unexpectedFIN, cleanupUnconfirmed }
private struct PeerCleanupFailure: Error { let original: any Error; let cleanup: any Error }
private func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}

@main private enum USBNativeInteropMain {
    static let implementation = "skybridge-swift-usb-owner"
    static let command = Data("skybridge-usb-control-1".utf8)
    static func payload(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 31 + 17) }) }
    static func acceptLoopback(profile: String) throws -> Int32 {
        try USBLoopbackSocketFixture.accept { port in
            try emit(["event": "listening", "port": port, "implementation": implementation, "linkProfile": profile])
        }
    }
    static func read(_ stream: USBHostMultiplexConnection.Stream, expected: Data) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5)); var offset = 0
        while offset < expected.count {
            let remaining = ContinuousClock.now.duration(to: end)
            guard remaining > .zero else { throw NativePeerError.timedOut }
            switch try await stream.readBytes(maximumBytes: min(8191, expected.count - offset), timeout: remaining) {
            case .end: throw NativePeerError.unexpectedFIN
            case .bytes(let bytes):
                guard bytes.count <= expected.count - offset,
                      bytes == expected.subdata(in: offset..<(offset + bytes.count)) else { throw NativePeerError.invalidData }
                offset += bytes.count
            }
        }
    }
    static func fin(_ stream: USBHostMultiplexConnection.Stream) async throws {
        switch try await stream.readBytes(maximumBytes: 1, timeout: .seconds(5)) {
        case .end: return
        case .bytes: throw NativePeerError.invalidData
        }
    }
    static func send(_ stream: USBHostMultiplexConnection.Stream, _ bytes: Data) async throws {
        try await stream.writeBytes(bytes, timeout: .seconds(5), requireEffectAuthorization: {})
    }
    static func run() async throws {
        guard (2...3).contains(CommandLine.arguments.count), ["flow", "reverse", "reset"].contains(CommandLine.arguments[1]),
              CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "epoch-v2" else { throw NativePeerError.arguments }
        let mode = CommandLine.arguments[1]
        let profile: USBHostMultiplexConnection.LinkProfile = CommandLine.arguments.count == 3 ? .epochV2 : .rawYamuxV1
        let profileLabel = profile == .epochV2 ? "epoch-v2" : "raw-yamux-v1"
        let driver = try USBLoopbackSocketDriver(fd: acceptLoopback(profile: profileLabel))
        let carrier = USBHostByteTransport(deviceRegistryID: 1, driver: driver, requireAttachmentCurrent: {})
        let owner = try USBHostMultiplexConnection(carrier: carrier, role: mode == "flow" ? .server : .client,
            configuration: .init(linkProfile: profile))
        do {
            try await owner.start()
            let bytes: Data
            var resetStage: String?
            if mode == "flow" {
                let file = try await owner.acceptStream(priority: .bulk), control = try await owner.acceptStream()
                defer { withExtendedLifetime((file, control)) {} }
                try await read(control, expected: command); try await send(control, command)
                try await control.finishSending(); try await fin(control); try await control.closeAndAwait()
                bytes = payload(262_145)
                try await read(file, expected: bytes); try await send(file, bytes)
                try await file.finishSending(); try await fin(file); try await file.closeAndAwait()
            } else if mode == "reverse" {
                let file = try await owner.openStream(priority: .bulk), control = try await owner.openStream()
                defer { withExtendedLifetime((file, control)) {} }
                bytes = payload(65_579)
                try await send(file, bytes); try await send(control, command)
                try await control.finishSending(); try await read(control, expected: command); try await fin(control)
                try await control.closeAndAwait()
                try await file.finishSending(); try await read(file, expected: bytes); try await fin(file)
                try await file.closeAndAwait()
            } else {
                var ending: USBHostMultiplexConnection.Stream?
                var waitingAt = "open"
                do {
                    let stream = try await owner.openStream(); ending = stream
                    waitingAt = "read"
                    _ = try await stream.readBytes(maximumBytes: 1, timeout: .seconds(5))
                    throw NativePeerError.invalidData
                } catch USBLogicalStreamError.resetByPeer {
                    // A peer may refuse with RST before ACK. Unlike the state-only fixture,
                    // the real owner's open waits for ACK and must report that refusal here.
                    resetStage = waitingAt
                    if let ending { try await ending.closeAndAwait() }
                }
                guard resetStage != nil, owner.protocolSnapshot.owners == 0 else { throw NativePeerError.cleanupUnconfirmed }
                let control = try await owner.openStream()
                defer { withExtendedLifetime((ending, control)) {} }
                try await send(control, command); try await control.finishSending()
                try await read(control, expected: command); try await fin(control); try await control.closeAndAwait()
                bytes = command
            }
            guard owner.protocolSnapshot.owners == 0 else { throw NativePeerError.cleanupUnconfirmed }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var receipt: [String: Any] = ["event": "verified", "implementation": implementation, "case": mode,
                      "bytes": bytes.count, "sha256": hash, "resetObserved": resetStage != nil,
                      "linkProfile": profileLabel, "epochReady": owner.epochSnapshot?.phase == .ready]
            if let resetStage { receipt["resetStage"] = resetStage }
            try emit(receipt)
            // Data/FIN receipts were verified first. Physical EOF is only the parent's shutdown.
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while owner.terminalFailure == nil {
                guard ContinuousClock.now < end else { throw NativePeerError.timedOut }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let failure = owner.terminalFailure else { throw NativePeerError.invalidData }
            guard case USBLoopbackSocketError.ended = failure else { throw failure }
            try await owner.closeAndAwait()
            let state = owner.shutdownState
            guard state.nativeWorkersExited && state.referencesReleased && state.pumpsJoined && state.logicalOwnersReleased else { throw NativePeerError.cleanupUnconfirmed }
            try emit(["event": "closed", "readerExited": true, "nativeWorkersExited": state.nativeWorkersExited,
                      "referencesReleased": state.referencesReleased, "pumpsJoined": state.pumpsJoined,
                      "logicalOwnersReleased": state.logicalOwnersReleased, "owners": owner.protocolSnapshot.owners,
                      "linkProfile": profileLabel, "epochDispatchPending": owner.epochSnapshot?.dispatchPending == true,
                      "epochRetired": owner.epochSnapshot?.phase == .failed])
        } catch {
            do { try await owner.closeAndAwait() }
            catch let cleanup { throw PeerCleanupFailure(original: error, cleanup: cleanup) }
            throw error
        }
    }
    static func main() async {
        do { try await run() }
        catch {
            do { try FileHandle.standardError.write(contentsOf: Data("USB owner peer failed: \(error)\n".utf8)) }
            catch { exit(74) }
            exit(1)
        }
    }
}
