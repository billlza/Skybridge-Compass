import XCTest
@testable import SkyBridgeCore

final class ApplicationCacheServiceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationCacheServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testCacheUsageScansNestedFiles() async throws {
        let cacheRoot = try makeDirectory("CacheRoot")
        let nested = try makeDirectory("CacheRoot/Nested")
        try writeFile("CacheRoot/root.bin", byteCount: 7)
        try writeFile("CacheRoot/Nested/child.bin", byteCount: 11)

        let service = ApplicationCacheService(cacheDirectories: [cacheRoot])

        let snapshot = try await service.cacheUsageSnapshot()

        XCTAssertEqual(snapshot.totalBytes, 18)
        XCTAssertEqual(snapshot.fileCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testClearCachesRemovesContentsButPreservesCacheRoot() async throws {
        let cacheRoot = try makeDirectory("CacheRoot")
        try makeDirectory("CacheRoot/Nested")
        try writeFile("CacheRoot/root.bin", byteCount: 5)
        try writeFile("CacheRoot/Nested/child.bin", byteCount: 13)

        let service = ApplicationCacheService(cacheDirectories: [cacheRoot])

        let result = try await service.clearCaches()
        let remainingChildren = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)

        XCTAssertEqual(result.clearedBytes, 18)
        XCTAssertEqual(result.removedItemCount, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path))
        XCTAssertTrue(remainingChildren.isEmpty)
    }

    func testFileCacheRootFailsExplicitly() async throws {
        let invalidRoot = try writeFile("not-a-directory.bin", byteCount: 3)
        let service = ApplicationCacheService(cacheDirectories: [invalidRoot])

        do {
            _ = try await service.cacheUsageSnapshot()
            XCTFail("Expected file roots to fail instead of being reported as an empty cache.")
        } catch ApplicationCacheService.ApplicationCacheServiceError.scanFailed(let failures) {
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures[0].operation, .measure)
            XCTAssertEqual(failures[0].path, invalidRoot.path)
        }
    }

    @discardableResult
    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ relativePath: String, byteCount: Int) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x2A, count: byteCount).write(to: url)
        return url
    }
}
