import Foundation
import XCTest
@testable import SkyBridgeCore

final class SSHKnownHostsPersistenceTests: XCTestCase {
    private static let firstEd25519Key =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINicH75EkfPRcyMeavVFJoaQoGsFQ8a+ufgODigxAa77"
    private static let secondEd25519Key =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+BA8aNQbABbDH+6CLyTPHdQA3L5Nqkwe2bU4MtzdH3"
    private static let ecdsaKey =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBH0NfOn7QeUzVKy9yRXx/dOKAvJChE+UiPJerrarBjgUdf3Yum/8dkYT10qW+LbkGjYm2Hr3iffHUQLeEVtlK+I="

    private var temporaryDirectory: URL!
    private var databaseURL: URL!
    private var integrityPersistence: ControlledIntegrityPersistence!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkyBridgeSSHKnownHostsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporaryDirectory.path
        )
        databaseURL = temporaryDirectory.appendingPathComponent("ssh-known-hosts.json")
        integrityPersistence = ControlledIntegrityPersistence(initialState: nil)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        databaseURL = nil
        temporaryDirectory = nil
        integrityPersistence = nil
        try super.tearDownWithError()
    }

    func testCorruptDatabaseFailsClosedWithoutReplacingPersistedEvidence() throws {
        let corruptData = Data("{not-json".utf8)
        try writeAuthorityData(corruptData)
        let store = makeFileStore()

        XCTAssertThrowsError(try store.allEntries()) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .invalidPersistedData)
        }
        XCTAssertThrowsError(
            try store.isTrusted(
                host: "example.test",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: String(repeating: "a", count: 64)
            )
        )
        XCTAssertThrowsError(
            try store.record(
                host: "example.test",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: String(repeating: "a", count: 64)
            )
        )
        XCTAssertEqual(try Data(contentsOf: databaseURL), corruptData)
    }

    func testExplicitResetRecoversCorruptDatabaseOnlyAfterDurableCommit() throws {
        try writeAuthorityData(Data("{not-json".utf8))
        let store = makeFileStore()

        XCTAssertThrowsError(try store.allEntries())
        try store.resetAuthorityAfterUserConfirmation()
        XCTAssertEqual(try store.allEntries(), [])

        let reloaded = makeFileStore()
        XCTAssertEqual(try reloaded.allEntries(), [])
    }

    func testFailedTOFUCommitFailsClosedAndDoesNotPublishInMemoryAuthority() throws {
        let backend = ControlledPersistence(initialData: nil)
        backend.shouldFailCommit = true
        let store = SSHKnownHostsStore(
            persistence: backend,
            integrityPersistence: ControlledIntegrityPersistence(initialState: nil)
        )

        XCTAssertThrowsError(
            try store.validationDecision(
                host: "camera.home",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: String(repeating: "b", count: 64),
                trustOnFirstUse: true
            )
        ) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .persistenceUnavailable)
        }
        XCTAssertNil(backend.snapshot())
        XCTAssertThrowsError(try store.allEntries())
    }

    func testFailedRemovalKeepsLastDurableSnapshotAndDisablesAuthority() throws {
        let existing = SSHKnownHostEntry(
            host: "192.168.1.20",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "c", count: 64)
        )
        let durableData = try encoded([existing])
        let backend = ControlledPersistence(initialData: durableData)
        let store = SSHKnownHostsStore(
            persistence: backend,
            integrityPersistence: ControlledIntegrityPersistence(initialState: nil)
        )
        backend.shouldFailCommit = true

        XCTAssertThrowsError(try store.remove(entry: existing))
        XCTAssertEqual(backend.snapshot(), durableData)
        XCTAssertThrowsError(try store.allEntries())
        XCTAssertThrowsError(
            try store.isTrusted(
                host: existing.host,
                port: existing.port,
                keyType: existing.keyType,
                fingerprint: existing.fingerprint
            )
        )
    }

    func testSuccessfulRecordIsDurableAcrossACompletelyNewStore() throws {
        let store = makeFileStore()
        let fingerprint = String(repeating: "d", count: 64)

        XCTAssertTrue(
            try store.record(
                host: "Camera.Home.",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: fingerprint.uppercased()
            )
        )
        XCTAssertFalse(
            try store.record(
                host: "camera.home",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: fingerprint
            )
        )

        let reloaded = makeFileStore()
        XCTAssertTrue(
            try reloaded.isTrusted(
                host: "CAMERA.HOME",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: fingerprint
            )
        )
        XCTAssertEqual(try reloaded.allEntries().count, 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testEquivalentIPv6SpellingsShareOneAuthority() throws {
        let store = makeFileStore()
        let fingerprint = String(repeating: "e", count: 64)
        try store.record(
            host: "[2001:0db8:0:0:0:0:0:1]",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: fingerprint
        )

        XCTAssertTrue(
            try store.isTrusted(
                host: "2001:db8::1",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: fingerprint
            )
        )
        XCTAssertEqual(try store.allEntries().first?.host, "2001:db8::1")
    }

    func testLegacyNumericIPv4SpellingsShareResolverAuthority() throws {
        let store = makeFileStore()
        let fingerprint = String(repeating: "e", count: 64)
        try store.record(
            host: "127.1",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: fingerprint
        )

        XCTAssertTrue(
            try store.isTrusted(
                host: "0x7f000001",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: fingerprint
            )
        )
        XCTAssertTrue(
            try store.isTrusted(
                host: "2130706433",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: fingerprint
            )
        )
        XCTAssertEqual(try store.allEntries().first?.host, "127.0.0.1")
    }

    func testTOFUCannotReplaceExistingKeyOrAddAnotherAlgorithm() throws {
        let store = makeFileStore()
        try store.record(
            host: "camera.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "f", count: 64)
        )

        XCTAssertEqual(
            try store.validationDecision(
                host: "CAMERA.HOME.",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: String(repeating: "1", count: 64),
                trustOnFirstUse: true
            ),
            .mismatch
        )
        XCTAssertEqual(
            try store.validationDecision(
                host: "camera.home",
                port: 22,
                keyType: "ecdsa-sha2-nistp256",
                fingerprint: String(repeating: "2", count: 64),
                trustOnFirstUse: true
            ),
            .mismatch
        )
        XCTAssertEqual(try store.allEntries().count, 1)
    }

    func testImportIsTransactionalWhenLaterEntryConflicts() throws {
        let store = makeFileStore()
        XCTAssertTrue(
            try store.addOpenSSHPublicKey(
                host: "camera.home",
                port: 22,
                openSSHPublicKey: Self.firstEd25519Key
            )
        )
        let importURL = temporaryDirectory.appendingPathComponent("conflicting-known-hosts")
        let content = """
        new-camera.home \(Self.firstEd25519Key)
        camera.home \(Self.secondEd25519Key)
        """
        try Data(content.utf8).write(to: importURL)

        XCTAssertThrowsError(try store.importKnownHostsFile(from: importURL)) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .conflictingHostKey)
        }
        XCTAssertFalse(try store.hasTrustedKey(forHost: "new-camera.home", port: 22))
        XCTAssertEqual(try store.allEntries().count, 1)

        let reloaded = makeFileStore()
        XCTAssertFalse(try reloaded.hasTrustedKey(forHost: "new-camera.home", port: 22))
        XCTAssertEqual(try reloaded.allEntries().count, 1)
    }

    func testExplicitImportAllowsAnotherAlgorithmButRejectsSameAlgorithmRotation() throws {
        let store = makeFileStore()
        XCTAssertTrue(
            try store.addOpenSSHPublicKey(
                host: "camera.home",
                port: 22,
                openSSHPublicKey: Self.firstEd25519Key
            )
        )
        XCTAssertTrue(
            try store.addOpenSSHPublicKey(
                host: "CAMERA.HOME.",
                port: 22,
                openSSHPublicKey: Self.ecdsaKey
            )
        )
        XCTAssertThrowsError(
            try store.addOpenSSHPublicKey(
                host: "camera.home",
                port: 22,
                openSSHPublicKey: Self.secondEd25519Key
            )
        ) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .conflictingHostKey)
        }
        XCTAssertEqual(try store.allEntries().count, 2)
    }

    func testAtomicSameAlgorithmRotationRequiresExpectedDurableKey() throws {
        let store = makeFileStore()
        XCTAssertTrue(
            try store.addOpenSSHPublicKey(
                host: "camera.home",
                port: 22,
                openSSHPublicKey: Self.firstEd25519Key
            )
        )

        XCTAssertTrue(
            try store.compareAndReplaceOpenSSHPublicKey(
                host: "CAMERA.HOME.",
                port: 22,
                expectedOpenSSHPublicKey: Self.firstEd25519Key,
                replacementOpenSSHPublicKey: Self.secondEd25519Key
            )
        )
        let rotatedSnapshot = try store.allEntries()
        XCTAssertEqual(rotatedSnapshot.count, 1)

        XCTAssertThrowsError(
            try store.compareAndReplaceOpenSSHPublicKey(
                host: "camera.home",
                port: 22,
                expectedOpenSSHPublicKey: Self.firstEd25519Key,
                replacementOpenSSHPublicKey: Self.secondEd25519Key
            )
        ) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .conflictingHostKey)
        }
        XCTAssertEqual(try store.allEntries(), rotatedSnapshot)

        let reloaded = makeFileStore()
        XCTAssertEqual(try reloaded.allEntries(), rotatedSnapshot)
    }

    func testRotationConflictGuidanceNeverRecommendsDeleteThenAdd() throws {
        let message = try XCTUnwrap(
            SSHKnownHostsStoreError.conflictingHostKey.errorDescription
        ).lowercased()
        XCTAssertTrue(message.contains("rotate it atomically"))
        XCTAssertTrue(message.contains("do not delete"))
    }

    func testDeletingInitializedAuthorityFailsClosedInsteadOfReenablingTOFU() throws {
        let store = makeFileStore()
        try store.record(
            host: "camera.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "4", count: 64)
        )
        try FileManager.default.removeItem(at: databaseURL)

        let reloaded = makeFileStore()
        XCTAssertThrowsError(try reloaded.allEntries()) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .invalidPersistedData)
        }
        XCTAssertThrowsError(
            try reloaded.validationDecision(
                host: "attacker.home",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: String(repeating: "5", count: 64),
                trustOnFirstUse: true
            )
        )
    }

    func testRollingBackAuthorityFileBehindProtectedGenerationFailsClosed() throws {
        let store = makeFileStore()
        try store.record(
            host: "first.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "6", count: 64)
        )
        let oldSnapshot = try Data(contentsOf: databaseURL)

        try store.record(
            host: "second.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "7", count: 64)
        )
        try writeAuthorityData(oldSnapshot)

        let reloaded = makeFileStore()
        XCTAssertThrowsError(try reloaded.allEntries()) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .invalidPersistedData)
        }
    }

    func testAuthorityRejectsGroupWritableAndHardLinkedDatabaseFiles() throws {
        let store = makeFileStore()
        try store.record(
            host: "camera.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "8", count: 64)
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o660],
            ofItemAtPath: databaseURL.path
        )
        XCTAssertThrowsError(try makeFileStore().allEntries())

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
        let hardLinkURL = temporaryDirectory.appendingPathComponent("authority-hard-link")
        try FileManager.default.linkItem(at: databaseURL, to: hardLinkURL)
        XCTAssertThrowsError(try makeFileStore().allEntries())
    }

    func testAuthorityRejectsNonPrivateContainingDirectory() throws {
        let store = makeFileStore()
        try store.record(
            host: "camera.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "9", count: 64)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: temporaryDirectory.path
        )

        XCTAssertThrowsError(try makeFileStore().allEntries()) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .invalidPersistedData)
        }
    }

    func testProtectedCommitFailureAfterFileCommitRemainsFailClosedAfterRestart() throws {
        let backend = ControlledPersistence(initialData: nil)
        let integrity = ControlledIntegrityPersistence(initialState: nil)
        let store = SSHKnownHostsStore(
            persistence: backend,
            integrityPersistence: integrity
        )
        XCTAssertEqual(try store.allEntries(), [])

        integrity.shouldFailCommit = true
        XCTAssertThrowsError(
            try store.record(
                host: "camera.home",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprint: String(repeating: "a", count: 64)
            )
        )
        XCTAssertNotNil(backend.snapshot())

        integrity.shouldFailCommit = false
        let reloaded = SSHKnownHostsStore(
            persistence: backend,
            integrityPersistence: integrity
        )
        XCTAssertThrowsError(try reloaded.allEntries()) { error in
            XCTAssertEqual(error as? SSHKnownHostsStoreError, .invalidPersistedData)
        }
    }

    func testNestedPrivateDirectoriesAndAuthorityUseRestrictiveModes() throws {
        let nestedDatabaseURL = temporaryDirectory
            .appendingPathComponent("State", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
            .appendingPathComponent("ssh-known-hosts.json", isDirectory: false)
        let nestedIntegrity = ControlledIntegrityPersistence(initialState: nil)
        let store = SSHKnownHostsStore(
            persistence: SSHKnownHostsFilePersistence(fileURL: nestedDatabaseURL),
            integrityPersistence: nestedIntegrity
        )
        XCTAssertEqual(try store.allEntries(), [])

        for directory in [
            nestedDatabaseURL.deletingLastPathComponent(),
            nestedDatabaseURL.deletingLastPathComponent().deletingLastPathComponent()
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o700)
        }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: nestedDatabaseURL.path)
        let filePermissions = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
    }

    func testLegacyUserDefaultsMigratesOnlyAfterVerifiedFileCommit() throws {
        let suiteName = "SkyBridgeSSHKnownHostsMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyKey = "legacy-known-hosts"
        let existing = SSHKnownHostEntry(
            host: "legacy.home",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: String(repeating: "3", count: 64)
        )
        defaults.set(try encoded([existing]), forKey: legacyKey)

        let store = SSHKnownHostsStore(
            persistence: SSHKnownHostsFilePersistence(fileURL: databaseURL),
            integrityPersistence: integrityPersistence,
            legacyDefaults: defaults,
            legacyStorageKey: legacyKey
        )
        XCTAssertEqual(try store.allEntries(), [existing])
        XCTAssertNil(defaults.object(forKey: legacyKey))
        XCTAssertEqual(try makeFileStore().allEntries(), [existing])
    }

    private func makeFileStore() -> SSHKnownHostsStore {
        SSHKnownHostsStore(
            persistence: SSHKnownHostsFilePersistence(fileURL: databaseURL),
            integrityPersistence: integrityPersistence
        )
    }

    private func encoded(_ entries: [SSHKnownHostEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entries)
    }

    private func writeAuthorityData(_ data: Data) throws {
        try data.write(to: databaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }
}

private final class ControlledPersistence: SSHKnownHostsPersistenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var commitFailureEnabled = false

    var shouldFailCommit: Bool {
        get { lock.withLock { commitFailureEnabled } }
        set { lock.withLock { commitFailureEnabled = newValue } }
    }

    init(initialData: Data?) {
        data = initialData
    }

    func loadData() throws -> Data? {
        lock.withLock { data }
    }

    func commitAndReload(_ data: Data) throws -> Data {
        try lock.withLock {
            if commitFailureEnabled {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            self.data = data
            return data
        }
    }

    func snapshot() -> Data? {
        lock.withLock { data }
    }
}

private final class ControlledIntegrityPersistence: SSHKnownHostsIntegrityPersistenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SSHKnownHostsIntegrityState?
    private var commitFailureEnabled = false

    var shouldFailCommit: Bool {
        get { lock.withLock { commitFailureEnabled } }
        set { lock.withLock { commitFailureEnabled = newValue } }
    }

    init(initialState: SSHKnownHostsIntegrityState?) {
        state = initialState
    }

    func loadState() throws -> SSHKnownHostsIntegrityState? {
        lock.withLock { state }
    }

    func commitAndReload(
        _ state: SSHKnownHostsIntegrityState
    ) throws -> SSHKnownHostsIntegrityState {
        try lock.withLock {
            if commitFailureEnabled {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            self.state = state
            return state
        }
    }
}
