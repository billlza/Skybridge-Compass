# SkyBridge Compass - 跨平台 PQC 握手设计

> Superseded for current Android P2P/Q-Periapt implementation decisions by
> `docs/ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md`. This file remains as
> historical design context; do not use its Android 13-15, macOS 14+, or iOS 17+
> compatibility assumptions as the current product contract.

## 概述

本文档详细分析 macOS/iOS 与 Android 平台的 PQC (后量子密码学) 握手实现，并提供确保跨平台互操作性的设计方案。

**目标平台：**
- Android 16+ (API 36+)
- macOS 14.0+ / macOS Tahoe 26+
- iOS 17+ / iOS 26+

---

## 1. macOS/iOS 实现分析

### 1.1 PQC Provider 架构

```
┌─────────────────────────────────────────────────────┐
│              PQCProviderFactory                     │
├─────────────────────────────────────────────────────┤
│  ┌───────────────┐     ┌───────────────────────┐   │
│  │ ApplePQC      │     │ OQSProvider           │   │
│  │ (iOS/macOS 26+)│     │ (macOS 14-15, liboqs)  │   │
│  │               │     │                       │   │
│  │ • ML-KEM-768  │     │ • ML-KEM-768          │   │
│  │ • ML-KEM-1024 │     │ • ML-KEM-1024         │   │
│  │ • ML-DSA-65   │     │ • ML-DSA-65           │   │
│  │ • ML-DSA-87   │     │ • ML-DSA-87           │   │
│  │ • X-Wing HPKE │     │ • HPKE降级(KEM+AES-GCM)│   │
│  └───────────────┘     └───────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### 1.2 支持的算法套件

| 套件名称 | Wire ID | KEM 算法 | 签名算法 | 支持平台 |
|---------|---------|----------|----------|----------|
| `classic-p256` | - | P-256 ECDH | P-256 ECDSA | 所有 |
| `pqc-mlkem-mldsa` | - | ML-KEM-768 | ML-DSA-65 | macOS 14+, iOS 17+ |
| `hybrid-xwing` | - | X-Wing (X25519+ML-KEM-768) | P-256+ML-DSA-65 | iOS/macOS 26+ |

### 1.3 混合密钥派生 (HybridCryptoService)

```swift
// macOS/iOS 实现
private func combineSharedSecrets(classic: Data, pqc: Data) -> Data {
    var combined = classic
    combined.append(pqc)
    
    let inputKey = SymmetricKey(data: combined)
    let derivedKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: inputKey,
        salt: Data("SkyBridgeHybridKDF".utf8),  // ⚠️ 固定盐
        info: Data("hybrid-key-exchange".utf8), // ⚠️ 固定 info
        outputByteCount: 32
    )
    return derivedKey.withUnsafeBytes { Data($0) }
}
```

---

## 2. Android 实现分析

### 2.1 PQC Provider 架构

```
┌─────────────────────────────────────────────────────┐
│              CryptoProviderFactory                  │
├─────────────────────────────────────────────────────┤
│  ┌───────────────────────────────────────────────┐ │
│  │ AndroidPQCCryptoProvider (liboqs via JNI)    │ │
│  │                                               │ │
│  │ • ML-KEM-768 (encapsulate/decapsulate)       │ │
│  │ • ML-DSA-65 (sign/verify)                    │ │
│  │ • 跨平台签名验证 (Ed25519, ECDSA P-256)       │ │
│  └───────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 2.2 支持的算法套件

| 套件名称 | Wire ID | KEM 算法 | 签名算法 | Android 支持 |
|---------|---------|----------|----------|--------------|
| `X-Wing+ML-DSA-65` | 0x0001 | X-Wing | ML-DSA-65 | 未实现 |
| `ML-KEM-768+ML-DSA-65` | 0x0101 | ML-KEM-768 | ML-DSA-65 | ✅ liboqs |
| `X25519+Ed25519` | 0x1001 | X25519 | Ed25519 | ✅ API 33+ |
| `P-256+ECDSA` | 0x1002 | P-256 ECDH | ECDSA | ✅ 所有版本 |

### 2.3 当前密钥派生 (HybridKeyDerivation)

```kotlin
// Android 当前实现
fun deriveSessionKeys(
    classicSecret: ByteArray,
    pqcSecret: ByteArray,
    clientRandom: ByteArray,
    serverRandom: ByteArray,
    transcriptHash: ByteArray
): SessionKeys {
    // IKM = classicSecret || pqcSecret
    val ikm = classicSecret + pqcSecret
    
    // salt = SHA-256(clientRandom || serverRandom)  ⚠️ 动态盐
    val salt = sha256(clientRandom + serverRandom)
    
    // Extract PRK
    val prk = hkdfExtract(salt, ikm)
    
    // Expand with domain separator + transcript
    val info = "SkyBridge-P2P-v2".toByteArray() + transcriptHash  // ⚠️ 不同 info
    val masterSecret = hkdfExpand(prk, info, 48)  // ⚠️ 48 字节 vs 32 字节
    
    // Derive channel keys
    return SessionKeys(
        controlKey = deriveChannelKey(masterSecret, "skybridge-control-v1"),
        videoKey = deriveChannelKey(masterSecret, "skybridge-video-v1"),
        fileKey = deriveChannelKey(masterSecret, "skybridge-file-v1")
    )
}
```

---

## 3. 兼容性问题分析

### 3.1 ⚠️ 关键问题：密钥派生不匹配

| 参数 | macOS/iOS | Android | 状态 |
|------|-----------|---------|------|
| IKM | classic \|\| pqc | classic \|\| pqc | ✅ 一致 |
| Salt | 固定 "SkyBridgeHybridKDF" | 动态 SHA-256(randoms) | ❌ 不一致 |
| Info | 固定 "hybrid-key-exchange" | "SkyBridge-P2P-v2" + transcript | ❌ 不一致 |
| 输出长度 | 32 字节 | 48 字节 master → 32 字节 channel | ❌ 不一致 |

**影响：** 即使握手消息正确交换，双方派生的会话密钥将不同，导致后续通信失败。

### 3.2 握手流程兼容性

```
Android (Client)                    macOS/iOS (Server)
      │                                    │
      │─────── ClientHello ───────────────▶│
      │  • supportedSuites                 │
      │  • clientRandom                    │
      │  • clientKeyShare (P-256)          │
      │  • extensions[pqc_kem_pk]          │  ← ML-KEM-768 公钥
      │  • extensions[peer_platform]       │
      │                                    │
      │◀────── ServerHello ────────────────│
      │  • selectedSuite                   │
      │  • serverRandom                    │
      │  • serverKeyShare (P-256)          │
      │  • pqcEncapsulated                 │  ← ML-KEM-768 密文
      │  • transcriptHash                  │
      │  • extensions[pqc_sig]             │  ← ML-DSA-65 签名
      │  • extensions[classic_sig]         │  ← ECDSA/Ed25519 签名
      │                                    │
      ├─────── Key Derivation ─────────────┤
      │  classicSecret = ECDH(...)         │
      │  pqcSecret = Decapsulate(...)      │
      │  sessionKey = HKDF(...)  ⚠️ 参数不同 │
      └────────────────────────────────────┘
```

### 3.3 Wire Format 兼容性

| 项目 | Android | macOS/iOS | 状态 |
|------|---------|-----------|------|
| 字节序 | Little-endian | Little-endian | ✅ |
| Magic | "SBV2" (0x53425632) | 使用 JSON 消息 | ⚠️ 需适配 |
| 协议版本 | 0x0002 | 1.0.0 (JSON) | ⚠️ 需映射 |

---

## 4. 推荐解决方案

### 4.1 方案 A：统一密钥派生参数 (推荐)

修改 Android 实现以匹配 macOS/iOS：

```kotlin
// 新增: 跨平台兼容的混合密钥组合
object CrossPlatformKeyDerivation {
    
    private val CROSS_PLATFORM_SALT = "SkyBridgeHybridKDF".toByteArray(Charsets.UTF_8)
    private val CROSS_PLATFORM_INFO = "hybrid-key-exchange".toByteArray(Charsets.UTF_8)
    
    /**
     * 与 macOS/iOS HybridCryptoService.combineSharedSecrets() 兼容的密钥派生
     */
    fun combineSharedSecrets(
        classicSecret: ByteArray,
        pqcSecret: ByteArray
    ): ByteArray {
        // IKM = classic || pqc
        val ikm = classicSecret + pqcSecret
        
        // HKDF with fixed salt and info (matches Apple implementation)
        val prk = HybridKeyDerivation.hkdfExtract(CROSS_PLATFORM_SALT, ikm)
        return HybridKeyDerivation.hkdfExpand(prk, CROSS_PLATFORM_INFO, 32)
    }
    
    /**
     * 从组合密钥派生通道密钥
     */
    fun deriveSessionKeysFromCombined(
        combinedSecret: ByteArray,
        clientRandom: ByteArray,
        serverRandom: ByteArray,
        transcriptHash: ByteArray
    ): SessionKeys {
        // Use combined secret as input for channel key derivation
        val salt = MessageDigest.getInstance("SHA-256").apply {
            update(clientRandom)
            update(serverRandom)
        }.digest()
        
        val prk = HybridKeyDerivation.hkdfExtract(salt, combinedSecret)
        val info = "SkyBridge-P2P-v2".toByteArray() + transcriptHash
        val masterSecret = HybridKeyDerivation.hkdfExpand(prk, info, 48)
        
        return SessionKeys(
            controlKey = HybridKeyDerivation.hkdfExpand(masterSecret, 
                "skybridge-control-v1".toByteArray(), 32),
            videoKey = HybridKeyDerivation.hkdfExpand(masterSecret, 
                "skybridge-video-v1".toByteArray(), 32),
            fileKey = HybridKeyDerivation.hkdfExpand(masterSecret, 
                "skybridge-file-v1".toByteArray(), 32)
        )
    }
}
```

### 4.2 方案 B：协议版本协商

在 ClientHello 中声明支持的密钥派生版本：

```kotlin
// Extension: kdf_version
// 0x01 = Legacy (Android original)
// 0x02 = CrossPlatform (Apple compatible)

extensions[EXT_KDF_VERSION] = byteArrayOf(0x02) // Prefer cross-platform
```

### 4.3 方案 C：简化握手（针对 P2P 场景）

对于直接 P2P 连接，可以使用简化的握手：

```kotlin
/**
 * 简化的跨平台 PQC 握手
 * 匹配 macOS/iOS 的 P2PHandshakeManager
 */
class SimplePQCHandshake(private val pqcProvider: AndroidPQCCryptoProvider) {
    
    /**
     * 发起方: KEM 封装
     */
    suspend fun initiate(peerPublicKey: ByteArray): Pair<ByteArray, ByteArray> {
        return pqcProvider.encapsulate(peerPublicKey)
        // Returns: (ciphertext, sharedSecret)
    }
    
    /**
     * 响应方: KEM 解封装
     */
    suspend fun complete(ciphertext: ByteArray, privateKey: ByteArray): ByteArray {
        return pqcProvider.decapsulate(ciphertext, privateKey)
        // Returns: sharedSecret
    }
    
    /**
     * 从 KEM 共享密钥派生会话密钥
     */
    fun deriveSessionKey(sharedSecret: ByteArray, deviceId: String): ByteArray {
        // Match Apple's deriveAndStoreSessionKey implementation
        val salt = "SkyBridgeHybridKDF".toByteArray()
        val info = "session-$deviceId".toByteArray()
        
        val prk = HybridKeyDerivation.hkdfExtract(salt, sharedSecret)
        return HybridKeyDerivation.hkdfExpand(prk, info, 32)
    }
}
```

---

## 5. 实施计划

### Phase 1: 核心兼容性修复 (优先级: 高)

1. **添加 CrossPlatformKeyDerivation 模块**
   - 实现与 Apple 兼容的 `combineSharedSecrets()`
   - 保留现有 `HybridKeyDerivation` 用于同平台通信

2. **更新 HandshakeManager**
   - 检测对端平台 (via `EXT_PEER_PLATFORM`)
   - 根据对端选择密钥派生策略
   - 添加 `EXT_KDF_VERSION` 扩展

3. **验证 Wire Format**
   - 确认 little-endian 格式一致
   - 测试 extension 序列化兼容性

### Phase 2: 测试和验证 (优先级: 高)

1. **创建互操作性测试向量**
   - 使用已知输入生成 Android 输出
   - 与 macOS/iOS 输出比对

2. **集成测试**
   - Android → macOS 握手
   - macOS → Android 握手
   - iOS → Android 握手

### Phase 3: 生产就绪 (优先级: 中)

1. **错误处理和降级**
   - PQC 不可用时优雅降级到 ECDH
   - 签名验证失败时尝试 fallback 算法

2. **性能优化**
   - liboqs JNI 调用批处理
   - 密钥缓存策略

---

## 6. Android 13+ 特性利用

### 6.1 可用的密码学 API

| API | 最低 API Level | 用途 |
|-----|---------------|------|
| Ed25519 | API 33 (Android 13) | 经典签名 |
| X25519 | API 33 | 经典 ECDH |
| P-256 ECDH | API 1 | 通用 ECDH |
| HKDF | API 23 (自定义实现) | 密钥派生 |
| ML-KEM-768 | - (liboqs) | PQC KEM |
| ML-DSA-65 | - (liboqs) | PQC 签名 |

### 6.2 liboqs 集成最佳实践

```kotlin
// JNI 加载策略
object LibOQSLoader {
    private var isLoaded = false
    
    fun ensureLoaded() {
        if (!isLoaded) {
            synchronized(this) {
                if (!isLoaded) {
                    try {
                        System.loadLibrary("skybridge_pqc")
                        isLoaded = true
                    } catch (e: UnsatisfiedLinkError) {
                        // 降级到纯经典模式
                        Log.w(TAG, "liboqs not available, falling back to classic crypto")
                    }
                }
            }
        }
    }
    
    val isAvailable: Boolean
        get() = isLoaded
}
```

---

## 7. 安全考量

### 7.1 密钥材料处理

- ✅ PQC 私钥使用 `ByteArray.fill(0)` 清零后再回收
- ✅ 共享密钥不应记录到日志
- ✅ 使用 `SecureRandom` 生成所有随机数

### 7.2 降级攻击防护

- ⚠️ 如果协商了 PQC 套件但 PQC 派生失败，应**拒绝连接**而非降级
- ✅ 当前 `HandshakeManager` 已实现此检查

### 7.3 前向保密

- ✅ 每次握手生成新的临时密钥对
- ✅ 会话密钥通过 HKDF 派生，不直接使用原始共享密钥

---

## 8. 结论

Android 与 macOS/iOS 的 PQC 握手**基本兼容**，主要差异在于：

1. **密钥派生参数** - 需要统一 HKDF salt/info
2. **协议消息格式** - Android 使用二进制 "SBV2"，Apple 可能使用 JSON

**推荐行动：**
1. 立即实施 `CrossPlatformKeyDerivation` 模块
2. 添加平台检测逻辑选择密钥派生策略
3. 创建互操作性测试套件验证兼容性

---

---

## 9. 测试向量

以下测试向量由 Android 实现生成，应与 iOS/macOS 实现产生相同的输出。

### 9.1 输入数据

```
classicSecret   = 0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
pqcSecret       = 2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40
clientRandom    = 4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60
serverRandom    = 6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80
transcriptHash  = 8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0
deviceId        = "test-device-123"
```

### 9.2 预期输出 (Android)

| 测试 | 输出 (hex) |
|------|-----------|
| combineSharedSecrets | `6b58bedb224eb980208debf6a7e8b53d6551d06da78e83149e1f9740b0b40a43` |
| classic-only | `e4d786a762483a971f57ff0d6564b250a8a9f315807307b6d3ab5f0d38ca844d` |
| P2P session key | `6e885214bc7db0d5f795b16fdbe4c18b680059215e4584dc1c361dad84ad2d67` |
| controlKey | `39b058b53864c4b63500a80694aac71a2e05b15eb96afe468fc1d0c68ab22f81` |
| videoKey | `7dab0b285498eddcca04a302fe6a3fd22afe17e21f4646ff1d40f638870f4be1` |
| fileKey | `efdaad3c42118024e09382b83d666ffbbe2d6c07cfcd736f7e63efed898c6a68` |

### 9.3 Swift 验证代码

```swift
import CryptoKit

let classicSecret = Data([0x01...0x20].map { UInt8($0) })
let pqcSecret = Data([0x21...0x40].map { UInt8($0) })

// Test 1: combineSharedSecrets
let combined = classicSecret + pqcSecret
let combinedKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: combined),
    salt: Data("SkyBridgeHybridKDF".utf8),
    info: Data("hybrid-key-exchange".utf8),
    outputByteCount: 32
)
let combinedHex = combinedKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
assert(combinedHex == "6b58bedb224eb980208debf6a7e8b53d6551d06da78e83149e1f9740b0b40a43")

// Test 2: P2P session key
let deviceId = "test-device-123"
let info = Data("session-\(deviceId)".utf8)
let p2pKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: classicSecret),
    salt: Data("SkyBridgeHybridKDF".utf8),
    info: info,
    outputByteCount: 32
)
let p2pHex = p2pKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
assert(p2pHex == "6e885214bc7db0d5f795b16fdbe4c18b680059215e4584dc1c361dad84ad2d67")
```

---

*文档版本: 1.1*
*最后更新: 2026-01-28*
*作者: SkyBridge 跨平台团队*
