import XCTest
@testable import SkyBridgeCore

/// Regression coverage for the macOS Keychain authorization-panel storm.
///
/// Two defects combined into a loop that made the app unusable at launch:
/// 1. `DeviceIdentityKeyManager` wrote its identity cache but only *read* it under
///    `useInMemoryKeychain`, so every discovery batch, presence heartbeat and
///    advertisement replayed the full Keychain lookup plus the legacy-domain
///    migration scan (which reads item data and therefore raises the macOS ACL
///    authorization panel).
/// 2. `DeviceDiscoveryManagerOptimized.flushPendingUpdates` retained the pending
///    batch after an identity-resolution failure with no backoff, so every Bonjour
///    result change re-attempted that same lookup immediately.
@available(macOS 14.0, *)
final class IdentityResolutionKeychainStormTests: XCTestCase {

    // MARK: - Discovery batch backoff

    func testIdentityResolutionBackoffIsMonotonicAndBounded() {
        let delays = (0..<8).map {
            DeviceDiscoveryManagerOptimized.identityResolutionBackoffDelay(
                forFailureCount: $0
            )
        }

        XCTAssertEqual(delays[0], 2)
        XCTAssertEqual(delays[1], 5)
        XCTAssertEqual(delays[2], 15)
        XCTAssertEqual(delays[3], 30)

        for index in delays.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(
                delays[index],
                delays[index - 1],
                "退避间隔不得随失败次数变小，否则失败越多重试越猛"
            )
        }

        let ceiling = delays[4]
        XCTAssertEqual(ceiling, 60)
        for delay in delays.dropFirst(4) {
            XCTAssertEqual(
                delay,
                ceiling,
                "持续失败必须收敛到固定上限，既不放弃恢复也不再加速重试"
            )
        }
    }

    func testIdentityResolutionBackoffNeverReachesZero() {
        for failureCount in 0..<64 {
            XCTAssertGreaterThan(
                DeviceDiscoveryManagerOptimized.identityResolutionBackoffDelay(
                    forFailureCount: failureCount
                ),
                0,
                "退避间隔为 0 等于没有退避，会退化成每个 Bonjour 事件一次 Keychain 访问"
            )
        }
    }

    func testDiscoveryBatchGatesIdentityResolutionBehindBackoffWindow() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )
        let flush = try sourceSlice(
            of: source,
            from: "private func flushPendingUpdates() async {",
            to: "let updates = pendingUpdates"
        )

        let gate = try XCTUnwrap(
            flush.range(of: "if let retryNotBefore = identityResolutionRetryNotBefore"),
            "身份解析必须先过退避闸门，再触碰 Keychain"
        )
        let resolution = try XCTUnwrap(
            flush.range(of: "SelfIdentityProvider.shared"),
            "批处理必须仍通过 SelfIdentityProvider 解析本机身份"
        )
        XCTAssertLessThan(
            gate.lowerBound,
            resolution.lowerBound,
            "退避判断必须出现在身份解析之前，否则退避无法阻止 Keychain 访问"
        )
        XCTAssertTrue(
            flush.contains("identityResolutionFailureCount += 1"),
            "失败必须累计，否则退避永远停留在首个间隔"
        )
        XCTAssertTrue(
            flush.contains("identityResolutionFailureCount = 0"),
            "成功必须复位退避状态"
        )
    }

    // MARK: - Identity authority cache

    func testIdentityAuthorityCacheIsNotGatedOnInMemoryKeychain() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )

        XCTAssertFalse(
            source.contains("if Self.useInMemoryKeychain, let cached = cachedKeyInfo {"),
            "生产环境必须命中身份缓存；否则每次解析都会重放 Keychain 与 legacy 迁移扫描"
        )
        XCTAssertFalse(
            source.contains("if Self.useInMemoryKeychain, let cachedKeyInfo {"),
            "strict 读取路径同样必须命中缓存"
        )
        XCTAssertTrue(source.contains("if let cached = cachedKeyInfo {"))
        XCTAssertTrue(source.contains("if let cachedKeyInfo {"))
    }

    /// The cache may only ever serve a previously validated authority. Deletion is
    /// refused by design, so a resolved authority must stay identical for the whole
    /// process; a cache that could hand back a different tuple would be a security
    /// regression rather than a performance win.
    func testResolvedIdentityAuthorityIsStableAcrossRepeatedResolution() async throws {
        let first = try await DeviceIdentityKeyManager.shared.getOrCreateIdentityKey()
        let second = try await DeviceIdentityKeyManager.shared.getOrCreateIdentityKey()
        let strict = try await DeviceIdentityKeyManager.shared.existingIdentityKeyInfoStrict()

        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertEqual(first.pubKeyFP, second.pubKeyFP)
        XCTAssertEqual(strict?.deviceId, first.deviceId)
        XCTAssertEqual(strict?.publicKey, first.publicKey)
        XCTAssertEqual(
            first.pubKeyFP,
            DeviceIdentityAuthorityRecord.fingerprint(for: first.publicKey),
            "缓存返回的指纹必须仍与其公钥匹配"
        )
    }

    func testIdentityAuthorityDeletionRemainsRefused() async throws {
        let before = try await DeviceIdentityKeyManager.shared.getOrCreateIdentityKey()

        do {
            try await DeviceIdentityKeyManager.shared.deleteIdentityKey()
            XCTFail("身份删除必须被拒绝，否则进程内缓存会变成陈旧数据")
        } catch DeviceIdentityKeyError.keyRotationFailed {
            // Expected: deletion requires an explicit reset + re-pinning transaction.
        } catch {
            XCTFail("身份删除必须保持 typed 拒绝: \(error)")
        }

        let after = try await DeviceIdentityKeyManager.shared.getOrCreateIdentityKey()
        XCTAssertEqual(before.deviceId, after.deviceId)
    }

    // MARK: - Helpers

    private func sourceSlice(
        of source: String,
        from start: String,
        to end: String
    ) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw XCTSkip("Source anchor not found: \(start)")
        }
        guard let endRange = source.range(
            of: end,
            range: startRange.upperBound..<source.endIndex
        ) else {
            throw XCTSkip("Source anchor not found: \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
