import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import SkyBridgeCore

final class BoundSessionEvidenceJournalV2Tests: XCTestCase {
    func testExactV2DigestChainPersistsAndRecoversFromDescriptors() throws {
        let root = try makePrivateDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let identity = digest("identity-a")
        let journal = try BoundSessionEvidenceJournalV2(
            rootURL: root,
            identityFingerprint: identity
        )
        let firstSubject = digest("message-a")
        let first = try journal.append(
            eventType: .wireMessageAVerified,
            direction: .initiatorToResponder,
            subjectSHA256: firstSubject,
            wireSHA256: firstSubject,
            describedAt: try date("2026-08-30T12:00:01Z")
        )
        let secondSubject = digest("finished")
        let second = try journal.append(
            eventType: .wireFinishedVerified,
            direction: .initiatorToResponder,
            subjectSHA256: secondSubject,
            wireSHA256: secondSubject,
            describedAt: try date("2026-08-30T12:00:02Z")
        )

        let endpointID = BoundSessionEvidenceJournalV2.endpointID(for: identity)
        XCTAssertEqual(
            first.eventSHA256,
            independentEventDigest(
                endpointID: endpointID,
                sequence: 1,
                previous: nil,
                eventType: "wire_message_a_verified",
                direction: 1,
                subject: firstSubject,
                wire: firstSubject
            )
        )
        XCTAssertEqual(
            second.eventSHA256,
            independentEventDigest(
                endpointID: endpointID,
                sequence: 2,
                previous: first.eventSHA256,
                eventType: "wire_finished_verified",
                direction: 1,
                subject: secondSubject,
                wire: secondSubject
            )
        )

        let beforeRestart = journal.snapshot()
        let recovered = try BoundSessionEvidenceJournalV2(
            rootURL: root,
            identityFingerprint: identity
        ).snapshot()
        XCTAssertEqual(recovered, beforeRestart)
        XCTAssertEqual(recovered.events.map(\.sequence), [1, 2])
        XCTAssertEqual(try dedicatedJournalFileNames(in: root).count, 3)
    }

    func testDirectorySyncUnknownOutcomeRetriesOnlyExactSameEventAndPath() throws {
        let root = try makePrivateDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let identity = digest("identity-b")
        let firstJournal = try BoundSessionEvidenceJournalV2(
            rootURL: root,
            identityFingerprint: identity
        )
        _ = try firstJournal.append(
            eventType: .wireMessageBVerified,
            direction: .responderToInitiator,
            subjectSHA256: digest("message-b"),
            wireSHA256: digest("message-b"),
            describedAt: try date("2026-08-30T12:01:01Z")
        )

        let retryJournal = try BoundSessionEvidenceJournalV2(
            rootURL: root,
            identityFingerprint: identity,
            faultsForTesting: [.eventDirectorySync(sequence: 2)]
        )
        let receipt = digest("receipt")
        XCTAssertThrowsError(
            try retryJournal.append(
                eventType: .receiptVerified,
                direction: .responderToInitiator,
                subjectSHA256: receipt,
                wireSHA256: receipt,
                describedAt: try date("2026-08-30T12:01:02Z")
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionEvidenceJournalV2Error,
                .injectedFault("event directory sync")
            )
        }
        let namesAfterUnknownOutcome = try dedicatedJournalFileNames(in: root)
        XCTAssertTrue(namesAfterUnknownOutcome.contains("event-00000000000000000002.bsev2"))
        XCTAssertEqual(namesAfterUnknownOutcome.count, 3)

        XCTAssertThrowsError(
            try retryJournal.append(
                eventType: .receiptIssued,
                direction: .responderToInitiator,
                subjectSHA256: digest("different"),
                wireSHA256: digest("different")
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionEvidenceJournalV2Error,
                .pendingCommitRequiresExactRetry
            )
        }

        let retried = try retryJournal.retryPendingCommit()
        XCTAssertEqual(retried.sequence, 2)
        XCTAssertEqual(retried.eventType, .receiptVerified)
        XCTAssertEqual(try dedicatedJournalFileNames(in: root), namesAfterUnknownOutcome)

        let recovered = try BoundSessionEvidenceJournalV2(
            rootURL: root,
            identityFingerprint: identity
        ).snapshot()
        XCTAssertEqual(recovered.events.count, 2)
        XCTAssertEqual(recovered.events[1], retried)
    }

    func testPrivateRootSymlinkPartialConflictAndCapacityFailClosed() throws {
        let publicRoot = try makeDirectory(permissions: 0o755)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: publicRoot)) }
        XCTAssertThrowsError(
            try BoundSessionEvidenceJournalV2(
                rootURL: publicRoot,
                identityFingerprint: digest("identity-c")
            )
        ) { error in
            guard case BoundSessionEvidenceJournalV2Error.invalidRoot = error else {
                return XCTFail("expected private-root rejection, got \(error)")
            }
        }

        let root = try makePrivateDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let symlink = root.deletingLastPathComponent()
            .appendingPathComponent("journal-link-\(UUID().uuidString)")
        XCTAssertEqual(Darwin.symlink(root.path, symlink.path), 0)
        defer { XCTAssertEqual(Darwin.unlink(symlink.path), 0) }
        XCTAssertThrowsError(
            try BoundSessionEvidenceJournalV2(
                rootURL: symlink,
                identityFingerprint: digest("identity-c")
            )
        )

        let partialRoot = try makePrivateDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: partialRoot)) }
        try Data([0x01]).write(
            to: partialRoot.appendingPathComponent("event-00000000000000000001.bsev2"),
            options: .withoutOverwriting
        )
        XCTAssertThrowsError(
            try BoundSessionEvidenceJournalV2(
                rootURL: partialRoot,
                identityFingerprint: digest("identity-c")
            )
        ) { error in
            guard case BoundSessionEvidenceJournalV2Error.corruptJournal = error else {
                return XCTFail("expected partial-journal rejection, got \(error)")
            }
        }

        let capacityRoot = try makePrivateDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: capacityRoot)) }
        let journal = try BoundSessionEvidenceJournalV2(
            rootURL: capacityRoot,
            identityFingerprint: digest("identity-capacity")
        )
        for index in 0..<128 {
            let subject = digest("subject-\(index)")
            _ = try journal.append(
                eventType: .transferStarted,
                direction: .initiatorToResponder,
                subjectSHA256: subject,
                wireSHA256: nil,
                describedAt: try date("2026-08-30T12:02:00Z")
            )
        }
        XCTAssertThrowsError(
            try journal.append(
                eventType: .transferCompleted,
                direction: .initiatorToResponder,
                subjectSHA256: digest("overflow"),
                wireSHA256: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionEvidenceJournalV2Error,
                .capacityExceeded
            )
        }
    }

    private func independentEventDigest(
        endpointID: String,
        sequence: UInt64,
        previous: Data?,
        eventType: String,
        direction: UInt8,
        subject: Data,
        wire: Data?
    ) -> Data {
        var bytes = Data("policy-purpose-bound-session/endpoint-event/v2\0".utf8)
        append(UInt16(endpointID.utf8.count), to: &bytes)
        bytes.append(Data(endpointID.utf8))
        append(sequence, to: &bytes)
        bytes.append(previous ?? Data(repeating: 0, count: 32))
        append(UInt16(eventType.utf8.count), to: &bytes)
        bytes.append(Data(eventType.utf8))
        bytes.append(direction)
        bytes.append(subject)
        bytes.append(wire ?? Data(repeating: 0, count: 32))
        return Data(SHA256.hash(data: bytes))
    }

    private func append<Integer: FixedWidthInteger>(
        _ value: Integer,
        to data: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func digest(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func makePrivateDirectory() throws -> URL {
        try makeDirectory(permissions: 0o700)
    }

    private func makeDirectory(permissions: mode_t) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bound-session-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
        guard chmod(root.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return root
    }

    private func dedicatedJournalFileNames(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }
}
