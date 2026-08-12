@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package com.skybridge.compass.core.webrtc

import android.os.Build
import android.util.Base64
import com.skybridge.compass.core.BuildConfig
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNames
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI

class SignalServerClient(
    private val httpClient: HttpClient = HttpClient(Android) {
        install(ContentNegotiation) { json(defaultJson) }
    },
    private val baseUrlProvider: () -> String = { SkyBridgeServerConfig.signalingServerURL },
    private val apiKeyProvider: () -> String = { SkyBridgeServerConfig.clientApiKey },
    private val userAuthContextProvider: suspend () -> UserAuthContext? = { null },
    private val userAgentProvider: () -> String = { DEFAULT_USER_AGENT },
    private val clientVersionProvider: () -> String = {
        System.getProperty("skybridge.clientVersion")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "1.0.0"
    },
    private val protocolVersionProvider: () -> String = {
        System.getProperty("skybridge.protocolVersion")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "1"
    },
    private val isDebugBuildProvider: () -> Boolean = { BuildConfig.DEBUG }
) {
    data class UserAuthContext(
        val bearerToken: String,
        val tenantId: String
    )

    @Serializable
    data class AdmissionChallengeRequestBody(
        val deviceId: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String,
        val clientVersion: String,
        val protocolVersion: String
    )

    @Serializable
    data class AdmissionChallengeResponseBody(
        val challengeId: String,
        val nonce: String,
        val tenantId: String,
        val userId: String,
        val deviceId: String,
        val clientIpHash: String,
        val clientVersion: String,
        val protocolVersion: String,
        val state: String,
        val issuedAt: Long,
        val expiresAt: Long
    )

    @Serializable
    data class AdmissionRequestBody(
        val challengeId: String,
        val signature: String,
        val deviceId: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String,
        val protocolPublicKeyBytes: String,
        val clientVersion: String,
        val protocolVersion: String
    )

    @Serializable
    data class AdmissionResponseBody(
        val admissionToken: String,
        val state: String,
        val issuedAt: Long,
        val expiresAt: Long
    )

    @Serializable
    data class RegisterSessionRequestBody(
        val sessionId: String? = null,
        val deviceId: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String,
        val ttlSeconds: Int
    )

    @Serializable
    data class RegisterSessionWithAdmissionRequestBody(
        val sessionId: String? = null,
        val ttlSeconds: Int
    )

    @Serializable
    data class RegisterSessionResponseBody(
        val sessionId: String,
        @JsonNames("sessionToken")
        val initiatorSignalingToken: String,
        val qrBootstrapToken: String,
        val turnAdmissionToken: String = "",
        val expiresIn: Int,
        val signalingServerOrigin: String
    )

    @Serializable
    data class RegisterCodeRequestBody(
        val deviceId: String,
        val deviceName: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String,
        val ttlSeconds: Int
    )

    @Serializable
    data class RegisterCodeWithAdmissionRequestBody(
        val deviceName: String,
        val ttlSeconds: Int
    )

    @Serializable
    data class RegisterCodeResponseBody(
        val code: String,
        val sessionId: String,
        @JsonNames("sessionToken")
        val initiatorToken: String,
        val turnAdmissionToken: String = "",
        val expiresIn: Int,
        val signalingServerOrigin: String
    )

    @Serializable
    data class LookupCodeResponseBody(
        val found: Boolean,
        val sessionId: String,
        @JsonNames("sessionToken")
        val responderToken: String,
        val turnAdmissionToken: String = "",
        val expiresIn: Int,
        val signalingServerOrigin: String,
        val initiatorDeviceId: String,
        val initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val initiatorProtocolPublicKeyFingerprint: String,
        val initiatorDeviceName: String? = null
    )

    @Serializable
    data class RedeemSessionRequestBody(
        val sessionId: String,
        val qrBootstrapToken: String,
        val deviceId: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String
    )

    @Serializable
    data class RedeemSessionWithAdmissionRequestBody(
        val sessionId: String,
        val qrBootstrapToken: String
    )

    @Serializable
    data class RedeemSessionResponseBody(
        val sessionId: String,
        @JsonNames("sessionToken")
        val responderSignalingToken: String,
        val turnAdmissionToken: String = "",
        val expiresIn: Int,
        val signalingServerOrigin: String,
        val initiatorDeviceId: String,
        val initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val initiatorProtocolPublicKeyFingerprint: String
    )

    data class AdmissionChallenge(
        val challengeId: String,
        val nonce: String,
        val tenantId: String,
        val userId: String,
        val deviceId: String,
        val clientIpHash: String,
        val clientVersion: String,
        val protocolVersion: String,
        val state: String,
        val issuedAtMillis: Long,
        val expiresAtMillis: Long
    ) {
        fun signaturePayload(): ByteArray =
            listOf(
                "SkyBridge-Admission-Challenge",
                challengeId,
                nonce,
                tenantId,
                userId,
                deviceId,
                clientVersion,
                protocolVersion
            ).joinToString(separator = "\n").encodeToByteArray()
    }

    data class AdmissionLease(
        val token: String,
        val state: String,
        val issuedAtMillis: Long,
        val expiresAtMillis: Long
    )

    data class TurnAdmissionLease(
        val token: String,
        val expiresInSeconds: Int
    )

    data class ConnectionCodeLease(
        val code: String,
        val sessionId: String,
        val initiatorToken: String,
        val expiresInSeconds: Int,
        val signalingServerOrigin: String,
        val turnAdmissionLease: TurnAdmissionLease? = null
    ) {
        val turnAdmissionToken: String
            get() = turnAdmissionLease?.token.orEmpty()
    }

    data class ConnectionCodeLookup(
        val sessionId: String,
        val responderToken: String,
        val expiresInSeconds: Int,
        val signalingServerOrigin: String,
        val initiatorDeviceId: String,
        val initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val initiatorProtocolPublicKeyFingerprint: String,
        val initiatorDeviceName: String? = null,
        val turnAdmissionLease: TurnAdmissionLease? = null
    ) {
        val turnAdmissionToken: String
            get() = turnAdmissionLease?.token.orEmpty()
    }

    data class SessionLease(
        val sessionId: String,
        val initiatorSignalingToken: String,
        val qrBootstrapToken: String,
        val expiresInSeconds: Int,
        val signalingServerOrigin: String,
        val turnAdmissionLease: TurnAdmissionLease? = null
    ) {
        val signalingToken: String get() = initiatorSignalingToken
        val turnAdmissionToken: String
            get() = turnAdmissionLease?.token.orEmpty()
    }

    data class RedeemedSessionLease(
        val sessionId: String,
        val responderSignalingToken: String,
        val expiresInSeconds: Int,
        val signalingServerOrigin: String,
        val initiatorDeviceId: String,
        val initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val initiatorProtocolPublicKeyFingerprint: String,
        val turnAdmissionLease: TurnAdmissionLease? = null
    ) {
        val turnAdmissionToken: String
            get() = turnAdmissionLease?.token.orEmpty()
    }

    suspend fun requestAdmissionChallenge(
        binding: ProtocolIdentityBinding
    ): AdmissionChallenge {
        val response: AdmissionChallengeResponseBody = performJsonRequest(
            path = admissionChallengePath,
            method = HttpMethod.POST,
            body = AdmissionChallengeRequestBody(
                deviceId = binding.deviceId,
                protocolSigningAlgorithm = binding.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint,
                clientVersion = clientVersionProvider(),
                protocolVersion = protocolVersionProvider()
            ),
            requiresUserAuth = true
        )
        return AdmissionChallenge(
            challengeId = response.challengeId,
            nonce = response.nonce,
            tenantId = response.tenantId,
            userId = response.userId,
            deviceId = response.deviceId,
            clientIpHash = response.clientIpHash,
            clientVersion = response.clientVersion,
            protocolVersion = response.protocolVersion,
            state = response.state,
            issuedAtMillis = response.issuedAt,
            expiresAtMillis = response.expiresAt
        )
    }

    suspend fun completeAdmission(
        challenge: AdmissionChallenge,
        binding: ProtocolIdentityBinding,
        signature: ByteArray
    ): AdmissionLease {
        val response: AdmissionResponseBody = performJsonRequest(
            path = admissionPath,
            method = HttpMethod.POST,
            body = AdmissionRequestBody(
                challengeId = challenge.challengeId,
                signature = signature.toBase64(),
                deviceId = binding.deviceId,
                protocolSigningAlgorithm = binding.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint,
                protocolPublicKeyBytes = binding.protocolPublicKeyBytes.toBase64(),
                clientVersion = challenge.clientVersion,
                protocolVersion = challenge.protocolVersion
            ),
            requiresUserAuth = true
        )
        return AdmissionLease(
            token = response.admissionToken,
            state = response.state,
            issuedAtMillis = response.issuedAt,
            expiresAtMillis = response.expiresAt
        )
    }

    suspend fun registerSession(
        sessionId: String? = null,
        binding: ProtocolIdentityBinding,
        validDurationSeconds: Int
    ): SessionLease {
        requireLegacyEndpointAllowedForDiagnostics("registerSession")
        val requestBody = makeRegisterSessionRequestBody(
            sessionId = sessionId,
            binding = binding,
            ttlSeconds = maxOf(60, validDurationSeconds)
        )
        val response: RegisterSessionResponseBody = performJsonRequest(
            path = registerSessionPath,
            method = HttpMethod.POST,
            body = requestBody
        )
        return decodeRegisterSessionResponse(response)
    }

    suspend fun registerSession(
        sessionId: String? = null,
        binding: ProtocolIdentityBinding,
        localIdentity: LocalP2PIdentity,
        validDurationSeconds: Int
    ): SessionLease {
        val admission = issueAdmissionLeaseIfAvailable(binding, localIdentity)
        return if (admission != null) {
            registerSessionWithAdmission(
                admissionToken = admission.token,
                sessionId = sessionId,
                validDurationSeconds = validDurationSeconds
            )
        } else {
            registerSession(
                sessionId = sessionId,
                binding = binding,
                validDurationSeconds = validDurationSeconds
            )
        }
    }

    suspend fun registerSessionWithAdmission(
        admissionToken: String,
        sessionId: String? = null,
        validDurationSeconds: Int
    ): SessionLease {
        val response: RegisterSessionResponseBody = performJsonRequest(
            path = registerSessionPath,
            method = HttpMethod.POST,
            body = RegisterSessionWithAdmissionRequestBody(
                sessionId = sessionId,
                ttlSeconds = maxOf(60, validDurationSeconds)
            ),
            extraHeaders = mapOf("X-SkyBridge-Admission" to admissionToken)
        )
        return decodeRegisterSessionResponse(response)
    }

    suspend fun registerConnectionCode(
        binding: ProtocolIdentityBinding,
        deviceName: String,
        validDurationSeconds: Int
    ): ConnectionCodeLease {
        requireLegacyEndpointAllowedForDiagnostics("registerConnectionCode")
        val requestBody = makeRegisterCodeRequestBody(
            binding = binding,
            deviceName = deviceName,
            ttlSeconds = maxOf(60, validDurationSeconds)
        )
        val response: RegisterCodeResponseBody = performJsonRequest(
            path = registerCodePath,
            method = HttpMethod.POST,
            body = requestBody
        )
        return decodeRegisterCodeResponse(response)
    }

    suspend fun registerConnectionCodeLegacy(
        binding: ProtocolIdentityBinding,
        deviceName: String,
        validDurationSeconds: Int
    ): ConnectionCodeLease =
        registerConnectionCode(
            binding = binding,
            deviceName = deviceName,
            validDurationSeconds = validDurationSeconds
        )

    suspend fun registerConnectionCode(
        binding: ProtocolIdentityBinding,
        localIdentity: LocalP2PIdentity,
        deviceName: String,
        validDurationSeconds: Int
    ): ConnectionCodeLease {
        val admission = issueAdmissionLeaseIfAvailable(binding, localIdentity)
        return if (admission != null) {
            registerConnectionCodeWithAdmission(
                admissionToken = admission.token,
                deviceName = deviceName,
                validDurationSeconds = validDurationSeconds
            )
        } else {
            registerConnectionCode(
                binding = binding,
                deviceName = deviceName,
                validDurationSeconds = validDurationSeconds
            )
        }
    }

    suspend fun registerConnectionCodeWithAdmission(
        admissionToken: String,
        deviceName: String,
        validDurationSeconds: Int
    ): ConnectionCodeLease {
        val response: RegisterCodeResponseBody = performJsonRequest(
            path = registerCodePath,
            method = HttpMethod.POST,
            body = RegisterCodeWithAdmissionRequestBody(
                deviceName = deviceName,
                ttlSeconds = maxOf(60, validDurationSeconds)
            ),
            extraHeaders = mapOf("X-SkyBridge-Admission" to admissionToken)
        )
        return decodeRegisterCodeResponse(response)
    }

    suspend fun registerConnectionCode(
        admissionToken: String,
        deviceName: String,
        validDurationSeconds: Int
    ): ConnectionCodeLease =
        registerConnectionCodeWithAdmission(
            admissionToken = admissionToken,
            deviceName = deviceName,
            validDurationSeconds = validDurationSeconds
        )

    suspend fun lookupConnectionCode(
        code: String,
        binding: ProtocolIdentityBinding
    ): ConnectionCodeLookup {
        requireLegacyEndpointAllowedForDiagnostics("lookupConnectionCode")
        val response: LookupCodeResponseBody = performJsonRequest(
            path = lookupCodePath(code),
            method = HttpMethod.GET,
            query = listOf(
                "deviceId" to binding.deviceId,
                "protocolSigningAlgorithm" to binding.protocolSigningAlgorithm.rawValue,
                "protocolPublicKeyFingerprint" to binding.protocolPublicKeyFingerprint
            )
        )
        return decodeLookupCodeResponse(response)
    }

    suspend fun lookupConnectionCodeLegacy(
        code: String,
        binding: ProtocolIdentityBinding
    ): ConnectionCodeLookup =
        lookupConnectionCode(
            code = code,
            binding = binding
        )

    suspend fun lookupConnectionCode(
        code: String,
        binding: ProtocolIdentityBinding,
        localIdentity: LocalP2PIdentity
    ): ConnectionCodeLookup {
        val admission = issueAdmissionLeaseIfAvailable(binding, localIdentity)
        return if (admission != null) {
            lookupConnectionCodeWithAdmission(
                admissionToken = admission.token,
                code = code
            )
        } else {
            lookupConnectionCode(
                code = code,
                binding = binding
            )
        }
    }

    suspend fun lookupConnectionCodeWithAdmission(
        admissionToken: String,
        code: String
    ): ConnectionCodeLookup {
        val response: LookupCodeResponseBody = performJsonRequest(
            path = lookupCodePath(code),
            method = HttpMethod.GET,
            extraHeaders = mapOf("X-SkyBridge-Admission" to admissionToken)
        )
        return decodeLookupCodeResponse(response)
    }

    suspend fun lookupConnectionCode(
        admissionToken: String,
        code: String
    ): ConnectionCodeLookup =
        lookupConnectionCodeWithAdmission(
            admissionToken = admissionToken,
            code = code
        )

    suspend fun redeemSession(
        sessionId: String,
        qrBootstrapToken: String,
        binding: ProtocolIdentityBinding
    ): RedeemedSessionLease {
        requireLegacyEndpointAllowedForDiagnostics("redeemSession")
        val requestBody = RedeemSessionRequestBody(
            sessionId = sessionId,
            qrBootstrapToken = qrBootstrapToken,
            deviceId = binding.deviceId,
            protocolSigningAlgorithm = binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint
        )
        val response: RedeemSessionResponseBody = performJsonRequest(
            path = redeemSessionPath,
            method = HttpMethod.POST,
            body = requestBody
        )
        return decodeRedeemSessionResponse(response)
    }

    suspend fun redeemSession(
        sessionId: String,
        qrBootstrapToken: String,
        binding: ProtocolIdentityBinding,
        localIdentity: LocalP2PIdentity
    ): RedeemedSessionLease {
        val admission = issueAdmissionLeaseIfAvailable(binding, localIdentity)
        return if (admission != null) {
            redeemSessionWithAdmission(
                admissionToken = admission.token,
                sessionId = sessionId,
                qrBootstrapToken = qrBootstrapToken
            )
        } else {
            redeemSession(
                sessionId = sessionId,
                qrBootstrapToken = qrBootstrapToken,
                binding = binding
            )
        }
    }

    suspend fun redeemSessionWithAdmission(
        admissionToken: String,
        sessionId: String,
        qrBootstrapToken: String
    ): RedeemedSessionLease {
        val response: RedeemSessionResponseBody = performJsonRequest(
            path = redeemSessionPath,
            method = HttpMethod.POST,
            body = RedeemSessionWithAdmissionRequestBody(
                sessionId = sessionId,
                qrBootstrapToken = qrBootstrapToken
            ),
            extraHeaders = mapOf("X-SkyBridge-Admission" to admissionToken)
        )
        return decodeRedeemSessionResponse(response)
    }

    private suspend inline fun <reified Response> performJsonRequest(
        path: String,
        method: HttpMethod,
        query: List<Pair<String, String>> = emptyList(),
        body: Any? = null,
        requiresUserAuth: Boolean = false,
        extraHeaders: Map<String, String> = emptyMap()
    ): Response {
        val authContext = sanitizedUserAuthContext(
            if (requiresUserAuth) {
                requireUserAuthContext()
            } else {
                userAuthContextProvider()
            }
        )
        val url = buildUrl(path, query)
        val responseText = when (method) {
            HttpMethod.GET -> httpClient.get(url) {
                applyHeaders(
                    authContext = authContext,
                    requiresUserAuth = requiresUserAuth,
                    extraHeaders = extraHeaders
                )
            }

            HttpMethod.POST -> httpClient.post(url) {
                applyHeaders(
                    authContext = authContext,
                    requiresUserAuth = requiresUserAuth,
                    extraHeaders = extraHeaders
                )
                contentType(ContentType.Application.Json)
                if (body != null) {
                    setBody(body)
                }
            }
        }.let { response ->
            val payload = response.bodyAsText()
            if (!response.status.isSuccess()) {
                throw IllegalStateException(
                    safeServerRejectionMessage(response.status.value, payload)
                )
            }
            payload
        }

        return try {
            defaultJson.decodeFromString(responseText)
        } catch (err: Throwable) {
            throw IllegalStateException("signal server malformed response")
        }
    }

    private fun HttpRequestBuilder.applyHeaders(
        authContext: UserAuthContext?,
        requiresUserAuth: Boolean,
        extraHeaders: Map<String, String>
    ) {
        header(HttpHeaders.Accept, ContentType.Application.Json)
        header(HttpHeaders.UserAgent, userAgentProvider())

        val apiKey = apiKeyProvider().trim()
        if (apiKey.isNotEmpty()) {
            header("X-API-Key", apiKey)
        }

        authContext?.tenantId?.trim()?.takeIf { it.isNotEmpty() }?.let {
            header("X-SkyBridge-Tenant-Id", it)
        }

        if (requiresUserAuth) {
            val bearerToken = authContext?.bearerToken?.trim().orEmpty()
            if (bearerToken.isEmpty()) {
                throw IllegalStateException("missing authenticated user session")
            }
            header(HttpHeaders.Authorization, "Bearer $bearerToken")
        }

        extraHeaders.forEach { (field, value) ->
            if (value.isNotBlank()) {
                header(field, value)
            }
        }
    }

    private suspend fun requireUserAuthContext(): UserAuthContext {
        val authContext = sanitizedUserAuthContext(userAuthContextProvider())
        require(authContext != null) { "missing authenticated user session" }
        require(authContext.tenantId.isNotBlank()) { "missing tenant id" }
        return authContext
    }

    private suspend fun issueAdmissionLeaseIfAvailable(
        binding: ProtocolIdentityBinding,
        localIdentity: LocalP2PIdentity
    ): AdmissionLease? {
        if (!shouldAttemptAdmissionForBaseUrl(baseUrlProvider(), userAuthContextProvider())) {
            return null
        }
        requireAdmissionAuthContext()
        val challenge = requestAdmissionChallenge(binding)
        val signature = signAdmissionChallenge(
            payload = challenge.signaturePayload(),
            binding = binding,
            localIdentity = localIdentity
        )
        return completeAdmission(
            challenge = challenge,
            binding = binding,
            signature = signature
        )
    }

    private suspend fun requireAdmissionAuthContext(): UserAuthContext {
        val raw = userAuthContextProvider()
        val bearerToken = raw?.bearerToken?.trim().orEmpty()
        val tenantId = raw?.tenantId?.trim().orEmpty()
        if (bearerToken.isEmpty()) {
            throw IllegalStateException("missing authenticated user session")
        }
        if (tenantId.isEmpty()) {
            throw IllegalStateException("missing tenant id")
        }
        return UserAuthContext(
            bearerToken = bearerToken,
            tenantId = tenantId
        )
    }

    private fun sanitizedUserAuthContext(
        authContext: UserAuthContext?
    ): UserAuthContext? {
        val bearerToken = authContext?.bearerToken?.trim().orEmpty()
        val tenantId = authContext?.tenantId?.trim().orEmpty()
        if (bearerToken.isEmpty() || tenantId.isEmpty()) {
            return null
        }
        return UserAuthContext(
            bearerToken = bearerToken,
            tenantId = tenantId
        )
    }

    private suspend fun signAdmissionChallenge(
        payload: ByteArray,
        binding: ProtocolIdentityBinding,
        localIdentity: LocalP2PIdentity
    ): ByteArray {
        val signingKeys = localIdentity.getOrCreateProtocolSigningKeys()
        return when (binding.protocolSigningAlgorithm) {
            ProtocolSigningAlgorithm.ED25519 ->
                P2PHandshakeWire.signEd25519Public(payload, signingKeys.ed25519PrivateKey)

            ProtocolSigningAlgorithm.ML_DSA_65 ->
                AndroidPQCCryptoProvider().sign(
                    payload,
                    requireNotNull(signingKeys.mlDsa65PrivateKeyRaw) {
                        "ML-DSA-65 private key unavailable for current-path admission"
                    }
                )
        }
    }

    private fun shouldUseAdmission(): Boolean {
        return shouldUseAdmissionForBaseUrl(baseUrlProvider())
    }

    private fun requireLegacyEndpointAllowedForDiagnostics(operation: String) {
        // R4.10: public signaling base URLs must use current-path admission; the legacy
        // register/lookup/redeem direct endpoints are permitted ONLY for local/private
        // diagnostic endpoints in a debug build. Any public base URL, any non-debug build,
        // or any host outside the diagnostic ranges must fail closed BEFORE a request is sent.
        if (shouldUseAdmission()) {
            throw IllegalStateException(
                "$operation requires current-path admission on public signaling endpoint"
            )
        }
        if (!isLegacyDiagnosticEndpointAllowed(baseUrlProvider())) {
            throw IllegalStateException(
                "$operation legacy signaling path rejected: current-path authentication required"
            )
        }
    }

    /**
     * R4.10 admission gate for the legacy direct signaling endpoints.
     *
     * Returns true only when the build is a debug build AND the target host is a
     * local/private diagnostic host within one of the permitted ranges
     * (127.0.0.0/8, ::1/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
     * 169.254.0.0/16, fc00::/7). All other cases (public hosts, non-debug builds,
     * unparseable URLs) return false so the caller fails closed before sending.
     */
    internal fun isLegacyDiagnosticEndpointAllowed(baseUrl: String): Boolean {
        if (!isDebugBuildProvider()) {
            return false
        }
        val host = runCatching { URI(baseUrl.trim()) }
            .getOrNull()
            ?.host
            ?.lowercase()
            ?: return false
        return isDiagnosticEndpointHost(host)
    }

    internal fun isDiagnosticEndpointHost(rawHost: String): Boolean {
        val host = normalizeHostLiteral(rawHost)
        return isIpv4DiagnosticHost(host) || isIpv6DiagnosticHost(host)
    }

    private fun normalizeHostLiteral(host: String): String {
        var normalized = host.trim().lowercase()
        if (normalized.startsWith("[") && normalized.endsWith("]")) {
            normalized = normalized.substring(1, normalized.length - 1)
        }
        // Drop an IPv6 zone identifier if present (e.g. fe80::1%eth0).
        val zoneIndex = normalized.indexOf('%')
        if (zoneIndex >= 0) {
            normalized = normalized.substring(0, zoneIndex)
        }
        return normalized
    }

    private fun isIpv4DiagnosticHost(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) {
            return false
        }
        val octets = parts.map { it.toIntOrNull() ?: return false }
        if (octets.any { it !in 0..255 }) {
            return false
        }
        return when {
            octets[0] == 127 -> true                          // 127.0.0.0/8
            octets[0] == 10 -> true                           // 10.0.0.0/8
            octets[0] == 172 && octets[1] in 16..31 -> true   // 172.16.0.0/12
            octets[0] == 192 && octets[1] == 168 -> true      // 192.168.0.0/16
            octets[0] == 169 && octets[1] == 254 -> true      // 169.254.0.0/16
            else -> false
        }
    }

    private fun isIpv6DiagnosticHost(host: String): Boolean {
        if (!host.contains(':')) {
            return false
        }
        val canonical = when (host) {
            "::1", "0:0:0:0:0:0:0:1" -> return true            // ::1/128 loopback
            else -> host
        }
        // fc00::/7 unique local addresses: first byte 0xfc or 0xfd.
        val firstGroup = canonical.substringBefore(':').takeIf { it.isNotEmpty() } ?: return false
        val firstGroupValue = firstGroup.toIntOrNull(16) ?: return false
        val firstByte = (firstGroupValue shr 8) and 0xFF
        return firstByte == 0xFC || firstByte == 0xFD
    }

    internal fun shouldUseAdmissionForBaseUrl(baseUrl: String): Boolean {
        val host = runCatching { URI(baseUrl.trim()) }
            .getOrNull()
            ?.host
            ?.lowercase()
            ?: return false
        if (host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2" || host == "::1") {
            return false
        }
        if (host.endsWith(".local")) {
            return false
        }
        return !isPrivateIpv4Host(host)
    }

    internal fun shouldAttemptAdmissionForBaseUrl(
        baseUrl: String,
        authContext: UserAuthContext?
    ): Boolean =
        shouldUseAdmissionForBaseUrl(baseUrl) || sanitizedUserAuthContext(authContext) != null

    internal fun safeServerRejectionMessage(statusCode: Int, payload: String): String {
        val errorCode = runCatching {
            defaultJson.parseToJsonElement(payload)
                .jsonObject["error"]
                ?.jsonPrimitive
                ?.content
                ?.trim()
                ?.takeIf { it.matches(Regex("[A-Za-z0-9_.:-]{1,80}")) }
        }.getOrNull()
        return if (errorCode.isNullOrEmpty()) {
            "signal server rejected ($statusCode)"
        } else {
            "signal server rejected ($statusCode, error=$errorCode)"
        }
    }

    private fun isPrivateIpv4Host(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) {
            return false
        }
        val octets = parts.map { it.toIntOrNull() ?: return false }
        return when {
            octets[0] == 10 -> true
            octets[0] == 127 -> true
            octets[0] == 192 && octets[1] == 168 -> true
            octets[0] == 172 && octets[1] in 16..31 -> true
            octets[0] == 169 && octets[1] == 254 -> true
            else -> false
        }
    }

    private fun buildUrl(path: String, query: List<Pair<String, String>>): String {
        val base = baseUrlProvider().trim().trimEnd('/')
        require(base.isNotEmpty()) { "invalid signaling base url" }
        val querySuffix = if (query.isEmpty()) {
            ""
        } else {
            query.joinToString(separator = "&", prefix = "?") { (name, value) ->
                "${encodeUrlPart(name)}=${encodeUrlPart(value)}"
            }
        }
        return "$base$path$querySuffix"
    }

    companion object {
        private val defaultJson = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
        }

        const val admissionChallengePath: String = "/api/webrtc/admission/challenge"
        const val admissionPath: String = "/api/webrtc/admission"
        const val registerCodePath: String = "/api/webrtc/register-code"
        const val registerSessionPath: String = "/api/webrtc/register-session"
        const val redeemSessionPath: String = "/api/webrtc/redeem-session"
        const val DEFAULT_USER_AGENT: String =
            "Mozilla/5.0 (Linux; Android 14; SkyBridge) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

        fun lookupCodePath(code: String): String =
            "/api/webrtc/lookup/${encodeUrlPart(code)}"

        fun makeRegisterCodeRequestBody(
            binding: ProtocolIdentityBinding,
            deviceName: String,
            ttlSeconds: Int
        ): RegisterCodeRequestBody =
            RegisterCodeRequestBody(
                deviceId = binding.deviceId,
                deviceName = deviceName,
                protocolSigningAlgorithm = binding.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint,
                ttlSeconds = ttlSeconds
            )

        fun makeRegisterSessionRequestBody(
            sessionId: String? = null,
            binding: ProtocolIdentityBinding,
            ttlSeconds: Int
        ): RegisterSessionRequestBody =
            RegisterSessionRequestBody(
                sessionId = sessionId,
                deviceId = binding.deviceId,
                protocolSigningAlgorithm = binding.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint,
                ttlSeconds = ttlSeconds
            )

        fun decodeRegisterCodeResponse(response: RegisterCodeResponseBody): ConnectionCodeLease =
            ConnectionCodeLease(
                code = response.code,
                sessionId = response.sessionId,
                initiatorToken = response.initiatorToken,
                expiresInSeconds = response.expiresIn,
                signalingServerOrigin = response.signalingServerOrigin,
                turnAdmissionLease = turnAdmissionLease(
                    token = response.turnAdmissionToken,
                    expiresInSeconds = response.expiresIn
                )
            )

        fun decodeLookupCodeResponse(response: LookupCodeResponseBody): ConnectionCodeLookup {
            require(response.found) { "code_not_found" }
            require(response.responderToken.isNotBlank()) { "missing responderToken" }
            return ConnectionCodeLookup(
                sessionId = response.sessionId,
                responderToken = response.responderToken,
                expiresInSeconds = response.expiresIn,
                signalingServerOrigin = response.signalingServerOrigin,
                initiatorDeviceId = response.initiatorDeviceId,
                initiatorProtocolSigningAlgorithm = response.initiatorProtocolSigningAlgorithm,
                initiatorProtocolPublicKeyFingerprint = response.initiatorProtocolPublicKeyFingerprint,
                initiatorDeviceName = response.initiatorDeviceName,
                turnAdmissionLease = turnAdmissionLease(
                    token = response.turnAdmissionToken,
                    expiresInSeconds = response.expiresIn
                )
            )
        }

        fun decodeRegisterSessionResponse(response: RegisterSessionResponseBody): SessionLease =
            SessionLease(
                sessionId = response.sessionId,
                initiatorSignalingToken = response.initiatorSignalingToken,
                qrBootstrapToken = response.qrBootstrapToken,
                expiresInSeconds = response.expiresIn,
                signalingServerOrigin = response.signalingServerOrigin,
                turnAdmissionLease = turnAdmissionLease(
                    token = response.turnAdmissionToken,
                    expiresInSeconds = response.expiresIn
                )
            )

        fun decodeRedeemSessionResponse(response: RedeemSessionResponseBody): RedeemedSessionLease =
            RedeemedSessionLease(
                sessionId = response.sessionId,
                responderSignalingToken = response.responderSignalingToken,
                expiresInSeconds = response.expiresIn,
                signalingServerOrigin = response.signalingServerOrigin,
                initiatorDeviceId = response.initiatorDeviceId,
                initiatorProtocolSigningAlgorithm = response.initiatorProtocolSigningAlgorithm,
                initiatorProtocolPublicKeyFingerprint = response.initiatorProtocolPublicKeyFingerprint,
                turnAdmissionLease = turnAdmissionLease(
                    token = response.turnAdmissionToken,
                    expiresInSeconds = response.expiresIn
                )
            )

        fun defaultUserAgent(): String {
            val release = Build.VERSION.RELEASE?.trim().takeUnless { it.isNullOrEmpty() } ?: "Android"
            val model = Build.MODEL?.trim().takeUnless { it.isNullOrEmpty() } ?: "Device"
            return "Mozilla/5.0 (Linux; Android $release; $model) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
        }

        private fun turnAdmissionLease(
            token: String,
            expiresInSeconds: Int
        ): TurnAdmissionLease? {
            val trimmedToken = token.trim()
            if (trimmedToken.isEmpty()) {
                return null
            }
            return TurnAdmissionLease(
                token = trimmedToken,
                expiresInSeconds = minOf(expiresInSeconds, 60)
            )
        }

        private fun encodeUrlPart(value: String): String =
            java.net.URLEncoder.encode(value, Charsets.UTF_8.name())
                .replace("+", "%20")
    }

    private enum class HttpMethod {
        GET,
        POST
    }
}

private fun ByteArray.toBase64(): String =
    Base64.encodeToString(this, Base64.NO_WRAP)
