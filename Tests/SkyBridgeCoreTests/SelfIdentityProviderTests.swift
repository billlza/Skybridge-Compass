import XCTest
@testable import SkyBridgeCore
import CryptoKit

/// SelfIdentityProvider 单元测试
/// 验证本机强身份生成、持久化和判定逻辑
@available(macOS 14.0, *)
final class SelfIdentityProviderTests: XCTestCase {
    private enum FixtureError: Error {
        case authorityUnavailable
    }

    private static let deterministicIdentity = SelfIdentitySnapshot(
        deviceId: "11111111-1111-4111-8111-111111111111",
        pubKeyFP: String(repeating: "a", count: 64),
        macSet: ["02:11:22:33:44:55"]
    )
    private static let localNameCollisionProbe = {
        let host = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "SkyBridgeLocalNameProbe" : host
    }()
    
 // MARK: - 基础功能测试
    
    /// 测试：首次启动生成并持久化 deviceId
    func testDeviceIdGenerationAndPersistence() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let snapshot = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        
 // 断言 deviceId 不为空且符合 UUID 格式
        XCTAssertFalse(snapshot.deviceId.isEmpty, "deviceId 不应为空")
        XCTAssertNotNil(UUID(uuidString: snapshot.deviceId), "deviceId 应为有效的 UUID")
        
 // 重新加载，验证持久化
        let provider2 = SelfIdentityProvider.shared
        try await provider2.loadOrCreate()
        let snapshot2 = try await provider2.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        
        XCTAssertEqual(snapshot.deviceId, snapshot2.deviceId, "deviceId 应保持一致")
    }

    /// 测试：SelfIdentityProvider 与协议身份管理器使用同一份稳定 deviceId
    func testDeviceIdMatchesProtocolIdentitySource() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()

        let snapshot = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let protocolIdentityDeviceID = try await DeviceIdentityKeyManager.shared.getDeviceId()
        let protocolIdentity = try await DeviceIdentityKeyManager.shared
            .getOrCreateIdentityKey()

        XCTAssertEqual(
            snapshot.deviceId,
            protocolIdentityDeviceID,
            "SelfIdentityProvider 应与 DeviceIdentityKeyManager 使用同一份稳定 deviceId"
        )
        XCTAssertEqual(protocolIdentityDeviceID, protocolIdentity.deviceId)
        XCTAssertEqual(
            snapshot.pubKeyFP,
            protocolIdentity.pubKeyFP,
            "SelfIdentityProvider 的 deviceId 与 pubKeyFP 必须来自同一份 identity authority"
        )
    }
    
 /// 测试：公钥指纹生成
    func testPubKeyFingerprintGeneration() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let snapshot = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        
 // 权威身份必须始终发布非空、规范化的 SHA256 公钥指纹。
        let identity = try await DeviceIdentityKeyManager.shared
            .getOrCreateIdentityKey()
        XCTAssertEqual(snapshot.pubKeyFP, identity.pubKeyFP)
        XCTAssertEqual(snapshot.pubKeyFP.count, 64, "SHA256 指纹应为 64 字符")
        XCTAssertTrue(snapshot.pubKeyFP.allSatisfy { $0.isHexDigit }, "指纹应为 hex 字符")
        XCTAssertEqual(snapshot.pubKeyFP, snapshot.pubKeyFP.lowercased(), "指纹应为小写")
    }
    
 /// 测试：MAC 地址获取
    func testMACAddressCollection() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let snapshot = await provider.presentationSnapshot()
        
 // MAC 地址集合可能为空（取决于环境），但不应为 nil
        XCTAssertNotNil(snapshot.macSet)
        
 // 如果有 MAC 地址，验证格式
        for mac in snapshot.macSet {
            XCTAssertTrue(
                try mac.matches(regex: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$"),
                "MAC 地址格式应为 xx:xx:xx:xx:xx:xx (小写)"
            )
        }
    }

    func testStrictIdentitySnapshotPublishesOneAuthorityTuple() async throws {
        let identity = makeIdentityInfo(
            deviceID: "22222222-2222-4222-8222-222222222222"
        )
        let expectedMACs: Set<String> = ["02:aa:bb:cc:dd:ee"]
        let provider = SelfIdentityProvider(
            identityLoader: { _ in identity },
            deviceIDMirror: { _ in false },
            macAddressLoader: { expectedMACs }
        )

        try await provider.loadOrCreate()
        let snapshot = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )

        XCTAssertEqual(snapshot.deviceId, identity.deviceId)
        XCTAssertEqual(snapshot.pubKeyFP, identity.pubKeyFP)
        XCTAssertEqual(snapshot.macSet, expectedMACs)
    }

    func testExistingIdentityAbsenceThrowsInsteadOfReturningBlankIdentity() async {
        let provider = SelfIdentityProvider(identityLoader: { allowCreate in
            XCTAssertFalse(allowCreate)
            return nil
        })

        do {
            _ = try await provider.protocolIdentityDeviceId(allowCreate: false)
            XCTFail("Missing authority must not become a blank device ID")
        } catch DeviceIdentityKeyError.keyNotFound {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await provider.presentationSnapshot()
        XCTAssertTrue(snapshot.deviceId.isEmpty)
        XCTAssertTrue(snapshot.pubKeyFP.isEmpty)
    }

    func testSnapshotEnsuringIdentityPropagatesAuthorityFailure() async {
        let provider = SelfIdentityProvider(identityLoader: { _ in
            throw FixtureError.authorityUnavailable
        })

        do {
            _ = try await provider.snapshotEnsuringProtocolDeviceId(
                allowCreate: true
            )
            XCTFail("Authority storage failures must propagate")
        } catch FixtureError.authorityUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegistrationFingerprintUsesOnlyCanonicalAuthorityTuple() async throws {
        let identity = makeIdentityInfo(
            deviceID: "44444444-4444-4444-8444-444444444444"
        )
        let first = SelfIdentityProvider(
            identityLoader: { _ in identity },
            macAddressLoader: { ["02:11:22:33:44:55"] }
        )
        let second = SelfIdentityProvider(
            identityLoader: { _ in identity },
            macAddressLoader: { ["02:aa:bb:cc:dd:ee"] }
        )

        try await first.loadOrCreate()
        try await second.loadOrCreate()
        let firstFingerprint = try await first.generateRegistrationFingerprint(
            allowCreate: false
        )
        let secondFingerprint = try await second.generateRegistrationFingerprint(
            allowCreate: false
        )

        XCTAssertEqual(firstFingerprint, secondFingerprint)
        XCTAssertEqual(firstFingerprint.count, 64)
        XCTAssertTrue(firstFingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testRegistrationFingerprintEncodingIsVersionedAndTupleUnambiguous() {
        let first = SelfIdentityProvider.registrationFingerprint(
            deviceId: "a",
            publicKeyFingerprint: "bc"
        )
        let second = SelfIdentityProvider.registrationFingerprint(
            deviceId: "ab",
            publicKeyFingerprint: "c"
        )

        XCTAssertNotEqual(first, second)
    }

    func testRegistrationFingerprintPropagatesAuthorityFailure() async {
        let provider = SelfIdentityProvider(identityLoader: { _ in
            throw FixtureError.authorityUnavailable
        })

        do {
            _ = try await provider.generateRegistrationFingerprint(allowCreate: true)
            XCTFail("Registration policy must not hash an absent authority tuple")
        } catch FixtureError.authorityUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMismatchedAuthorityFingerprintFailsBeforePublishingEitherField() async {
        let validIdentity = makeIdentityInfo(
            deviceID: "33333333-3333-4333-8333-333333333333"
        )
        let invalidIdentity = DeviceIdentityKeyInfo(
            deviceId: validIdentity.deviceId,
            pubKeyFP: String(repeating: "0", count: 64),
            publicKey: validIdentity.publicKey,
            keyType: validIdentity.keyType,
            createdAt: validIdentity.createdAt,
            isSecureEnclave: validIdentity.isSecureEnclave
        )
        let provider = SelfIdentityProvider(identityLoader: { _ in invalidIdentity })

        do {
            try await provider.loadOrCreate()
            XCTFail("A mismatched authority tuple must fail closed")
        } catch DeviceIdentityKeyError.corruptIdentityAuthority {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await provider.presentationSnapshot()
        XCTAssertTrue(snapshot.deviceId.isEmpty)
        XCTAssertTrue(snapshot.pubKeyFP.isEmpty)
    }
    
 // MARK: - 本机判定测试
    
 /// 测试：强身份硬匹配 - deviceId 匹配
    func testIsLocalDetection_DeviceIdMatch() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let selfId = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let resolver = IdentityResolver()
        
 // 构造与本机 deviceId 相同的设备
        let localDevice = DiscoveredDevice(
            id: UUID(),
            name: "测试设备",
            ipv4: "192.168.1.100",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: selfId.deviceId, // 匹配本机 deviceId
            pubKeyFP: nil,
            macSet: []
        )
        
        let isLocal = await resolver.resolveIsLocal(localDevice, selfId: selfId)
        XCTAssertTrue(isLocal, "deviceId 匹配应判定为本机")
    }

    private func makeIdentityInfo(deviceID: String) -> DeviceIdentityKeyInfo {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        return DeviceIdentityKeyInfo(
            deviceId: deviceID,
            pubKeyFP: DeviceIdentityAuthorityRecord.fingerprint(for: publicKey),
            publicKey: publicKey,
            keyType: .p256Signing,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isSecureEnclave: false
        )
    }
    
    /// 测试：强身份硬匹配 - pubKeyFP 匹配
    func testIsLocalDetection_PubKeyFPMatch() async throws {
        let selfId = Self.deterministicIdentity
        let resolver = IdentityResolver()
        
 // 构造与本机 pubKeyFP 相同的设备
        let localDevice = DiscoveredDevice(
            id: UUID(),
            name: "测试设备",
            ipv4: "192.168.1.101",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: nil,
            pubKeyFP: selfId.pubKeyFP, // 匹配本机公钥指纹
            macSet: []
        )
        
        let isLocal = await resolver.resolveIsLocal(localDevice, selfId: selfId)
        XCTAssertTrue(isLocal, "pubKeyFP 匹配应判定为本机")
    }
    
    /// 测试：强身份硬匹配 - MAC 地址匹配
    func testIsLocalDetection_MACMatch() async throws {
        let selfId = Self.deterministicIdentity
        let resolver = IdentityResolver()
        
 // 构造与本机 MAC 地址有交集的设备
        let localDevice = DiscoveredDevice(
            id: UUID(),
            name: "测试设备",
            ipv4: "192.168.1.102",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: nil,
            pubKeyFP: nil,
            macSet: ["02:11:22:33:44:55"] // 匹配固定合法 MAC
        )
        
        let isLocal = await resolver.resolveIsLocal(localDevice, selfId: selfId)
        XCTAssertTrue(isLocal, "MAC 地址匹配应判定为本机")
    }

    func testIsLocalDetection_MalformedOrNonUnicastMACIsNotStrongIdentity() async {
        let resolver = IdentityResolver()
        for invalidMAC in [
            "02-11-22-33-44-55",
            "02:11:22:33:44",
            "FF:FF:FF:FF:FF:FF",
            "ff:ff:ff:ff:ff:ff",
            "00:00:00:00:00:00",
            "01:00:5e:00:00:01"
        ] {
            let selfId = SelfIdentitySnapshot(
                deviceId: "",
                pubKeyFP: "",
                macSet: [invalidMAC]
            )
            let device = DiscoveredDevice(
                id: UUID(),
                name: "remote",
                ipv4: "127.0.0.1",
                ipv6: nil,
                services: ["_skybridge._tcp"],
                portMap: [:],
                connectionTypes: [.wifi],
                uniqueIdentifier: nil,
                signalStrength: nil,
                isLocalDevice: false,
                deviceId: nil,
                pubKeyFP: nil,
                macSet: [invalidMAC]
            )

            let isLocal = await resolver.resolveIsLocal(device, selfId: selfId)
            XCTAssertFalse(isLocal, "Invalid or multicast MAC must not be a strong identity: \(invalidMAC)")
        }
    }
    
 /// 测试：弱特征不匹配 - 同名设备不应判定为本机
    func testIsLocalDetection_SameNameNotLocal() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let selfId = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let resolver = IdentityResolver()
        
 // 构造同名但强身份不匹配的设备
        let remoteDevice = DiscoveredDevice(
            id: UUID(),
            name: Self.localNameCollisionProbe, // 同名（固定字符串，避免 Host.current() 触发阻塞）
            ipv4: "192.168.1.200",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: UUID().uuidString, // 不同的 deviceId
            pubKeyFP: "0000000000000000000000000000000000000000000000000000000000000000", // 假指纹
            macSet: ["ff:ff:ff:ff:ff:ff"] // 假 MAC
        )
        
        let isLocal = await resolver.resolveIsLocal(remoteDevice, selfId: selfId)
        XCTAssertFalse(isLocal, "同名但强身份不匹配不应判定为本机")
    }
    
 /// 测试：缺少强身份字段不应判定为本机
    func testIsLocalDetection_NoStrongIdentity() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let selfId = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let resolver = IdentityResolver()
        
 // 构造缺少所有强身份字段的设备
        let unknownDevice = DiscoveredDevice(
            id: UUID(),
            name: "未知设备",
            ipv4: "192.168.1.250",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: nil, // 无 deviceId
            pubKeyFP: nil, // 无 pubKeyFP
            macSet: [] // 无 MAC
        )
        
        let isLocal = await resolver.resolveIsLocal(unknownDevice, selfId: selfId)
        XCTAssertFalse(isLocal, "缺少强身份字段不应判定为本机")
    }
    
 // MARK: - 加强补丁：IP/网段碰撞测试
    
 /// 测试：IP 相同但强身份不匹配不应判定为本机
 /// 补丁目的：禁止使用 IP 作为本机判定依据
    func testIsLocalDetection_SameIPButNoStrongIdentity() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let selfId = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let resolver = IdentityResolver()
        
 // 构造一台设备：IP 与本机相同，但强身份不匹配
        let sameIPDevice = DiscoveredDevice(
            id: UUID(),
            name: "HP LaserJet Pro",
            ipv4: "127.0.0.1", // 与本机 localhost 相同
            ipv6: nil,
            services: ["_airplay._tcp"], // 非 SkyBridge 服务
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: UUID().uuidString, // 不同的 deviceId
            pubKeyFP: "0000000000000000000000000000000000000000000000000000000000000000", // 假指纹
            macSet: []
        )
        
        let isLocal = await resolver.resolveIsLocal(sameIPDevice, selfId: selfId)
        XCTAssertFalse(isLocal, "IP 相同但强身份不匹配不应判定为本机")
    }
    
 /// 测试：同网段但强身份不匹配不应判定为本机
 /// 补丁目的：禁止使用 subnet 作为本机判定依据
    func testIsLocalDetection_SameSubnetButNoStrongIdentity() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let selfId = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let resolver = IdentityResolver()
        
 // 构造一台设备：与本机同网段（192.168.1.x），但强身份不匹配
        let sameSubnetDevice = DiscoveredDevice(
            id: UUID(),
            name: "Dell Printer",
            ipv4: "192.168.1.100", // 假设本机也在 192.168.1.x 网段
            ipv6: nil,
            services: ["_ipp._tcp"], // 打印机服务
            portMap: [:],
            connectionTypes: [.ethernet],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: nil, // 无 deviceId
            pubKeyFP: nil, // 无 pubKeyFP
            macSet: [] // 无 MAC
        )
        
        let isLocal = await resolver.resolveIsLocal(sameSubnetDevice, selfId: selfId)
        XCTAssertFalse(isLocal, "同网段但强身份不匹配不应判定为本机")
    }
    
 /// 测试：IP + 同名但强身份不匹配不应判定为本机
 /// 补丁目的：综合测试多个弱特征碰撞时的防护
    func testIsLocalDetection_IPAndNameCollisionButNoStrongIdentity() async throws {
        let provider = SelfIdentityProvider.shared
        try await provider.loadOrCreate()
        
        let selfId = try await provider.snapshotEnsuringProtocolDeviceId(
            allowCreate: false
        )
        let resolver = IdentityResolver()
        
        let deviceName = Self.localNameCollisionProbe
        
 // 构造一台设备：IP 相同 + 名称相同，但强身份不匹配
        let collisionDevice = DiscoveredDevice(
            id: UUID(),
            name: deviceName, // 与本机同名
            ipv4: "127.0.0.1", // 与本机同 IP
            ipv6: nil,
            services: ["_companion-link._tcp"], // Apple Continuity 服务
            portMap: [:],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false,
            deviceId: nil, // 缺失强身份
            pubKeyFP: nil, // 缺失强身份
            macSet: [] // 缺失强身份
        )
        
        let isLocal = await resolver.resolveIsLocal(collisionDevice, selfId: selfId)
        XCTAssertFalse(isLocal, "IP + 名称碰撞但强身份不匹配不应判定为本机")
    }
}

// MARK: - 辅助扩展

extension String {
    func matches(regex pattern: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}
