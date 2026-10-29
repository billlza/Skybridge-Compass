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

    func testOwnedCachesExcludeOtherAppsAndTransferRecoveryState() async throws {
        let userCaches = try makeDirectory("UserCaches")
        let bundleIdentifier = "com.skybridge.compass.pro"
        try writeFile("UserCaches/\(bundleIdentifier)/http.bin", byteCount: 7)
        try writeFile("UserCaches/SkyBridge/Avatars/avatar.jpg", byteCount: 11)
        let protectedPaths = [
            "UserCaches/AnotherApp/data.bin",
            "UserCaches/com.apple.metal/compiled.bin",
            "UserCaches/SkyBridge/ClassicInboundPartials/incoming.partial",
            "UserCaches/SkyBridge/ResumeData/transfer.json"
        ]
        for path in protectedPaths { try writeFile(path, byteCount: 23) }
        let service = ApplicationCacheService(cacheDirectories:
            ApplicationCacheService.ownedCacheDirectories(in: [userCaches], bundleIdentifier: bundleIdentifier)
        )

        let snapshot = try await service.cacheUsageSnapshot()
        XCTAssertEqual(snapshot.totalBytes, 18)
        XCTAssertEqual(snapshot.fileCount, 2)
        let cleared = try await service.clearCaches()
        XCTAssertEqual(cleared.clearedBytes, 18)
        XCTAssertEqual(cleared.removedItemCount, 2)
        for path in protectedPaths {
            XCTAssertEqual(try Data(contentsOf: temporaryRoot.appendingPathComponent(path)).count, 23)
        }
        let remaining = try await service.cacheUsageSnapshot()
        XCTAssertEqual(remaining.totalBytes, 0)
    }

    func testMissingOwnedCachesAreEmptyAndDoNotCreateDirectories() async throws {
        let userCaches = temporaryRoot.appendingPathComponent("AbsentCaches", isDirectory: true)
        let service = ApplicationCacheService(cacheDirectories:
            ApplicationCacheService.ownedCacheDirectories(in: [userCaches], bundleIdentifier: "com.skybridge.compass.pro")
        )
        let snapshot = try await service.cacheUsageSnapshot()
        XCTAssertEqual(snapshot.totalBytes, 0)
        XCTAssertEqual(snapshot.fileCount, 0)
        let result = try await service.clearCaches()
        XCTAssertEqual(result.removedItemCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userCaches.path))
    }

    func testDuplicateUserCacheLocationsAreMeasuredOnlyOnce() async throws {
        let userCaches = try makeDirectory("UserCaches")
        try writeFile("UserCaches/SkyBridge/Avatars/avatar.jpg", byteCount: 11)
        let service = ApplicationCacheService(cacheDirectories:
            ApplicationCacheService.ownedCacheDirectories(in: [userCaches, userCaches], bundleIdentifier: "com.skybridge.compass.pro")
        )
        let snapshot = try await service.cacheUsageSnapshot()
        XCTAssertEqual(snapshot.totalBytes, 11)
        XCTAssertEqual(snapshot.fileCount, 1)
    }

    func testRootSymlinkCannotMeasureOrClearItsTarget() async throws {
        let outside = try makeDirectory("Outside")
        let sentinel = try writeFile("Outside/sentinel.bin", byteCount: 31)
        let link = temporaryRoot.appendingPathComponent("CacheLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let service = ApplicationCacheService(cacheDirectories: [link])

        do {
            _ = try await service.cacheUsageSnapshot()
            XCTFail("A root symlink must not be treated as an owned cache directory.")
        } catch ApplicationCacheService.ApplicationCacheServiceError.scanFailed(let failures) {
            XCTAssertEqual(failures.count, 1)
        }
        do {
            _ = try await service.clearCaches()
            XCTFail("A root symlink must not permit deleting its target's contents.")
        } catch ApplicationCacheService.ApplicationCacheServiceError.clearFailed(let result) {
            XCTAssertEqual(result.removedItemCount, 0)
            XCTAssertEqual(result.failures.count, 1)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel).count, 31)
    }

    func testSymlinkedSkyBridgeParentCannotEscapeOwnedAvatarCache() async throws {
        let userCaches = try makeDirectory("UserCaches")
        let outside = try makeDirectory("Outside")
        let sentinel = try writeFile("Outside/Avatars/sentinel.bin", byteCount: 31)
        try FileManager.default.createSymbolicLink(
            at: userCaches.appendingPathComponent("SkyBridge"), withDestinationURL: outside
        )
        let service = ApplicationCacheService(cacheDirectories:
            ApplicationCacheService.ownedCacheDirectories(in: [userCaches], bundleIdentifier: "com.skybridge.compass.pro")
        )
        do {
            _ = try await service.clearCaches()
            XCTFail("An ancestor symlink must not redirect avatar cache clearing.")
        } catch ApplicationCacheService.ApplicationCacheServiceError.clearFailed(let result) {
            XCTAssertEqual(result.removedItemCount, 0)
            XCTAssertEqual(result.failures.count, 1)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel).count, 31)
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
