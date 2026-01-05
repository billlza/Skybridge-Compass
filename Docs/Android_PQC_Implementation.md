# Android 后量子加密 (PQC) 实现指南

> 版本: 1.0.0 | 更新日期: 2025-12-16  
> 与 macOS SkyBridge Compass PQC 架构对齐

## 目录

1. [架构概览](#1-架构概览)
2. [算法套件对照](#2-算法套件对照)
3. [Provider 层级设计](#3-provider-层级设计)
4. [核心接口定义](#4-核心接口定义)
5. [实现方案](#5-实现方案)
6. [互操作性保证](#6-互操作性保证)

---

## 1. 架构概览

### 1.1 macOS 端架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│  HybridCryptoService (混合加密服务)                          │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────────┐
│              CryptoProvider Protocol                         │
│  - hpkeSeal/hpkeOpen (HPKE 封装/解封装)                      │
│  - sign/verify (数字签名)                                    │
│  - generateKeyPair (密钥生成)                                │
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
┌───────▼──────┐ ┌──▼──────┐ ┌──▼──────────┐
│ ApplePQC     │ │ OQS     │ │ Classic     │
│ Provider     │ │ Provider│ │ Provider    │
│ (iOS 26+)    │ │ (liboqs)│ │ (P-256)     │
└──────────────┘ └─────────┘ └─────────────┘
```

### 1.2 Android 端对齐架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│  HybridCryptoService (混合加密服务)                          │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────────┐
│              CryptoProvider Interface                        │
│  - hpkeSeal/hpkeOpen (HPKE 封装/解封装)                      │
│  - sign/verify (数字签名)                                    │
│  - generateKeyPair (密钥生成)                                │
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
┌───────▼──────┐ ┌──▼──────┐ ┌──▼──────────┐
│ Tink PQC     │ │ BouncyCastle│ Classic    │
│ Provider     │ │ PQC Provider│ Provider   │
│ (Google)     │ │ (BC-PQC)    │ (EC)       │
└──────────────┘ └─────────────┘ └───────────┘
```

---

## 2. 算法套件对照

### 2.1 Wire Protocol 编码

| Suite Name | Wire ID | KEM | Signature | macOS | Android |
|------------|---------|-----|-----------|-------|---------|
| X-Wing + ML-DSA-65 | 0x0001 | X-Wing | ML-DSA-65 | ✅ iOS 26+ | ⚠️ Tink |
| ML-KEM-768 + ML-DSA-65 | 0x0101 | ML-KEM-768 | ML-DSA-65 | ✅ iOS 26+ | ✅ Tink/BC |
| X25519 + Ed25519 | 0x1001 | X25519 | Ed25519 | ✅ | ✅ |
| P-256 + ECDSA | 0x1002 | P-256 | ECDSA | ✅ | ✅ |

### 2.2 密钥长度规范

#### ML-KEM-768 (FIPS 203)

| 组件 | 长度 (bytes) | 说明 |
|------|--------------|------|
| 公钥 | 1184 | FIPS 203 标准 |
| 私钥 (FIPS) | 2400 | 扩展格式 |
| 私钥 (Apple) | 96 | seed-based 紧凑格式 |
| 密文 | 1088 | 封装密钥 |
| 共享密钥 | 32 | KEM 输出 |

#### ML-DSA-65 (FIPS 204)

| 组件 | 长度 (bytes) | 说明 |
|------|--------------|------|
| 公钥 | 1952 | FIPS 204 标准 |
| 私钥 (FIPS) | 4032 | 扩展格式 |
| 私钥 (Apple) | 64 | seed-based 紧凑格式 |
| 签名 | ~3309 | 可变长度 |

**重要**: Android 端应使用 FIPS 标准格式，与 macOS 端的 `rawRepresentation` 兼容。

---

## 3. Provider 层级设计

### 3.1 Provider 层级定义

```kotlin
enum class CryptoTier {
    /** Google Tink PQC */
    TINK_PQC,
    
    /** BouncyCastle PQC */
    BOUNCY_CASTLE_PQC,
    
    /** 经典算法 (EC, RSA) */
    CLASSIC
}
```

### 3.2 Provider 选择策略

```kotlin
object CryptoProviderFactory {
    fun createProvider(suite: CryptoSuite): CryptoProvider {
        return when {
            // 优先使用 Tink (如果可用)
            suite.isPQC && TinkPQCProvider.isAvailable() -> 
                TinkPQCProvider()
            
            // 降级到 BouncyCastle
            suite.isPQC && BouncyCastlePQCProvider.isAvailable() -> 
                BouncyCastlePQCProvider()
            
            // 经典算法
            else -> ClassicProvider()
        }
    }
}
```

---

## 4. 核心接口定义

### 4.1 CryptoProvider 接口

```kotlin
interface CryptoProvider {
    /** Provider 标识 */
    val providerName: String
    
    /** Provider 层级 */
    val tier: CryptoTier
    
    /** 当前算法套件 */
    val activeSuite: CryptoSuite
    
    /** HPKE 封装 (KEM) */
    suspend fun hpkeSeal(
        plaintext: ByteArray,
        recipientPublicKey: ByteArray,
        info: ByteArray
    ): HPKESealedBox
    
    /** HPKE 解封装 */
    suspend fun hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: ByteArray,
        info: ByteArray
    ): ByteArray
    
    /** 数字签名 */
    suspend fun sign(
        data: ByteArray,
        privateKey: ByteArray
    ): ByteArray
    
    /** 签名验证 */
    suspend fun verify(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean
    
    /** 生成密钥对 */
    suspend fun generateKeyPair(usage: KeyUsage): KeyPair
}
```

### 4.2 数据结构

```kotlin
/** 算法套件 */
data class CryptoSuite(
    val rawValue: String,
    val wireId: UShort
) {
    companion object {
        val X_WING_ML_DSA = CryptoSuite("X-Wing", 0x0001u)
        val ML_KEM_768_ML_DSA_65 = CryptoSuite("ML-KEM-768", 0x0101u)
        val X25519_ED25519 = CryptoSuite("X25519", 0x1001u)
        val P256_ECDSA = CryptoSuite("P-256", 0x1002u)
    }
    
    val isPQC: Boolean
        get() = (wireId.toInt() shr 8) in listOf(0x00, 0x01)
}

/** HPKE 密封盒 */
data class HPKESealedBox(
    val encapsulatedKey: ByteArray,  // KEM 封装的临时公钥
    val nonce: ByteArray,            // AES-GCM nonce (12 bytes)
    val ciphertext: ByteArray,       // 加密数据
    val tag: ByteArray               // AES-GCM 认证标签 (16 bytes)
)

/** 密钥对 */
data class KeyPair(
    val publicKey: KeyMaterial,
    val privateKey: KeyMaterial
)

/** 密钥材料 */
data class KeyMaterial(
    val suite: CryptoSuite,
    val usage: KeyUsage,
    val bytes: ByteArray
)

enum class KeyUsage {
    KEY_EXCHANGE,  // KEM
    SIGNING        // 签名
}
```

---


## 5. 实现方案（基于 Google 工程实践）

### 5.1 算法迁移路线图

根据 Google Chrome 的实践和 NIST 标准化进展：

```
Timeline:
2022-2023: X25519 + Kyber-768 (实验阶段)
2024.05:   X25519 + ML-KEM-768 (Chrome 默认启用)
2024.08:   NIST 发布 ML-KEM/ML-DSA 最终标准
2025+:     全面迁移到 ML-KEM/ML-DSA
```

**云桥司南策略**：
- **优先支持**: X25519 + ML-KEM-768 (与 NIST 标准对齐)
- **兼容支持**: X25519 + Kyber-768 (向后兼容旧版本)
- **兜底方案**: X25519 / P-256 (经典算法)

### 5.2 Android Provider 实现选型

#### 5.2.1 推荐方案：liboqs + BoringSSL

```kotlin
/**
 * Android PQC Provider - 使用 liboqs
 * 
 * 优势：
 * - 跨平台一致性（与 macOS OQSPQCProvider 对齐）
 * - NIST 标准算法完整支持
 * - 成熟稳定，Google/Cloudflare 生产验证
 */
class AndroidPQCCryptoProvider : CryptoProvider {
    override val providerName = "liboqs-android"
    override val tier = CryptoTier.LIBOQS_PQC
    override val activeSuite = CryptoSuite.ML_KEM_768_ML_DSA_65
    
    // 使用 JNI 调用 liboqs C 库
    private external fun nativeMLKEM768Encaps(
        publicKey: ByteArray
    ): EncapsResult
    
    private external fun nativeMLKEM768Decaps(
        ciphertext: ByteArray,
        privateKey: ByteArray
    ): ByteArray
    
    private external fun nativeMLDSA65Sign(
        message: ByteArray,
        privateKey: ByteArray
    ): ByteArray
    
    private external fun nativeMLDSA65Verify(
        message: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean
    
    companion object {
        init {
            System.loadLibrary("skybridge_pqc")
        }
    }
}
```

#### 5.2.2 备选方案：Cronet (Chromium 网络栈)

```kotlin
/**
 * 使用 Cronet 的 QUIC + PQC 能力
 * 
 * 优势：
 * - Google 官方维护，与 Chrome 同步
 * - QUIC + ML-KEM 开箱即用
 * - 生产环境验证（Chrome 116+ 默认启用）
 * 
 * 劣势：
 * - 可控性较低
 * - 需要额外依赖
 */
dependencies {
    implementation("org.chromium.net:cronet-api:119.6045.31")
    implementation("org.chromium.net:cronet-common:119.6045.31")
}

class CronetPQCTransport(context: Context) {
    private val engine = CronetEngine.Builder(context)
        .enableQuic(true)
        .enableHttp2(true)
        // Cronet 自动处理 ML-KEM 协商
        .build()
}
```

### 5.3 握手协议 V2（与 macOS 对齐）

#### 5.3.1 消息格式

```kotlin
/**
 * SkyBridge Handshake V2
 * 
 * 设计原则：
 * - 自描述 header（支持协议演进）
 * - 双写/双读迁移（V1/V2 共存）
 * - 域分离（classic/PQC 密钥材料独立）
 */
data class HandshakeV2ClientHello(
    val protocolVersion: UShort = 0x0002u,  // V2
    val supportedSuites: List<CryptoSuite>,  // 按优先级排序
    val deviceCaps: DeviceCapabilities,
    val clientRandom: ByteArray,             // 32 bytes
    val clientKeyShare: KeyShare,            // 经典 ECDH 公钥
    val extensions: Map<String, ByteArray>   // 扩展字段
) {
    companion object {
        const val MAGIC = 0x53425632  // "SBV2"
    }
    
    fun serialize(): ByteArray {
        return ByteBuffer.allocate(4096).apply {
            putInt(MAGIC)
            putShort(protocolVersion.toShort())
            putShort(supportedSuites.size.toShort())
            supportedSuites.forEach { suite ->
                putShort(suite.wireId.toShort())
            }
            // ... 其他字段
        }.array()
    }
}

data class HandshakeV2ServerHello(
    val protocolVersion: UShort = 0x0002u,
    val selectedSuite: CryptoSuite,
    val serverRandom: ByteArray,
    val serverKeyShare: KeyShare,            // 经典 ECDH 公钥
    val pqcEncapsulated: ByteArray,          // ML-KEM 封装密钥
    val transcriptHash: ByteArray,           // SHA-256
    val extensions: Map<String, ByteArray>
)

data class KeyShare(
    val group: UShort,      // 0x001D = X25519, 0x0017 = P-256
    val keyExchange: ByteArray
)
```

#### 5.3.2 密钥派生（HKDF 域分离）

```kotlin
/**
 * 混合密钥派生
 * 
 * 遵循 Google Chrome 的做法：
 * 1. 经典 ECDH 生成 classic_secret
 * 2. ML-KEM 生成 pqc_secret
 * 3. HKDF 组合：master_secret = HKDF(classic_secret || pqc_secret)
 */
object HybridKeyDerivation {
    
    fun deriveSessionKeys(
        classicSecret: ByteArray,
        pqcSecret: ByteArray,
        clientRandom: ByteArray,
        serverRandom: ByteArray,
        transcriptHash: ByteArray
    ): SessionKeys {
        // 1. 域分离标签
        val domainSeparator = "SkyBridge-P2P-v2".toByteArray()
        
        // 2. 组合输入密钥材料
        val ikm = ByteBuffer.allocate(
            classicSecret.size + pqcSecret.size
        ).apply {
            put(classicSecret)
            put(pqcSecret)
        }.array()
        
        // 3. 计算 salt
        val salt = MessageDigest.getInstance("SHA-256").apply {
            update(clientRandom)
            update(serverRandom)
        }.digest()
        
        // 4. HKDF-Expand
        val masterSecret = hkdfExpand(
            prk = hkdfExtract(salt, ikm),
            info = domainSeparator + transcriptHash,
            length = 48  // 384 bits
        )
        
        // 5. 派生各通道密钥
        return SessionKeys(
            controlKey = deriveChannelKey(masterSecret, "control", 32),
            videoKey = deriveChannelKey(masterSecret, "video", 32),
            fileKey = deriveChannelKey(masterSecret, "file", 32)
        )
    }
    
    private fun deriveChannelKey(
        masterSecret: ByteArray,
        channel: String,
        length: Int
    ): ByteArray {
        val info = "skybridge-$channel-v1".toByteArray()
        return hkdfExpand(masterSecret, info, length)
    }
    
    private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        return mac.doFinal(ikm)
    }
    
    private fun hkdfExpand(
        prk: ByteArray,
        info: ByteArray,
        length: Int
    ): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        
        val result = ByteArrayOutputStream()
        var t = ByteArray(0)
        var i = 1
        
        while (result.size() < length) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(i.toByte())
            t = mac.doFinal()
            result.write(t)
            i++
        }
        
        return result.toByteArray().copyOf(length)
    }
}

data class SessionKeys(
    val controlKey: ByteArray,   // 控制通道
    val videoKey: ByteArray,     // 视频通道
    val fileKey: ByteArray       // 文件传输通道
)
```

### 5.4 HPKESealedBox 自描述格式

```kotlin
/**
 * HPKE 密封盒（与 macOS 格式完全一致）
 * 
 * Header 格式：
 * magic(4B: "HPKE") || version(1B) || suiteWireId(2B) || flags(2B) ||
 * encLen(2B) || nonceLen(1B) || tagLen(1B) || ctLen(4B) ||
 * enc || nonce || ct || tag
 */
data class HPKESealedBox(
    val encapsulatedKey: ByteArray,  // ML-KEM-768: 1088 bytes
    val nonce: ByteArray,            // AES-GCM: 12 bytes
    val ciphertext: ByteArray,
    val tag: ByteArray               // AES-GCM: 16 bytes
) {
    companion object {
        private val MAGIC = byteArrayOf(0x48, 0x50, 0x4B, 0x45)  // "HPKE"
        private const val HEADER_SIZE = 17
        private const val MAX_ENC_LEN = 4096
        private const val EXPECTED_NONCE_LEN = 12
        private const val EXPECTED_TAG_LEN = 16
        private const val MAX_CT_LEN_HANDSHAKE = 64 * 1024      // 64KB
        private const val MAX_CT_LEN_POST_AUTH = 256 * 1024     // 256KB
        
        /**
         * 从合并格式解析（带 DoS 防护）
         */
        fun fromCombined(
            combined: ByteArray,
            isHandshake: Boolean = true
        ): HPKESealedBox {
            // 1. 检查最小长度
            require(combined.size >= HEADER_SIZE) {
                "Data too short for header"
            }
            
            // 2. 验证 magic
            require(combined.sliceArray(0..3).contentEquals(MAGIC)) {
                "Invalid magic bytes"
            }
            
            // 3. 解析 header
            val version = combined[4].toInt() and 0xFF
            require(version == 1) {
                "Unsupported version: $version"
            }
            
            val suiteWireId = (combined[5].toInt() and 0xFF shl 8) or
                             (combined[6].toInt() and 0xFF)
            val flags = (combined[7].toInt() and 0xFF shl 8) or
                       (combined[8].toInt() and 0xFF)
            
            val encLen = (combined[9].toInt() and 0xFF shl 8) or
                        (combined[10].toInt() and 0xFF)
            val nonceLen = combined[11].toInt() and 0xFF
            val tagLen = combined[12].toInt() and 0xFF
            val ctLen = (combined[13].toInt() and 0xFF shl 24) or
                       (combined[14].toInt() and 0xFF shl 16) or
                       (combined[15].toInt() and 0xFF shl 8) or
                       (combined[16].toInt() and 0xFF)
            
            // 4. 验证长度上限（防 DoS）
            require(encLen <= MAX_ENC_LEN) {
                "encLen exceeds limit: $encLen > $MAX_ENC_LEN"
            }
            require(nonceLen == EXPECTED_NONCE_LEN) {
                "Invalid nonce length: $nonceLen"
            }
            require(tagLen == EXPECTED_TAG_LEN) {
                "Invalid tag length: $tagLen"
            }
            
            val maxCtLen = if (isHandshake) MAX_CT_LEN_HANDSHAKE else MAX_CT_LEN_POST_AUTH
            require(ctLen <= maxCtLen) {
                "ctLen exceeds limit: $ctLen > $maxCtLen"
            }
            
            // 5. 验证总长度
            val expectedTotal = HEADER_SIZE + encLen + nonceLen + ctLen + tagLen
            require(combined.size == expectedTotal) {
                "Length mismatch: expected $expectedTotal, got ${combined.size}"
            }
            
            // 6. 切片
            var offset = HEADER_SIZE
            val enc = combined.sliceArray(offset until offset + encLen)
            offset += encLen
            val nonce = combined.sliceArray(offset until offset + nonceLen)
            offset += nonceLen
            val ct = combined.sliceArray(offset until offset + ctLen)
            offset += ctLen
            val tag = combined.sliceArray(offset until offset + tagLen)
            
            return HPKESealedBox(enc, nonce, ct, tag)
        }
    }
    
    /**
     * 生成带 header 的合并格式
     */
    fun combinedWithHeader(suite: CryptoSuite): ByteArray {
        return ByteBuffer.allocate(
            HEADER_SIZE + encapsulatedKey.size + nonce.size + 
            ciphertext.size + tag.size
        ).apply {
            put(MAGIC)
            put(1)  // version
            putShort(suite.wireId.toShort())
            putShort(0)  // flags
            putShort(encapsulatedKey.size.toShort())
            put(EXPECTED_NONCE_LEN.toByte())
            put(EXPECTED_TAG_LEN.toByte())
            putInt(ciphertext.size)
            put(encapsulatedKey)
            put(nonce)
            put(ciphertext)
            put(tag)
        }.array()
    }
}
```

### 5.5 密钥存储策略

```kotlin
/**
 * Android 密钥存储
 * 
 * 策略：
 * - 经典密钥（P-256/Ed25519）→ Android Keystore (TEE/StrongBox)
 * - PQC 密钥（ML-KEM/ML-DSA）→ 加密存储（体积大，Keystore 不稳定）
 */
class SkyBridgeKeyManager(private val context: Context) {
    
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply {
        load(null)
    }
    
    /**
     * 生成设备身份密钥（经典算法，存入 Keystore）
     */
    fun generateDeviceIdentityKey(): KeyPair {
        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore"
        )
        
        val parameterSpec = KeyGenParameterSpec.Builder(
            "skybridge_device_identity",
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        ).apply {
            setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            setDigests(KeyProperties.DIGEST_SHA256)
            setUserAuthenticationRequired(false)
            // 尝试使用 StrongBox（如果可用）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                setIsStrongBoxBacked(true)
            }
        }.build()
        
        keyPairGenerator.initialize(parameterSpec)
        return keyPairGenerator.generateKeyPair()
    }
    
    /**
     * 存储 PQC 密钥（加密后存储）
     */
    fun storePQCKeyPair(keyPair: KeyPair, alias: String) {
        // 1. 生成 wrapping key（存入 Keystore）
        val wrappingKey = generateWrappingKey(alias)
        
        // 2. 加密 PQC 私钥
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
        val iv = cipher.iv
        val encryptedPrivateKey = cipher.doFinal(keyPair.privateKey.bytes)
        
        // 3. 存储到 SharedPreferences（加密后）
        context.getSharedPreferences("skybridge_pqc_keys", Context.MODE_PRIVATE)
            .edit()
            .putString("${alias}_public", Base64.encodeToString(
                keyPair.publicKey.bytes, Base64.NO_WRAP
            ))
            .putString("${alias}_private_enc", Base64.encodeToString(
                encryptedPrivateKey, Base64.NO_WRAP
            ))
            .putString("${alias}_iv", Base64.encodeToString(
                iv, Base64.NO_WRAP
            ))
            .apply()
    }
    
    private fun generateWrappingKey(alias: String): SecretKey {
        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        
        val parameterSpec = KeyGenParameterSpec.Builder(
            "skybridge_wrap_$alias",
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        ).apply {
            setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            setKeySize(256)
        }.build()
        
        keyGenerator.init(parameterSpec)
        return keyGenerator.generateKey()
    }
}
```

---

## 6. 互操作性保证

### 6.1 跨平台测试矩阵

| 发起端 | 响应端 | Suite | 状态 |
|--------|--------|-------|------|
| macOS (CryptoKit) | Android (liboqs) | ML-KEM-768 + ML-DSA-65 | ✅ 必测 |
| macOS (OQS) | Android (liboqs) | ML-KEM-768 + ML-DSA-65 | ✅ 必测 |
| iOS 26+ | Android | X-Wing + ML-DSA-65 | ⚠️ 可选 |
| Android | Android | ML-KEM-768 + ML-DSA-65 | ✅ 必测 |
| macOS | Android | X25519 + Ed25519 | ✅ 兜底 |

### 6.2 协议版本协商

```kotlin
/**
 * 协议版本协商（双写/双读迁移）
 */
object ProtocolNegotiator {
    
    fun negotiateVersion(
        localSupported: List<UShort>,
        remoteSupported: List<UShort>
    ): UShort? {
        // 优先选择最高版本
        val common = localSupported.intersect(remoteSupported.toSet())
        return common.maxOrNull()
    }
    
    fun shouldDualWrite(): Boolean {
        // 迁移期间双写 V1/V2
        return BuildConfig.PROTOCOL_MIGRATION_PHASE
    }
    
    fun canReadV1(): Boolean {
        // 始终保持向后兼容
        return true
    }
}
```

### 6.3 降级策略

```kotlin
/**
 * 加密套件降级策略
 * 
 * 遵循 Google Chrome 的做法：
 * 1. 尝试 PQC 混合套件
 * 2. 降级到经典套件
 * 3. 记录降级事件（用于监控）
 */
class CryptoSuiteNegotiator(
    private val telemetry: TelemetryService
) {
    
    fun negotiate(
        localSuites: List<CryptoSuite>,
        remoteSuites: List<CryptoSuite>
    ): CryptoSuite {
        // 1. 找到共同支持的套件
        val common = localSuites.intersect(remoteSuites.toSet())
        
        if (common.isEmpty()) {
            telemetry.recordEvent("crypto_negotiation_failed")
            throw CryptoNegotiationException("No common suite")
        }
        
        // 2. 按优先级选择
        val selected = common.first()
        
        // 3. 检查是否降级
        val isPQC = selected.isPQC
        val hadPQCOption = localSuites.any { it.isPQC } && 
                          remoteSuites.any { it.isPQC }
        
        if (!isPQC && hadPQCOption) {
            telemetry.recordEvent("crypto_degraded_to_classic", mapOf(
                "selected_suite" to selected.rawValue,
                "local_suites" to localSuites.map { it.rawValue }.joinToString(),
                "remote_suites" to remoteSuites.map { it.rawValue }.joinToString()
            ))
        }
        
        return selected
    }
}
```

---

## 7. 工程落地 Checklist

### 7.1 立即可做

- [ ] 更新协议文档：Kyber → ML-KEM, Dilithium → ML-DSA
- [ ] 实现 `AndroidPQCCryptoProvider` 骨架（接口与 macOS 对齐）
- [ ] 实现 `HandshakeV2` 消息格式
- [ ] 实现 `HPKESealedBox` 自描述格式（含 DoS 防护）
- [ ] 配置 liboqs JNI 绑定

### 7.2 短期目标（1-2 周）

- [ ] 实现混合密钥派生（HKDF 域分离）
- [ ] 实现密钥存储（Keystore + 加密存储）
- [ ] 编写单元测试（密钥生成、封装/解封装、签名/验签）
- [ ] 编写互操作测试（Android ↔ macOS）

### 7.3 中期目标（1 个月）

- [ ] 集成 QUIC 传输层（Cronet 或自研）
- [ ] 实现双写/双读迁移逻辑
- [ ] 实现降级策略和遥测
- [ ] 性能优化（JNI 调用、内存管理）

### 7.4 长期目标（3 个月）

- [ ] 完整的跨平台测试矩阵
- [ ] 生产环境灰度发布
- [ ] 监控和告警（降级率、失败率）
- [ ] 为未来量子密钥源预留接口

---

## 8. 参考资料

### 8.1 Google 工程实践

- [Chrome 116+ PQC in TLS/QUIC](https://blog.chromium.org/2023/08/protecting-chrome-traffic-with-hybrid.html)
- [Google Developers: ML-KEM Deployment](https://developers-jp.googleblog.com/2024/09/chrome-ml-kem.html)
- [Chrome Platform Status: Post-Quantum KEM](https://chromestatus.com/feature/6678134168485888)

### 8.2 NIST 标准

- [NIST PQC Standardization](https://csrc.nist.gov/projects/post-quantum-cryptography)
- [FIPS 203: ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [FIPS 204: ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)

### 8.3 开源实现

- [liboqs](https://github.com/open-quantum-safe/liboqs)
- [Cronet (Chromium Network Stack)](https://chromium.googlesource.com/chromium/src/+/main/components/cronet/)
- [BouncyCastle PQC](https://www.bouncycastle.org/java.html)

---

**文档维护**: SkyBridge Compass Team  
**最后更新**: 2025-12-16  
**基于**: Google Chrome PQC 工程实践 + NIST 标准化进展
