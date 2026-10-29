import Foundation
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport

@main enum USBHostBootstrapChecks {
    static func response(_ stream: USBHostMultiplexConnection.Stream, bytes: Data) async throws {
        _ = try await stream.readFrame(maximumBytes: 65_536, timeout: .seconds(2))
        try await stream.writeFrame(bytes, timeout: .seconds(2), requireEffectAuthorization: {})
        try await stream.finishSending()
        guard case .end = try await stream.readBytes(maximumBytes: 1, timeout: .seconds(2)) else {
            throw MultiplexFixtureError.check("Requester sent bytes after one request")
        }
        try await stream.closeAndAwait()
    }
    static func channel(_ fixture: USBMultiplexFixture,
                        authority: @escaping @Sendable () throws -> Void = {}) throws -> USBHostBootstrapChannel {
        try USBHostBootstrapChannel(connection: fixture.a, attachmentNonce: UUID(), requireAttachmentCurrent: authority)
    }
    static func expect(_ expected: USBHostBootstrapError, _ action: () async throws -> Void) async throws {
        do { try await action() } catch let actual as USBHostBootstrapError {
            try usbCheck(actual == expected, "Wrong bootstrap failure"); return
        }
        throw MultiplexFixtureError.check("Expected bootstrap failure")
    }
    static func oneFreshStreamPerExchange(_ profile: USBHostMultiplexConnection.LinkProfile = .rawYamuxV1) async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: profile)); try await f.start(); let c = try channel(f)
        var ids = Set<UInt32>()
        for size in [1, 65_536, 3] {
            let bytes = usbPattern(size), request = Data([11, 12])
            let reply = Task { try await c.exchange(request, timeout: .seconds(3)) }
            let peer = try await f.b.acceptStream()
            let received = try await peer.readFrame(timeout: .seconds(2))
            try usbCheck(received == request, "Request changed")
            try await peer.writeFrame(bytes, timeout: .seconds(2), requireEffectAuthorization: {})
            try await peer.finishSending()
            guard case .end = try await peer.readBytes(maximumBytes: 1, timeout: .seconds(2)) else {
                throw MultiplexFixtureError.check("No requester FIN")
            }
            try await peer.closeAndAwait()
            let value = try await reply.value
            try usbCheck(value.body == bytes && ids.insert(value.streamID).inserted && value.streamID == peer.id,
                         "Repeated stream or response loss")
            try usbCheck(value.openingDuration > .zero && !c.cleanupRequired, "False cleanup/latency")
        }
        try await f.sibling(); try await f.close()
    }
    static func requesterDoesNotFINWhileConsentPending(_ profile: USBHostMultiplexConnection.LinkProfile = .rawYamuxV1) async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: profile)); try await f.start(); let c = try channel(f)
        let result = Task { try await c.exchange(Data([1]), timeout: .seconds(2)) }
        let peer = try await f.b.acceptStream(); _ = try await peer.readFrame(timeout: .seconds(1))
        // Inspect emitted protocol frames while the responder has no response.
        // A FIN here would invalidate Android's consent transaction.
        try await Task.sleep(for: .milliseconds(40))
        let earlyFIN = f.nativeA.state.withLock { $0.headers.contains { $0.streamID == peer.id && ($0.flags & USBLogicalStreamWire.fin) != 0 } }
        try usbCheck(!earlyFIN, "Requester prematurely closed consent exchange")
        try await peer.writeFrame(Data([8]), timeout: .seconds(1), requireEffectAuthorization: {})
        try await peer.finishSending()
        guard case .end = try await peer.readBytes(maximumBytes: 1, timeout: .seconds(1)) else { throw MultiplexFixtureError.check("No final FIN") }
        try await peer.closeAndAwait(); _ = try await result.value; try await f.close()
    }
    static func concurrentExchangeIsRejected() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let c = try channel(f)
        let first = Task { try await c.exchange(Data([1]), timeout: .seconds(2)) }
        let peer = try await f.b.acceptStream()
        try await expect(.exchangeInProgress) { _ = try await c.exchange(Data([2]), timeout: .seconds(1)) }
        try await response(peer, bytes: Data([3])); _ = try await first.value
        try await f.close()
    }
    static func responseTailRejected() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let c = try channel(f)
        let result = Task { try await c.exchange(Data([1]), timeout: .seconds(2)) }
        let peer = try await f.b.acceptStream(); _ = try await peer.readFrame(timeout: .seconds(1))
        var bytes = try P2PControlFramePolicy.frame(body: Data([3])); bytes.append(77)
        try await peer.writeBytes(bytes, timeout: .seconds(1), requireEffectAuthorization: {})
        try await expect(.trailingResponseBytes) { _ = try await result.value }
        try await peer.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func cancellationRetiresExactStream() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let c = try channel(f)
        let result = Task { try await c.exchange(Data([1]), timeout: .seconds(2)) }
        let peer = try await f.b.acceptStream(); _ = try await peer.readFrame(timeout: .seconds(1))
        result.cancel()
        do { _ = try await result.value; throw MultiplexFixtureError.check("Cancelled exchange succeeded") }
        catch is CancellationError { try usbCheck(!c.cleanupRequired, "Cancellation lost logical cleanup") }
        try await peer.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func wholeResponseDeadline() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let c = try channel(f)
        let result = Task { try await c.exchange(Data([1]), timeout: .milliseconds(80)) }
        let peer = try await f.b.acceptStream(); _ = try await peer.readFrame(timeout: .seconds(1))
        try await peer.writeBytes(Data([0, 0, 0, 2, 99]), timeout: .seconds(1), requireEffectAuthorization: {})
        try await usbExpect(USBHostMultiplexError.timedOut) { _ = try await result.value }
        try await peer.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func revocationBeforeResponseIsNotSuccess() async throws {
        let f = try USBMultiplexFixture(); try await f.start()
        let valid = OSAllocatedUnfairLock(initialState: true)
        let c = try channel(f) { if !valid.withLock({ $0 }) { throw MultiplexFixtureError.revoked } }
        let result = Task { try await c.exchange(Data([1]), timeout: .seconds(2)) }
        let peer = try await f.b.acceptStream(); _ = try await peer.readFrame(timeout: .seconds(1))
        valid.withLock { $0 = false }
        try await peer.writeFrame(Data([8]), timeout: .seconds(1), requireEffectAuthorization: {})
        try await usbExpect(MultiplexFixtureError.revoked) { _ = try await result.value }
        try await peer.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func malformedLengthDoesNotEscapeBound() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let c = try channel(f)
        let result = Task { try await c.exchange(Data([1]), timeout: .seconds(2)) }
        let peer = try await f.b.acceptStream(); _ = try await peer.readFrame(timeout: .seconds(1))
        try await peer.writeBytes(Data([0, 1, 0, 1]), timeout: .seconds(1), requireEffectAuthorization: {})
        try await usbExpect(USBHostMultiplexError.invalidByteCount) { _ = try await result.value }
        try await peer.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func fullApprovalWindowAndUpperBound() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let c = try channel(f)
        for invalid: Duration in [.zero, .seconds(316)] {
            try await usbExpect(USBHostMultiplexError.invalidTimeout) { _ = try await c.exchange(Data([1]), timeout: invalid) }
        }
        let result = Task { try await c.exchange(Data([1]), timeout: .seconds(315)) }
        let peer = try await f.b.acceptStream(); try await response(peer, bytes: Data([7]))
        let received = try await result.value
        try usbCheck(received.body == Data([7]), "Full confirmation window rejected")
        try await f.close()
    }
    static func cleanupTimeoutRetainsStreamAndForbidsReplay(_ profile: USBHostMultiplexConnection.LinkProfile = .rawYamuxV1) async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: profile)); try await f.start(); let c = try channel(f), gate = USBFixtureGate()
        f.nativeA.state.withLock { state in state.beforeWrite = { bytes in
            switch profile {
            case .rawYamuxV1:
                let header = try USBLogicalStreamWire.decodeHeader(Data(bytes.prefix(12)))
                if header.type == .data { try gate.wait() }
            case .epochV2:
                // This two-byte request and its envelope fit in one native write.
                // Initial link control records must not trigger the data gate.
                var decoder = USBLinkWire.Decoder()
                for byte in bytes {
                    if case .record(let record) = try decoder.accept(byte), record.kind == .data {
                        let header = try USBLogicalStreamWire.decodeHeader(Data(record.body.prefix(12)))
                        if header.type == .data { try gate.wait() }
                    }
                }
            }
        } }
        let result = Task { try await c.exchange(Data([1, 2]), timeout: .seconds(3)) }
        let peer = try await f.b.acceptStream()
        try await usbEventually { gate.entered.withLock { $0 } }
        result.cancel()
        do {
            do { _ = try await result.value; throw MultiplexFixtureError.check("Unknown cleanup became success") }
            catch let failure as USBHostBootstrapCleanupFailure {
                try usbCheck(failure.cleanup as? USBHostMultiplexError == .cleanupUnconfirmed && c.cleanupRequired,
                             "Unknown cleanup discarded its owner")
            }
            try await expect(.retired) { _ = try await c.exchange(Data([9]), timeout: .seconds(1)) }
        } catch { gate.release(); throw error }
        gate.release(); f.nativeA.state.withLock { $0.beforeWrite = nil }
        try await c.finishCleanup()
        try usbCheck(!c.cleanupRequired, "Retained stream did not finish cleanup")
        try await expect(.retired) { _ = try await c.exchange(Data([10]), timeout: .seconds(1)) }
        try await peer.closeAndAwait(); try await f.close()
    }
    static func main() async {
        do {
            let checks: [(String, () async throws -> Void)] = [
                ("fresh-stream-complete-response-and-FIN", { try await oneFreshStreamPerExchange() }),
                ("consent-keeps-request-half-open", { try await requesterDoesNotFINWhileConsentPending() }),
                ("concurrent-bootstrap-rejected", concurrentExchangeIsRejected),
                ("trailing-response-bytes-rejected", responseTailRejected),
                ("cancellation-is-stream-local", cancellationRetiresExactStream),
                ("whole-frame-deadline", wholeResponseDeadline),
                ("revoked-attachment-cannot-publish-response", revocationBeforeResponseIsNotSuccess),
                ("bounded-response-length", malformedLengthDoesNotEscapeBound),
                ("full-approval-window-is-bounded", fullApprovalWindowAndUpperBound),
                ("unconfirmed-cleanup-forbids-replay", { try await cleanupTimeoutRetainsStreamAndForbidsReplay() }),
                ("epoch-v2-fresh-stream-complete-response-and-FIN", { try await oneFreshStreamPerExchange(.epochV2) }),
                ("epoch-v2-consent-keeps-request-half-open", { try await requesterDoesNotFINWhileConsentPending(.epochV2) }),
                ("epoch-v2-unconfirmed-cleanup-forbids-replay", { try await cleanupTimeoutRetainsStreamAndForbidsReplay(.epochV2) })]
            for (name, check) in checks { try await check(); print("PASS \(name)") }
            print("PASS \(checks.count) native bootstrap groups")
        } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
}
