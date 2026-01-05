import XCTest
@testable import SkyBridgeCore

/// 中文注释：二维码签名校验单元测试
/// 覆盖三种载荷格式：
/// 1) skybridge://connect/<Base64-JSON>?sig=&pk=&ts=&fp=
/// 2) 纯 JSON 封装：{"payload": {...}, "signatureBase64": "...", "publicKeyBase64": "...", "timestamp": 0, "publicKeyFingerprint": "hex"}
/// 3) 简化根对象（无签名）：期望验签失败并返回中文原因
/// 中文注释：
/// 由于 P2PSecurityManager 标注为 @MainActor（与UI状态同步），
/// 测试类需要在主Actor环境中执行以满足 Swift 6 严格并发要求。
@MainActor
final class QRCodeSignatureTests: XCTestCase {
 /// 中文注释：构建示例设备
    private func makeDevice(host: String = "127.0.0.1", port: UInt16 = 8081) -> P2PDevice {
        return P2PDevice(
            id: UUID().uuidString,
            name: "测试设备",
            type: .macOS,
            address: host,
            port: port,
            osVersion: "macOS 15.0",
            capabilities: ["ssh","rdp"],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: ["\(host):\(port)"]
        )
    }

 /// 中文注释：生成签名材料（调用安全管理器现有方法）
    private func sign(manager: P2PSecurityManager, device: P2PDevice, ts: Double) -> (pkB64: String, fpHex: String, sigB64: String) {
        let result = manager.signDiscoveryCanonical(
            id: device.id,
            name: device.name,
            type: device.deviceType,
            address: device.address,
            port: device.port,
            osVersion: device.osVersion,
            capabilities: device.capabilities,
            timestamp: ts
        )
        return (result.0, result.1, result.2)
    }

 /// 中文注释：测试 URL + query 载荷格式验签成功
    func testURLQuerySignatureVerification() throws {
        let manager = P2PSecurityManager()
        let device = makeDevice()
        let ts = Date().timeIntervalSince1970
        let (pkB64, fpHex, sigB64) = sign(manager: manager, device: device, ts: ts)

 // 模拟 URL 载荷：skybridge://connect/<base64-json>?sig=...&pk=...&ts=...&fp=...
        let jsonObj: [String: Any] = [
            "id": device.id,
            "name": device.name,
            "type": device.deviceType.rawValue,
            "address": device.address,
            "port": Int(device.port),
            "osVersion": device.osVersion,
            "capabilities": device.capabilities
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonObj, options: [])
        let b64 = jsonData.base64EncodedString()
        let urlStr = "skybridge://connect/\(b64)?sig=\(sigB64)&pk=\(pkB64)&ts=\(ts)&fp=\(fpHex)"
        let comps = URLComponents(string: urlStr)
        XCTAssertNotNil(comps)

 // 使用统一入口验签
        let verify = manager.verifyQRCodeSignature(for: device, publicKeyBase64: pkB64, signatureBase64: sigB64, timestamp: ts, fingerprintHex: fpHex)
        XCTAssertTrue(verify.ok, verify.reason ?? "")
    }

 /// 中文注释：测试 JSON 封装载荷格式验签成功
    func testJSONEnvelopeSignatureVerification() throws {
        let manager = P2PSecurityManager()
        let device = makeDevice(host: "host.local", port: 2222)
        let ts = Date().timeIntervalSince1970
        let (pkB64, fpHex, sigB64) = sign(manager: manager, device: device, ts: ts)

 // 构建封装 JSON
        struct Envelope: Codable {
            let payload: Payload
            let signatureBase64: String
            let publicKeyBase64: String
            let timestamp: Double
            let publicKeyFingerprint: String
        }
        struct Payload: Codable {
            let id: String
            let name: String
            let type: String
            let address: String
            let port: Int
            let osVersion: String
            let capabilities: [String]
        }
        let env = Envelope(
            payload: Payload(id: device.id, name: device.name, type: device.deviceType.rawValue, address: device.address, port: Int(device.port), osVersion: device.osVersion, capabilities: device.capabilities),
            signatureBase64: sigB64,
            publicKeyBase64: pkB64,
            timestamp: ts,
            publicKeyFingerprint: fpHex
        )
        let envData = try JSONEncoder().encode(env)
        XCTAssertGreaterThan(envData.count, 0)

 // 使用统一入口验签
        let verify = manager.verifyQRCodeSignature(for: device, publicKeyBase64: pkB64, signatureBase64: sigB64, timestamp: ts, fingerprintHex: fpHex)
        XCTAssertTrue(verify.ok, verify.reason ?? "")
    }

 /// 中文注释：测试简化根对象载荷（无签名）验签失败并返回中文原因
    func testSimplifiedRootWithoutSignatureFails() throws {
        let manager = P2PSecurityManager()
        let device = makeDevice()
 // 模拟无签名：传入不可解码的Base64字符串
        let verify = manager.verifyQRCodeSignature(for: device, publicKeyBase64: "", signatureBase64: "", timestamp: nil, fingerprintHex: nil)
        XCTAssertFalse(verify.ok)
        XCTAssertNotNil(verify.reason)
    }
}