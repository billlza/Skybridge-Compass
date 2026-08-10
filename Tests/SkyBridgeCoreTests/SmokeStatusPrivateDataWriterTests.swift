import Darwin
import Foundation
import XCTest
@testable import SkyBridgeSmokeSupport

final class SmokeStatusPrivateDataWriterTests: XCTestCase {
    private var privateDirectory: URL!

    override func setUpWithError() throws {
        privateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-private-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(privateDirectory.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    override func tearDownWithError() throws {
        if let privateDirectory {
            try FileManager.default.removeItem(at: privateDirectory)
        }
        privateDirectory = nil
    }

    func testCreatesExactPrivateRegularFile() throws {
        let output = privateDirectory.appendingPathComponent("new.json", isDirectory: false)
        let expected = Data("new-private-data".utf8)

        try SmokeStatusFileAppender.replacePrivateData(
            expected,
            at: output,
            protection: .completeUntilFirstUserAuthentication
        )

        XCTAssertEqual(try Data(contentsOf: output), expected)
        try assertPrivateRegularFile(output, expectedByteCount: expected.count)
    }

    func testAtomicallyReplacesExistingPrivateRegularFile() throws {
        let output = privateDirectory.appendingPathComponent("existing.json", isDirectory: false)
        try Data("old".utf8).write(to: output)
        guard Darwin.chmod(output.path, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let originalInode = try fileMetadata(output).st_ino
        let expected = Data("replacement-private-data".utf8)

        try SmokeStatusFileAppender.replacePrivateData(expected, at: output)

        XCTAssertEqual(try Data(contentsOf: output), expected)
        try assertPrivateRegularFile(output, expectedByteCount: expected.count)
        XCTAssertNotEqual(try fileMetadata(output).st_ino, originalInode)
        XCTAssertEqual(try directoryEntries(), ["existing.json"])
    }

    func testReplacesPreexistingWorldReadableFileWithExactPrivateMode() throws {
        let output = privateDirectory.appendingPathComponent("permissive.json", isDirectory: false)
        try Data("old-public-data".utf8).write(to: output)
        guard Darwin.chmod(output.path, mode_t(0o644)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let expected = Data("new-private-data".utf8)

        try SmokeStatusFileAppender.replacePrivateData(expected, at: output)

        XCTAssertEqual(try Data(contentsOf: output), expected)
        try assertPrivateRegularFile(output, expectedByteCount: expected.count)
    }

    func testRejectsSymbolicLinkWithoutChangingItsTarget() throws {
        let victim = privateDirectory.appendingPathComponent("victim.json", isDirectory: false)
        let output = privateDirectory.appendingPathComponent("linked.json", isDirectory: false)
        let victimData = Data("must-remain".utf8)
        try victimData.write(to: victim)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: victim)

        XCTAssertThrowsError(
            try SmokeStatusFileAppender.replacePrivateData(Data("replacement".utf8), at: output)
        )
        XCTAssertEqual(try Data(contentsOf: victim), victimData)

        var metadata = stat()
        XCTAssertEqual(Darwin.lstat(output.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
    }

    func testRejectsNonRegularDestination() throws {
        let output = privateDirectory.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try SmokeStatusFileAppender.replacePrivateData(Data("replacement".utf8), at: output)
        )

        var metadata = stat()
        XCTAssertEqual(Darwin.lstat(output.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
    }

    func testRejectsPermissiveParentWithoutChangingItsBoundary() throws {
        let output = privateDirectory.appendingPathComponent("output.json", isDirectory: false)
        guard Darwin.chmod(privateDirectory.path, mode_t(0o755)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        XCTAssertThrowsError(
            try SmokeStatusFileAppender.replacePrivateData(Data("private".utf8), at: output)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        var metadata = stat()
        XCTAssertEqual(Darwin.lstat(privateDirectory.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o755))

        guard Darwin.chmod(privateDirectory.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func testRejectsOversizedDataWithoutLeavingOutputOrTemporaryFile() throws {
        let output = privateDirectory.appendingPathComponent("oversized.json", isDirectory: false)
        let oversized = Data(repeating: 0x41, count: 1_048_577)

        XCTAssertThrowsError(try SmokeStatusFileAppender.replacePrivateData(oversized, at: output)) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EFBIG))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try directoryEntries(), [])
    }

    private func assertPrivateRegularFile(_ url: URL, expectedByteCount: Int) throws {
        let metadata = try fileMetadata(url)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_uid, Darwin.geteuid())
        XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(metadata.st_mode & mode_t(0o7777), mode_t(0o600))
        XCTAssertEqual(metadata.st_size, off_t(expectedByteCount))
    }

    private func fileMetadata(_ url: URL) throws -> stat {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata
    }

    private func directoryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: privateDirectory.path).sorted()
    }
}
