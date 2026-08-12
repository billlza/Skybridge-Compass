package com.skybridge.compass.core.webrtc

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.property.Arb
import io.kotest.property.arbitrary.arbitrary
import io.kotest.property.arbitrary.boolean
import io.kotest.property.arbitrary.element
import io.kotest.property.arbitrary.int
import io.kotest.property.checkAll

/**
 * **Feature: cross-platform-parity-audit, Property 24: 信令端点准入判定**
 *
 * **Validates: Requirements 4.10**
 *
 * 任务 9.16 的属性测试，驱动生产准入门
 * [SignalServerClient.isLegacyDiagnosticEndpointAllowed]（`:core` 的
 * `webrtc/SignalServerClient.kt`，R4.10 的实现所在）与
 * [SignalingEndpointTrustPolicy]（`webrtc/CurrentPathSecurity.kt`）。
 * 不在测试内重写任何 CIDR 判定逻辑：主机字面量由生成器按**八位组数值**构造，
 * 期望值由 R4.10 成文的地址段独立推导。
 *
 * ### 被验证的不变式（R4.10）
 * 「公开信令端点仅接受当前路径准入；**当且仅当**构建类型为调试构建**且**目标主机属于
 * 127.0.0.0/8、::1/128、10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16 或
 * fc00::/7 之一时，允许免准入的历史诊断端点；其余目标主机或非调试构建的情况一律拒绝
 * 并呈现失败原因分类为路径认证失败。」
 *
 * 形式化为一条**双向**（iff）判定：
 * `isLegacyDiagnosticEndpointAllowed(url) == (isDebugBuild && hostInPermittedRanges(host))`
 *
 * 三个半部因此都被检验：
 * 1. **调试构建 + 段内 ⇒ 允许**（不漏放）；
 * 2. **调试构建 + 段外 ⇒ 拒绝**（不误放，含 172.32/172.15 这类紧邻边界的主机）；
 * 3. **非调试构建 ⇒ 一律拒绝**（与主机无关，恒假）——同一批主机在
 *    `isDebugBuildProvider = { false }` 下必须全部被拒。
 *
 * 另外锁定 **fail-closed**：无法解析的 URL、无主机的 URL 一律拒绝而非放行。
 *
 * ### 属性定义域
 * 本属性只判定「免准入历史诊断端点」这道门。当前路径准入本身（挑战/签名交换）需要真实
 * 网络与设备身份，不在纯单元测试范围内；[SignalingEndpointTrustPolicy] 的
 * user-auth / diagnostic 上下文判定作为同一条 R4.10 规则的另一侧在第二个测试里覆盖。
 *
 * 非空真保证：每个测试断言各分支计数 > 0 并打印计数值。
 */
class SignalingAdmissionPropertyTest : FunSpec({

    // region R4.10 成文地址段的独立判据（按数值推导，不引用被测实现）

    /** 127.0.0.0/8、10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16。 */
    fun ipv4InPermittedRange(a: Int, b: Int, c: Int, d: Int): Boolean {
        if (listOf(a, b, c, d).any { it !in 0..255 }) return false
        return when {
            a == 127 -> true
            a == 10 -> true
            a == 172 && b in 16..31 -> true
            a == 192 && b == 168 -> true
            a == 169 && b == 254 -> true
            else -> false
        }
    }

    // endregion

    /**
     * IPv4 主机生成器：刻意混合**段内**与**紧邻边界的段外**取值，
     * 使 172.16.0.0/12 的两侧（172.15 / 172.32）、169.254 的两侧（169.253 / 169.255）、
     * 192.168 的两侧（192.167 / 192.169）都被覆盖。
     */
    val ipv4Arb: Arb<Triple<String, Boolean, String>> = arbitrary {
        val a = Arb.element(listOf(0, 9, 10, 11, 126, 127, 128, 169, 172, 191, 192, 193, 8, 203)).bind()
        val b = Arb.element(listOf(0, 1, 15, 16, 17, 31, 32, 100, 167, 168, 169, 253, 254, 255)).bind()
        val c = Arb.int(0..255).bind()
        val d = Arb.int(1..254).bind()
        val host = "$a.$b.$c.$d"
        Triple(host, ipv4InPermittedRange(a, b, c, d), "ipv4")
    }

    /** IPv6 主机生成器：::1、fc00::/7 内（fc/fd 开头）与段外（fe80、2001 等）。 */
    val ipv6Arb: Arb<Triple<String, Boolean, String>> = arbitrary {
        val (literal, permitted) = Arb.element(
            listOf(
                "::1" to true,
                "0:0:0:0:0:0:0:1" to true,
                "fc00::1" to true,
                "fc00::abcd" to true,
                "fcff::1" to true,
                "fd00::1" to true,
                "fd12:3456::1" to true,
                "fdff:ffff::9" to true,
                // 段外：fe80::/10 链路本地、2001::/16 公网、::2 非回环
                "fe80::1" to false,
                "fe80::abcd" to false,
                "2001:db8::1" to false,
                "2606:4700::1111" to false,
                "::2" to false,
                "fb00::1" to false,   // fb = 0xFB，紧邻 fc00::/7 下界之外
                "fe00::1" to false    // fe = 0xFE，紧邻 fc00::/7 上界之外
            )
        ).bind()
        Triple(literal, permitted, "ipv6")
    }

    /** 非 IP 主机名：一律段外（含公网信令主机与 .local 名字）。 */
    val hostnameArb: Arb<Triple<String, Boolean, String>> = arbitrary {
        val host = Arb.element(
            listOf(
                "api.nebula-technologies.net",
                "signal.example.com",
                "localhost",
                "mac.local",
                "127.evil.com",
                "10.0.0.1.evil.com",
                "example.org"
            )
        ).bind()
        // 注意：R4.10 的成文段是**地址段**，主机名（含 "localhost"）不在其列。
        Triple(host, false, "hostname")
    }

    val hostArb: Arb<Triple<String, Boolean, String>> = arbitrary {
        when (Arb.int(0..2).bind()) {
            0 -> ipv4Arb.bind()
            1 -> ipv6Arb.bind()
            else -> hostnameArb.bind()
        }
    }

    /** 把主机字面量包装成 URL（IPv6 需方括号）。 */
    fun urlFor(host: String, kind: String, port: Int): String =
        if (kind == "ipv6") "http://[$host]:$port" else "http://$host:$port"

    test("Property 24: 免准入诊断端点当且仅当调试构建且主机属于 R4.10 成文地址段时被允许") {
        var allowedDebugInRange = 0
        var rejectedDebugOutOfRange = 0
        var rejectedReleaseInRange = 0
        var rejectedReleaseOutOfRange = 0
        val kindCounts = mutableMapOf<String, Int>()

        checkAll(1000, hostArb, Arb.int(1024..65535)) { (host, inRange, kind), port ->
            val url = urlFor(host, kind, port)
            kindCounts[kind] = (kindCounts[kind] ?: 0) + 1

            val debugClient = SignalServerClient(isDebugBuildProvider = { true })
            val releaseClient = SignalServerClient(isDebugBuildProvider = { false })

            val debugDecision = debugClient.isLegacyDiagnosticEndpointAllowed(url)
            val releaseDecision = releaseClient.isLegacyDiagnosticEndpointAllowed(url)

            // **不变式（双向 iff）**：调试构建下的判定恰等于"主机在成文段内"。
            debugDecision shouldBe inRange

            // **不变式（非调试构建恒拒）**：与主机无关，一律拒绝。
            releaseDecision shouldBe false

            // 主机判定与构建类型无关（同一主机在两种构建下的"段内性"一致，
            // 差别只来自构建门），交叉核对生产的 isDiagnosticEndpointHost。
            debugClient.isDiagnosticEndpointHost(host) shouldBe inRange

            when {
                inRange -> {
                    allowedDebugInRange++
                    rejectedReleaseInRange++
                }
                else -> {
                    rejectedDebugOutOfRange++
                    rejectedReleaseOutOfRange++
                }
            }
        }

        println(
            "Property 24 counters: allowedDebugInRange=$allowedDebugInRange, " +
                "rejectedDebugOutOfRange=$rejectedDebugOutOfRange, " +
                "rejectedReleaseInRange=$rejectedReleaseInRange, " +
                "rejectedReleaseOutOfRange=$rejectedReleaseOutOfRange, kinds=$kindCounts"
        )

        // 非空真保证：四个象限都被生成到（调试/非调试 × 段内/段外）。
        (allowedDebugInRange > 0) shouldBe true
        (rejectedDebugOutOfRange > 0) shouldBe true
        (rejectedReleaseInRange > 0) shouldBe true
        (rejectedReleaseOutOfRange > 0) shouldBe true
        // 且三类主机形态都被覆盖，"段内"不是只由 IPv4 一种形态达成。
        ((kindCounts["ipv4"] ?: 0) > 0) shouldBe true
        ((kindCounts["ipv6"] ?: 0) > 0) shouldBe true
        ((kindCounts["hostname"] ?: 0) > 0) shouldBe true
    }

    test("Property 24: 无法解析或无主机的端点一律拒绝（fail-closed）") {
        var rejected = 0

        val malformedArb: Arb<String> = Arb.element(
            listOf(
                "",
                "   ",
                "not a url",
                "http://",
                "://missing-scheme",
                "http://[not-an-ipv6",
                "ht!tp://127.0.0.1",
                "file:///etc/hosts",
                "http://:18443"
            )
        )

        checkAll(200, malformedArb, Arb.boolean()) { raw, isDebug ->
            val client = SignalServerClient(isDebugBuildProvider = { isDebug })
            // 解析失败或无主机 ⇒ 拒绝（绝不因解析失败而放行）。
            client.isLegacyDiagnosticEndpointAllowed(raw) shouldBe false
            rejected++
        }

        println("Property 24 (fail-closed) counters: rejected=$rejected")
        (rejected > 0) shouldBe true
    }

    test("Property 24: 公开信令端点的 user-auth 上下文仅授予规范化后完全一致的受信端点") {
        var trusted = 0
        var untrusted = 0

        // 受信端点的等价书写形态（scheme/host 大小写、默认端口省略与显式书写）。
        val trustedVariants = listOf(
            SkyBridgeServerConfig.signalingWebSocketURL,
            "wss://api.nebula-technologies.net/ws",
            "WSS://API.NEBULA-TECHNOLOGIES.NET/ws",
            "wss://api.nebula-technologies.net:443/ws",
            "https://api.nebula-technologies.net/ws"
        )

        // 刻意构造的不受信端点：换主机、换路径、带查询、降级到明文 ws。
        val untrustedVariants = listOf(
            "wss://signal.example.com/ws",
            "wss://api.nebula-technologies.net/alternate",
            "wss://api.nebula-technologies.net/ws?tenant=other",
            "wss://api.nebula-technologies.net/ws#frag",
            "ws://api.nebula-technologies.net/ws",
            "wss://evil-api.nebula-technologies.net/ws",
            "wss://api.nebula-technologies.net.evil.com/ws",
            "wss://api.nebula-technologies.net:8443/ws"
        )

        val endpointArb: Arb<Pair<String, Boolean>> = arbitrary {
            if (Arb.boolean().bind()) {
                Arb.element(trustedVariants).bind() to true
            } else {
                Arb.element(untrustedVariants).bind() to false
            }
        }

        checkAll(400, endpointArb) { (endpoint, expectTrusted) ->
            val granted = SignalingEndpointTrustPolicy.allowsUserAuthContext(endpoint)
            granted shouldBe expectTrusted

            if (expectTrusted) {
                trusted++
                // 受信的公开端点不得同时被判为免准入的诊断端点（两条路径互斥）。
                SignalingEndpointTrustPolicy.allowsDiagnosticLoopbackAuthContext(endpoint) shouldBe false
                SignalingEndpointTrustPolicy.allowsDiagnosticLocalNetworkAuthContext(endpoint) shouldBe false
            } else {
                untrusted++
            }
        }

        println("Property 24 (user-auth) counters: trusted=$trusted, untrusted=$untrusted")

        (trusted > 0) shouldBe true
        (untrusted > 0) shouldBe true
    }
})
