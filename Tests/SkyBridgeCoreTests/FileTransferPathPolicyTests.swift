import XCTest
@testable import SkyBridgeCore

final class FileTransferPathPolicyTests: XCTestCase {
    func testSanitizedFileNameDropsTraversalComponents() {
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("../secret.txt"), "secret.txt")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("/tmp/nested/report.pdf"), "report.pdf")
    }

    func testSanitizedFileNameFallsBackForEmptyBasename() {
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("   "), "SkyBridgeFile")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("/"), "SkyBridgeFile")
    }

    func testUniqueDestinationURLAddsSuffixWhenFileExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("report.txt")
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let candidate = FileTransferPathPolicy.uniqueDestinationURL(
            baseDirectory: directory,
            fileName: "../report.txt"
        )

        XCTAssertEqual(candidate.deletingLastPathComponent(), directory)
        XCTAssertEqual(candidate.lastPathComponent, "report (1).txt")
    }
}
