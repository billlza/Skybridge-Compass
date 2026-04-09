# SkyBridge Compass: Cross-Platform Device Discovery and PQC Encryption Design

**Version:** 1.0
**Date:** 2026-01-11
**Status:** Draft Design Document

---

## Executive Summary

This document outlines the architectural design for extending SkyBridge Compass to support cross-platform device discovery and post-quantum cryptography (PQC) encryption across macOS, iOS, Android, Windows, and Linux platforms. The design maintains backward compatibility with classic cryptography for older devices while enabling quantum-resistant security on modern platforms.

---

## 1. Introduction

### 1.1 Motivation

SkyBridge Compass currently operates primarily on Apple platforms (macOS 26+ and iOS 26+) with native CryptoKit PQC support. Extending to other platforms requires:

1. **Unified Device Discovery**: A protocol that works across diverse network stacks
2. **PQC Interoperability**: Using standardized algorithms (ML-KEM, ML-DSA) with platform-appropriate libraries
3. **Graceful Degradation**: Classic fallback for devices without PQC capability

### 1.2 Goals

- Zero-configuration device discovery on local networks
- End-to-end PQC encryption where supported
- Seamless classic fallback for legacy devices
- Auditable security decisions across all platforms

---

## 2. Device Discovery Architecture

### 2.1 Discovery Protocol Stack

```
┌─────────────────────────────────────────────────────────┐
│                  Application Layer                       │
│              SkyBridge Discovery Service                 │
├─────────────────────────────────────────────────────────┤
│                  Abstraction Layer                       │
│           Platform-Agnostic Discovery API                │
├──────────┬──────────┬──────────┬──────────┬─────────────┤
│  macOS   │   iOS    │ Android  │ Windows  │   Linux     │
│ Bonjour  │ Bonjour  │   NSD    │  DNS-SD  │   Avahi     │
│ Network  │ Network  │          │          │             │
│ .framework│.framework│          │          │             │
├──────────┴──────────┴──────────┴──────────┴─────────────┤
│                    mDNS / DNS-SD                         │
│              _skybridge._tcp.local.                      │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Service Type Definition

**Service Type:** `_skybridge._tcp.local.`

**TXT Record Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `v` | uint8 | Protocol version (currently 1) |
| `pk` | base64 | Identity public key (Ed25519 or ML-DSA-65) |
| `caps` | bitmask | Capability flags (PQC, SE, etc.) |
| `suites` | uint16[] | Supported cipher suites |
| `name` | string | Human-readable device name |
| `platform` | string | Platform identifier |

**Capability Flags:**

```
Bit 0: PQC_MLKEM768      - ML-KEM-768 support
Bit 1: PQC_MLDSA65       - ML-DSA-65 support
Bit 2: SECURE_ENCLAVE    - Hardware-backed keys
Bit 3: CLASSIC_X25519    - X25519 ECDH support
Bit 4: CLASSIC_ED25519   - Ed25519 signature support
Bit 5: HYBRID_XWING      - X-Wing hybrid KEM support
Bit 6-15: Reserved
```

### 2.3 Platform-Specific Discovery Implementations

#### 2.3.1 macOS (Bonjour + Network.framework)

**Implementation:** Native Bonjour via `NWBrowser` and `NWListener`

```swift
// Current implementation in SkyBridge
let browser = NWBrowser(for: .bonjour(type: "_skybridge._tcp", domain: "local."),
                        using: .tcp)
browser.stateUpdateHandler = { state in
    // Handle discovery state
}
browser.browseResultsChangedHandler = { results, changes in
    // Process discovered peers
}
browser.start(queue: .main)
```

**PQC Provider:** CryptoKit (macOS 26+)
- ML-KEM-768, ML-KEM-1024
- ML-DSA-65, ML-DSA-87
- Native Secure Enclave integration

#### 2.3.2 iOS (Bonjour + Network.framework)

**Implementation:** Same as macOS via `NWBrowser`

**PQC Provider:** CryptoKit (iOS 26+)
- Identical API to macOS
- Secure Enclave available on all modern iOS devices

**Fallback (iOS 17-18):** liboqs static library or classic-only mode

#### 2.3.3 Android (NSD - Network Service Discovery)

**Implementation:** `NsdManager` API

```kotlin
class SkyBridgeDiscovery(private val context: Context) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(service: NsdServiceInfo) {
            // Resolve and extract TXT records
            nsdManager.resolveService(service, resolveListener)
        }

        override fun onServiceLost(service: NsdServiceInfo) {
            // Handle peer departure
        }
        // ... other callbacks
    }

    fun startDiscovery() {
        nsdManager.discoverServices("_skybridge._tcp", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }
}
```

**PQC Provider:** BouncyCastle 1.79+ (Java/Kotlin)

```kotlin
// ML-KEM-768 Key Generation
Security.addProvider(BouncyCastlePQCProvider())

val keyGen = KeyPairGenerator.getInstance("ML-KEM", "BCPQC")
keyGen.initialize(MLKEMParameterSpec.ml_kem_768)
val keyPair = keyGen.generateKeyPair()

// ML-DSA-65 Signing
val signer = Signature.getInstance("ML-DSA", "BCPQC")
signer.initSign(privateKey)
signer.update(data)
val signature = signer.sign()
```

**Android Version Support:**
- Android 16+ (API 36): Full NSD + BouncyCastle PQC
- Android 10-15: NSD + classic (X25519/Ed25519) via BouncyCastle
- Android 7-9: Limited NSD, classic only

#### 2.3.4 Windows (DNS-SD via Bonjour SDK or Native)

**Implementation Options:**

1. **Apple Bonjour SDK for Windows** (Recommended)
   - Full DNS-SD compatibility
   - Requires Bonjour Print Services or iTunes installation

2. **Native Windows DNS-SD** (Windows 10+)
   - `DnsServiceBrowse` / `DnsServiceRegister` APIs
   - Limited compared to Bonjour

```cpp
// Windows DNS-SD using Bonjour SDK
DNSServiceRef serviceRef;
DNSServiceBrowse(&serviceRef,
                 0,
                 0,
                 "_skybridge._tcp",
                 "local.",
                 BrowseCallback,
                 nullptr);
```

**PQC Provider Options:**

1. **liboqs** (Recommended)
   - C library, easy to integrate via FFI
   - Full ML-KEM/ML-DSA support

2. **OpenSSL 3.5+** (When available)
   - Native PQC provider
   - ML-KEM-768, ML-DSA-65

```cpp
// liboqs ML-KEM-768
OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_768);
OQS_KEM_keypair(kem, public_key, secret_key);
OQS_KEM_encaps(kem, ciphertext, shared_secret, public_key);
OQS_KEM_decaps(kem, shared_secret, ciphertext, secret_key);
OQS_KEM_free(kem);
```

#### 2.3.5 Linux/Ubuntu (Avahi)

**Implementation:** Avahi via D-Bus or direct API

```python
# Python example using avahi-python
import avahi
import dbus

bus = dbus.SystemBus()
server = dbus.Interface(
    bus.get_object(avahi.DBUS_NAME, avahi.DBUS_PATH_SERVER),
    avahi.DBUS_INTERFACE_SERVER
)

browser = dbus.Interface(
    bus.get_object(avahi.DBUS_NAME,
        server.ServiceBrowserNew(
            avahi.IF_UNSPEC,
            avahi.PROTO_UNSPEC,
            "_skybridge._tcp",
            "local",
            dbus.UInt32(0))),
    avahi.DBUS_INTERFACE_SERVICE_BROWSER
)
```

**PQC Provider Options:**

1. **liboqs** (Native)
   - Available via apt: `liboqs-dev`
   - Or build from source for latest algorithms

2. **OpenSSL 3.5+**
   - PQC provider available
   - `apt install openssl` (when 3.5+ is available)

3. **oqs-provider for OpenSSL**
   - Adds PQC to existing OpenSSL 3.x installations
   - `apt install oqs-provider`

---

## 3. PQC Support Matrix

### 3.1 Platform Capabilities

| Platform | OS Version | PQC Library | ML-KEM-768 | ML-DSA-65 | Hardware Keys |
|----------|------------|-------------|------------|-----------|---------------|
| macOS | 26+ | CryptoKit | ✓ | ✓ | Secure Enclave |
| macOS | 14-15 | liboqs | ✓ | ✓ | SE (P-256 only) |
| iOS | 26+ | CryptoKit | ✓ | ✓ | Secure Enclave |
| iOS | 17-18 | liboqs* | ✓ | ✓ | SE (P-256 only) |
| Android | 16+ | BouncyCastle | ✓ | ✓ | Keystore |
| Android | 10-15 | BouncyCastle | ✓ | ✓ | Keystore |
| Windows | 10+ | liboqs | ✓ | ✓ | TPM 2.0** |
| Linux | Any | liboqs | ✓ | ✓ | TPM 2.0** |

*iOS liboqs requires static linking; not currently bundled
**TPM PQC support varies by hardware

### 3.2 Library Version Requirements

| Library | Minimum Version | ML-KEM | ML-DSA | Notes |
|---------|-----------------|--------|--------|-------|
| CryptoKit | macOS/iOS 26 | 768, 1024 | 65, 87 | Native Apple |
| BouncyCastle | 1.79 | 512-1024 | 44-87 | Java/Kotlin |
| liboqs | 0.12.0 | 768 | 65 | FIPS 203/204 |
| OpenSSL | 3.5.0 | 768 | 65 | Via provider |
| oqs-provider | 0.8.0 | 768 | 65 | For OpenSSL 3.x |

### 3.3 Cipher Suite Definitions

| Suite ID | KEM | Signature | AEAD | KDF | Security Level |
|----------|-----|-----------|------|-----|----------------|
| 0x0001 | X-Wing | ML-DSA-65 | AES-256-GCM | HKDF-SHA256 | Hybrid PQC |
| 0x0101 | ML-KEM-768 | ML-DSA-65 | AES-256-GCM | HKDF-SHA256 | Pure PQC |
| 0x1001 | X25519 | Ed25519 | AES-256-GCM | HKDF-SHA256 | Classic |
| 0x1002 | P-256 | ECDSA-P256 | AES-256-GCM | HKDF-SHA256 | Legacy |

---

## 4. Classic Fallback Strategy

### 4.1 Fallback Decision Tree

```
┌─────────────────────────────────────────┐
│     Initiator Capabilities Assessment    │
└────────────────────┬────────────────────┘
                     │
        ┌────────────▼────────────┐
        │  Native PQC Available?   │
        └────────────┬────────────┘
                     │
         ┌───────────┴───────────┐
         │ YES                   │ NO
         ▼                       ▼
┌────────────────┐      ┌────────────────┐
│  Offer PQC +   │      │  Offer Classic │
│  Classic suites│      │  suites only   │
└───────┬────────┘      └───────┬────────┘
        │                       │
        └───────────┬───────────┘
                    ▼
        ┌────────────────────────┐
        │   Responder Selection   │
        └────────────┬───────────┘
                     │
         ┌───────────┴───────────┐
         │                       │
    PQC Match              Classic Match
         │                       │
         ▼                       ▼
┌────────────────┐      ┌────────────────┐
│  Establish PQC │      │ Policy Check:  │
│    Session     │      │ Allow Fallback?│
└────────────────┘      └───────┬────────┘
                                │
                    ┌───────────┴───────────┐
                    │ YES                   │ NO
                    ▼                       ▼
           ┌────────────────┐      ┌────────────────┐
           │Establish Classic│      │ Reject with    │
           │+ Emit Audit Event│     │ downgradeNotAllowed│
           └────────────────┘      └────────────────┘
```

### 4.2 Fallback Policy Configuration

```swift
enum FallbackPolicy: Sendable {
    /// Require PQC - no fallback allowed
    case strictPQC

    /// Prefer PQC, allow classic fallback with audit
    case preferPQC

    /// Allow any supported suite
    case permissive

    /// Classic only (for legacy interop testing)
    case classicOnly
}
```

### 4.3 Fallback Security Events

Every fallback triggers an auditable security event:

```swift
SecurityEvent.cryptoDowngrade(
    from: .pqcSuite(0x0101),
    to: .classicSuite(0x1001),
    reason: .peerCapability,
    deviceId: peerDeviceId,
    timestamp: Date()
)
```

### 4.4 Legacy Device Compatibility

| Device Category | Supported Suites | Notes |
|-----------------|------------------|-------|
| Modern (PQC-capable) | 0x0001, 0x0101, 0x1001 | Full PQC + fallback |
| Recent (Classic) | 0x1001 | X25519 + Ed25519 |
| Legacy (P-256) | 0x1002 | Requires authenticated channel |
| Very Old | None | Connection refused |

---

## 5. Wire Protocol Interoperability

### 5.1 Message Format (Platform-Agnostic)

All platforms MUST use identical wire format as defined in the IEEE paper:

```
MessageA (Initiator → Responder):
┌─────────┬────────────────────┬──────────────┬─────────────┐
│ version │ supportedSuites[]  │ keyShares[]  │ clientNonce │
│  (1B)   │     (2B len + N)   │ (2B len + N) │    (32B)    │
├─────────┼────────────────────┼──────────────┼─────────────┤
│  caps   │      policy        │ identityPub  │    sigA     │
│  (2B)   │       (1B)         │   (var)      │   (var)     │
└─────────┴────────────────────┴──────────────┴─────────────┘

MessageB (Responder → Initiator):
┌─────────┬────────────────────┬──────────────┬─────────────┐
│ version │   selectedSuite    │   keyShare   │ serverNonce │
│  (1B)   │       (2B)         │    (var)     │    (32B)    │
├─────────┼────────────────────┼──────────────┼─────────────┤
│  caps   │    identityPub     │ payloadHash  │    sigB     │
│  (2B)   │       (var)        │    (32B)     │   (var)     │
└─────────┴────────────────────┴──────────────┴─────────────┘
```

### 5.2 Encoding Rules

1. **Byte Order:** Little-endian for all integers (V1 wire format)
2. **Length Prefixes:** 2-byte LE for arrays
3. **Signatures:** Raw bytes (no ASN.1 wrapping)
4. **Public Keys:** Raw representation (not PEM/DER)

### 5.3 Cross-Platform Test Vectors

Test vectors MUST be validated on all platforms:

```json
{
  "suite": "0x0101",
  "clientNonce": "base64...",
  "serverNonce": "base64...",
  "mlkemPublicKey": "base64...",
  "mlkemCiphertext": "base64...",
  "sharedSecret": "base64...",
  "mldsaPublicKey": "base64...",
  "mldsaSignature": "base64...",
  "message": "base64..."
}
```

---

## 6. Implementation Roadmap

### Phase 1: Android Support (Recommended First)

1. Create Android library module with NSD discovery
2. Integrate BouncyCastle 1.79 for PQC
3. Implement wire protocol encoder/decoder
4. Validate interop with macOS/iOS

**Estimated Effort:** Medium
**Risk:** Low (mature libraries)

### Phase 2: Windows Support

1. Choose DNS-SD implementation (Bonjour SDK recommended)
2. Integrate liboqs for PQC
3. Create C++ or Rust bridge for wire protocol
4. Test with all existing platforms

**Estimated Effort:** Medium-High
**Risk:** Medium (DNS-SD fragmentation)

### Phase 3: Linux Support

1. Implement Avahi discovery service
2. Use liboqs (apt package or bundled)
3. Create shared library for wire protocol
4. Cross-platform integration testing

**Estimated Effort:** Medium
**Risk:** Low (mature ecosystem)

### Phase 4: Legacy Device Support

1. Define minimum classic cipher suite
2. Implement authenticated channel requirement
3. Add policy-based acceptance gates
4. Comprehensive fallback testing

**Estimated Effort:** Low-Medium
**Risk:** Low

---

## 7. Security Considerations

### 7.1 Discovery Channel Security

- mDNS/DNS-SD operates on local network (no TLS)
- Identity public keys in TXT records enable TOFU
- Initial pairing MUST use out-of-band verification
- Subsequent sessions verify pinned identity

### 7.2 PQC Algorithm Selection Rationale

- **ML-KEM-768:** NIST Level 3 security, reasonable key sizes
- **ML-DSA-65:** NIST Level 3, balanced performance/size
- **X-Wing:** Hybrid security during transition period

### 7.3 Classic Fallback Risks

| Risk | Mitigation |
|------|------------|
| Silent downgrade attack | Explicit policy check + audit event |
| Timeout-forced fallback | Timeout never triggers fallback |
| Rapid cycling attack | Per-peer cooldown (5 minutes) |
| Signature algorithm confusion | Homogeneous suites per attempt |

---

## 8. Testing Strategy

### 8.1 Unit Tests

- Wire format encoding/decoding (all platforms)
- PQC primitive round-trips
- Discovery service registration/browse

### 8.2 Integration Tests

- Cross-platform handshake completion
- Fallback scenario validation
- Network condition simulation

### 8.3 Interoperability Matrix

| Initiator | Responder | Expected Outcome |
|-----------|-----------|------------------|
| macOS 26 PQC | Android 16 PQC | PQC established |
| macOS 26 PQC | Windows Classic | Classic fallback |
| Android 16 PQC | iOS 26 PQC | PQC established |
| Linux PQC | Windows Classic | Classic fallback |
| Windows Classic | macOS strictPQC | Connection refused |

---

## 9. Appendix A: Library Installation

### A.1 BouncyCastle (Android/JVM)

```gradle
// build.gradle.kts
dependencies {
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.79")
}
```

### A.2 liboqs (Linux)

```bash
# Ubuntu 24.04+
sudo apt install liboqs-dev

# Or build from source
git clone https://github.com/open-quantum-safe/liboqs.git
cd liboqs && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local ..
make -j && sudo make install
```

### A.3 liboqs (Windows)

```powershell
# Using vcpkg
vcpkg install liboqs:x64-windows

# Or build from source with CMake
git clone https://github.com/open-quantum-safe/liboqs.git
cd liboqs && mkdir build && cd build
cmake -G "Visual Studio 17 2022" -A x64 ..
cmake --build . --config Release
```

### A.4 oqs-provider (OpenSSL 3.x)

```bash
# After installing liboqs
git clone https://github.com/open-quantum-safe/oqs-provider.git
cd oqs-provider && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local ..
make && sudo make install

# Enable in openssl.cnf
# [openssl_init]
# providers = provider_sect
# [provider_sect]
# oqsprovider = oqsprovider_sect
# [oqsprovider_sect]
# activate = 1
```

---

## 10. Appendix B: Code Templates

### B.1 Android Discovery Service

```kotlin
package com.skybridge.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

class SkyBridgeDiscoveryService(private val context: Context) {

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val _discoveredPeers = Channel<DiscoveredPeer>(Channel.BUFFERED)
    val discoveredPeers: Flow<DiscoveredPeer> = _discoveredPeers.receiveAsFlow()

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            // Discovery started
        }

        override fun onServiceFound(service: NsdServiceInfo) {
            nsdManager.resolveService(service, createResolveListener())
        }

        override fun onServiceLost(service: NsdServiceInfo) {
            // Handle peer departure
        }

        override fun onDiscoveryStopped(serviceType: String) {}
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
    }

    private fun createResolveListener() = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            val peer = parseTxtRecords(serviceInfo)
            _discoveredPeers.trySend(peer)
        }
    }

    fun startDiscovery() {
        nsdManager.discoverServices(
            "_skybridge._tcp",
            NsdManager.PROTOCOL_DNS_SD,
            discoveryListener
        )
    }

    fun stopDiscovery() {
        nsdManager.stopServiceDiscovery(discoveryListener)
    }

    private fun parseTxtRecords(info: NsdServiceInfo): DiscoveredPeer {
        // Parse TXT records and return DiscoveredPeer
        val attributes = info.attributes
        return DiscoveredPeer(
            name = info.serviceName,
            host = info.host,
            port = info.port,
            publicKey = attributes["pk"]?.let { String(it) },
            capabilities = attributes["caps"]?.let { parseCapabilities(it) } ?: 0,
            suites = attributes["suites"]?.let { parseSuites(it) } ?: emptyList()
        )
    }
}

data class DiscoveredPeer(
    val name: String,
    val host: java.net.InetAddress,
    val port: Int,
    val publicKey: String?,
    val capabilities: Int,
    val suites: List<Int>
)
```

### B.2 Android PQC Provider

```kotlin
package com.skybridge.crypto

import org.bouncycastle.jcajce.SecretKeyWithEncapsulation
import org.bouncycastle.jcajce.spec.KEMExtractSpec
import org.bouncycastle.jcajce.spec.KEMGenerateSpec
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import org.bouncycastle.pqc.jcajce.spec.MLKEMParameterSpec
import org.bouncycastle.pqc.jcajce.spec.MLDSAParameterSpec
import java.security.*
import javax.crypto.KeyGenerator

class PQCCryptoProvider {

    init {
        Security.addProvider(BouncyCastlePQCProvider())
    }

    // ML-KEM-768 Key Generation
    fun generateMLKEMKeyPair(): KeyPair {
        val keyGen = KeyPairGenerator.getInstance("ML-KEM", "BCPQC")
        keyGen.initialize(MLKEMParameterSpec.ml_kem_768, SecureRandom())
        return keyGen.generateKeyPair()
    }

    // ML-KEM Encapsulation
    fun encapsulate(publicKey: PublicKey): Pair<ByteArray, ByteArray> {
        val keyGen = KeyGenerator.getInstance("ML-KEM", "BCPQC")
        keyGen.init(KEMGenerateSpec(publicKey, "AES"), SecureRandom())
        val secretKey = keyGen.generateKey() as SecretKeyWithEncapsulation
        return Pair(secretKey.encapsulation, secretKey.encoded)
    }

    // ML-KEM Decapsulation
    fun decapsulate(privateKey: PrivateKey, ciphertext: ByteArray): ByteArray {
        val keyGen = KeyGenerator.getInstance("ML-KEM", "BCPQC")
        keyGen.init(KEMExtractSpec(privateKey, ciphertext, "AES"))
        return keyGen.generateKey().encoded
    }

    // ML-DSA-65 Key Generation
    fun generateMLDSAKeyPair(): KeyPair {
        val keyGen = KeyPairGenerator.getInstance("ML-DSA", "BCPQC")
        keyGen.initialize(MLDSAParameterSpec.ml_dsa_65, SecureRandom())
        return keyGen.generateKeyPair()
    }

    // ML-DSA Signing
    fun sign(privateKey: PrivateKey, data: ByteArray): ByteArray {
        val signer = Signature.getInstance("ML-DSA", "BCPQC")
        signer.initSign(privateKey)
        signer.update(data)
        return signer.sign()
    }

    // ML-DSA Verification
    fun verify(publicKey: PublicKey, data: ByteArray, signature: ByteArray): Boolean {
        val verifier = Signature.getInstance("ML-DSA", "BCPQC")
        verifier.initVerify(publicKey)
        verifier.update(data)
        return verifier.verify(signature)
    }
}
```

### B.3 Windows Discovery (C++ with Bonjour SDK)

```cpp
// SkyBridgeDiscovery.h
#pragma once

#include <dns_sd.h>
#include <string>
#include <vector>
#include <functional>

struct DiscoveredPeer {
    std::string name;
    std::string host;
    uint16_t port;
    std::vector<uint8_t> publicKey;
    uint16_t capabilities;
    std::vector<uint16_t> suites;
};

class SkyBridgeDiscovery {
public:
    using PeerCallback = std::function<void(const DiscoveredPeer&)>;

    SkyBridgeDiscovery();
    ~SkyBridgeDiscovery();

    void startDiscovery(PeerCallback callback);
    void stopDiscovery();

private:
    DNSServiceRef m_browseRef = nullptr;
    PeerCallback m_callback;

    static void DNSSD_API browseCallback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char* serviceName,
        const char* regtype,
        const char* replyDomain,
        void* context
    );

    static void DNSSD_API resolveCallback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        uint32_t interfaceIndex,
        DNSServiceErrorType errorCode,
        const char* fullname,
        const char* hosttarget,
        uint16_t port,
        uint16_t txtLen,
        const unsigned char* txtRecord,
        void* context
    );
};

// SkyBridgeDiscovery.cpp
#include "SkyBridgeDiscovery.h"

SkyBridgeDiscovery::SkyBridgeDiscovery() = default;

SkyBridgeDiscovery::~SkyBridgeDiscovery() {
    stopDiscovery();
}

void SkyBridgeDiscovery::startDiscovery(PeerCallback callback) {
    m_callback = std::move(callback);

    DNSServiceErrorType err = DNSServiceBrowse(
        &m_browseRef,
        0,                          // flags
        kDNSServiceInterfaceIndexAny,
        "_skybridge._tcp",
        "local.",
        browseCallback,
        this
    );

    if (err != kDNSServiceErr_NoError) {
        throw std::runtime_error("Failed to start discovery");
    }
}

void SkyBridgeDiscovery::stopDiscovery() {
    if (m_browseRef) {
        DNSServiceRefDeallocate(m_browseRef);
        m_browseRef = nullptr;
    }
}

void DNSSD_API SkyBridgeDiscovery::browseCallback(
    DNSServiceRef sdRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    DNSServiceErrorType errorCode,
    const char* serviceName,
    const char* regtype,
    const char* replyDomain,
    void* context
) {
    if (errorCode != kDNSServiceErr_NoError) return;
    if (!(flags & kDNSServiceFlagsAdd)) return;

    auto* self = static_cast<SkyBridgeDiscovery*>(context);

    DNSServiceRef resolveRef;
    DNSServiceResolve(
        &resolveRef,
        0,
        interfaceIndex,
        serviceName,
        regtype,
        replyDomain,
        resolveCallback,
        self
    );
}
```

---

## 11. References

1. NIST FIPS 203: Module-Lattice-Based Key-Encapsulation Mechanism Standard
2. NIST FIPS 204: Module-Lattice-Based Digital Signature Standard
3. RFC 6762: Multicast DNS
4. RFC 6763: DNS-Based Service Discovery
5. BouncyCastle Documentation: https://www.bouncycastle.org/documentation.html
6. liboqs Documentation: https://openquantumsafe.org/liboqs/
7. Apple CryptoKit: https://developer.apple.com/documentation/cryptokit
8. Android NSD: https://developer.android.com/develop/connectivity/wifi/use-nsd

---

*Document generated for SkyBridge Compass cross-platform expansion project.*
