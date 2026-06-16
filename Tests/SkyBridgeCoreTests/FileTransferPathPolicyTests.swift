import XCTest
@testable import SkyBridgeCore

final class FileTransferPathPolicyTests: XCTestCase {
    func testSanitizedFileNameFallsBackForUnsafePathInput() {
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("../secret.txt"), "SkyBridgeFile")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("/tmp/nested/report.pdf"), "SkyBridgeFile")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("nested\\report.pdf"), "SkyBridgeFile")
    }

    func testSanitizedFileNameFallsBackForEmptyBasename() {
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("   "), "SkyBridgeFile")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("/"), "SkyBridgeFile")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName("."), "SkyBridgeFile")
        XCTAssertEqual(FileTransferPathPolicy.sanitizedFileName(".."), "SkyBridgeFile")
    }

    func testValidatedFileNameRejectsTraversalAndPathSeparators() throws {
        let unsafeNames = [
            "../secret.txt",
            "/tmp/nested/report.pdf",
            "nested/report.pdf",
            "nested\\report.pdf",
            ".",
            "..",
            "report\u{2044}secret.txt",
            "report\u{2215}secret.txt"
        ]

        for name in unsafeNames {
            XCTAssertThrowsError(try FileTransferPathPolicy.validatedFileName(name), name)
        }
        XCTAssertEqual(try FileTransferPathPolicy.validatedFileName(" report.txt "), "report.txt")
    }

    func testUniqueDestinationURLAddsSuffixWhenFileExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("report.txt")
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let candidate = try FileTransferPathPolicy.uniqueDestinationURL(
            baseDirectory: directory,
            fileName: "report.txt"
        )

        XCTAssertEqual(candidate.deletingLastPathComponent(), directory)
        XCTAssertEqual(candidate.lastPathComponent, "report (1).txt")
    }

    func testUniqueDestinationURLRejectsUnsafeFileName() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(
            try FileTransferPathPolicy.uniqueDestinationURL(
                baseDirectory: directory,
                fileName: "../report.txt"
            )
        )
    }
}
