import XCTest
@testable import SkyBridgeCore
import CryptoKit

/// SelfIdentityProvider 单元测试
/// 验证本机强身份生成、持久化和判定逻辑
@available(macOS 14.0, *)
final class SelfIdentityProviderTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
 // 测试前清理 Keychain（避免脏数据）
        KeychainManager.shared.deduplicate(servicePrefix: "SkyBridge.SelfIdentity")
    }
    
 // MARK: - 基础功能测试
    
 /// 测试：首次启动生成并持久化 deviceId
    func testDeviceIdGenerationAndPersistence() async throws {
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let snapshot = await provider.snapshot()
        
 // 断言 deviceId 不为空且符合 UUID 格式
        XCTAssertFalse(snapshot.deviceId.isEmpty, "deviceId 不应为空")
        XCTAssertNotNil(UUID(uuidString: snapshot.deviceId), "deviceId 应为有效的 UUID")
        
 // 重新加载，验证持久化
        let provider2 = SelfIdentityProvider.shared
        await provider2.loadOrCreate()
        let snapshot2 = await provider2.snapshot()
        
        XCTAssertEqual(snapshot.deviceId, snapshot2.deviceId, "deviceId 应保持一致")
    }
    
 /// 测试：公钥指纹生成
    func testPubKeyFingerprintGeneration() async throws {
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let snapshot = await provider.snapshot()
        
 // 如果密钥存在，公钥指纹不应为空
        if !snapshot.pubKeyFP.isEmpty {
 // 验证是 64 字符的 hex 字符串（SHA256 输出）
            XCTAssertEqual(snapshot.pubKeyFP.count, 64, "SHA256 指纹应为 64 字符")
            XCTAssertTrue(snapshot.pubKeyFP.allSatisfy { $0.isHexDigit }, "指纹应为 hex 字符")
            XCTAssertTrue(snapshot.pubKeyFP.allSatisfy { !$0.isUppercase || !$0.isLetter }, "指纹应为小写")
        }
    }
    
 /// 测试：MAC 地址获取
    func testMACAddressCollection() async throws {
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let snapshot = await provider.snapshot()
        
 // MAC 地址集合可能为空（取决于环境），但不应为 nil
        XCTAssertNotNil(snapshot.macSet)
        
 // 如果有 MAC 地址，验证格式
        for mac in snapshot.macSet {
            XCTAssertTrue(mac.matches(regex: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$"), "MAC 地址格式应为 xx:xx:xx:xx:xx:xx (小写)")
        }
    }
    
 // MARK: - 本机判定测试
    
 /// 测试：强身份硬匹配 - deviceId 匹配
    func testIsLocalDetection_DeviceIdMatch() async throws {
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
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
    
 /// 测试：强身份硬匹配 - pubKeyFP 匹配
    func testIsLocalDetection_PubKeyFPMatch() async throws {
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
        let resolver = IdentityResolver()
        
        guard !selfId.pubKeyFP.isEmpty else {
            throw XCTSkip("本测试需要本机公钥指纹")
        }
        
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
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
        let resolver = IdentityResolver()
        
        guard !selfId.macSet.isEmpty else {
            throw XCTSkip("本测试需要本机 MAC 地址")
        }
        
        let firstMAC = selfId.macSet.first!
        
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
            macSet: [firstMAC] // 匹配本机 MAC
        )
        
        let isLocal = await resolver.resolveIsLocal(localDevice, selfId: selfId)
        XCTAssertTrue(isLocal, "MAC 地址匹配应判定为本机")
    }
    
 /// 测试：弱特征不匹配 - 同名设备不应判定为本机
    func testIsLocalDetection_SameNameNotLocal() async throws {
        let provider = SelfIdentityProvider.shared
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
        let resolver = IdentityResolver()
        
 // 构造同名但强身份不匹配的设备
        let remoteDevice = DiscoveredDevice(
            id: UUID(),
            name: Host.current().localizedName ?? "本机", // 同名
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
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
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
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
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
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
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
        await provider.loadOrCreate()
        
        let selfId = await provider.snapshot()
        let resolver = IdentityResolver()
        
        let deviceName = Host.current().localizedName ?? "MacBook Pro"
        
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
    func matches(regex pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}

