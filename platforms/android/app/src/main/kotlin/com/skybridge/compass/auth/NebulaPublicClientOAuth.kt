package com.skybridge.compass.auth

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import com.skybridge.compass.BuildConfig
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.forms.submitForm
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpHeaders
import io.ktor.http.Parameters
import io.ktor.http.isSuccess
import java.security.MessageDigest
import java.security.SecureRandom
import java.net.URI
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Nebula OAuth 2.1 public-client (PKCE) launcher for Android — mirrors the iOS
 * `NebulaPublicClientOAuth` contract 1:1:
 *
 * - Endpoints: `{baseURL}/oauth/authorize`, `/oauth/token`, `/oauth/userinfo`
 * - PKCE: S256 `code_verifier` / `code_challenge`, random `state`
 * - Scopes: `openid profile email offline_access`
 * - Redirect URI: `skybridge://auth/nebula` (must be registered exact-match server side)
 *
 * Where iOS uses `ASWebAuthenticationSession`, Android launches Chrome Custom Tabs and
 * captures the redirect via [NebulaRedirectActivity], which feeds the callback URL back
 * through [NebulaOAuthCoordinator]. The resulting OIDC `id_token` is then handed to
 * [AuthRepository.loginWithNebulaIdToken] (Supabase `grant_type=id_token`, provider=nebula),
 * exactly like the Google flow consumes a Google `id_token`.
 *
 * All logic lives here / in the coordinator — never inline in a Composable.
 */
object NebulaOAuthConfig {
    val baseURL: String get() = BuildConfig.NEBULA_BASE_URL.trim().trimEnd('/')
    val clientId: String get() = BuildConfig.NEBULA_CLIENT_ID.trim()

    /** Mirrors iOS `SkyBridgeServerConfig.hasNebulaConfiguration`. */
    val isConfigured: Boolean
        get() = baseURL.isNotBlank() && clientId.isNotBlank() && isValidBaseURL(baseURL) && !isPlaceholder()

    /** Registered redirect URI — must match the server-side public-client registration. */
    const val REDIRECT_URI: String = "skybridge://auth/nebula"
    const val CALLBACK_SCHEME: String = "skybridge"

    val scopes: List<String> = listOf("openid", "profile", "email", "offline_access")

    private fun isValidBaseURL(value: String): Boolean {
        return isValidNebulaOAuthBaseUrl(value)
    }

    private fun isPlaceholder(): Boolean {
        val b = baseURL.lowercase()
        return b.contains("your-nebula-host") ||
            b.contains("example.com") ||
            clientId.equals("your-nebula-client-id", ignoreCase = true)
    }
}

internal fun isValidNebulaOAuthBaseUrl(value: String): Boolean {
    val uri = try {
        URI(value.trim())
    } catch (_: java.net.URISyntaxException) {
        return false
    }
    return !uri.isOpaque &&
        uri.scheme.equals("https", ignoreCase = true) &&
        !uri.host.isNullOrBlank() &&
        uri.rawUserInfo == null &&
        uri.rawQuery == null &&
        uri.rawFragment == null &&
        (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/") &&
        (uri.port == -1 || uri.port in 1..65535)
}

/** Thrown when the Nebula OAuth flow fails. Message is user-presentable. */
class NebulaOAuthException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

/**
 * Bridges the system-browser redirect back to the suspending OAuth flow.
 *
 * The flow installs a [CompletableDeferred] before launching Custom Tabs;
 * [NebulaRedirectActivity] resolves it with the captured callback [Uri].
 */
object NebulaOAuthCoordinator {
    private val mutex = Mutex()
    @Volatile
    private var pending: CompletableDeferred<Uri>? = null

    suspend fun awaitCallback(install: () -> Unit): Uri {
        val deferred = CompletableDeferred<Uri>()
        mutex.withLock {
            // Cancel any stale in-flight attempt so we never leak a hung continuation.
            pending?.cancel()
            pending = deferred
        }
        install()
        return try {
            deferred.await()
        } finally {
            mutex.withLock {
                if (pending === deferred) pending = null
            }
        }
    }

    /** Called from [NebulaRedirectActivity] when the browser redirects to skybridge://auth/nebula. */
    fun deliver(uri: Uri): Boolean {
        val p = pending ?: return false
        return p.complete(uri)
    }

    fun fail(reason: Throwable) {
        pending?.completeExceptionally(reason)
    }
}

/**
 * Performs the Nebula OAuth 2.1 + PKCE authorization-code exchange and returns the
 * OIDC `id_token` (preferred) — falling back to the access token only if no id_token is issued.
 */
class NebulaPublicClientOAuth(
    private val httpClient: HttpClient,
    private val json: Json
) {
    data class AuthorizationRequest(
        val authorizeUri: Uri,
        val state: String,
        val codeVerifier: String,
        val redirectUri: String
    )

    /** Result of a successful flow: the token used by Supabase + best-effort profile hints. */
    data class NebulaTokens(
        val idToken: String,
        val accessToken: String?,
        val refreshToken: String?
    )

    fun makeAuthorizationRequest(register: Boolean): AuthorizationRequest {
        require(NebulaOAuthConfig.isConfigured) { "Nebula OAuth is not configured" }
        val codeVerifier = generateCodeVerifier()
        val codeChallenge = codeChallenge(codeVerifier)
        val state = generateState()

        val builder = "${NebulaOAuthConfig.baseURL}/oauth/authorize".toUri().buildUpon()
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("client_id", NebulaOAuthConfig.clientId)
            .appendQueryParameter("redirect_uri", NebulaOAuthConfig.REDIRECT_URI)
            .appendQueryParameter("scope", NebulaOAuthConfig.scopes.joinToString(" "))
            .appendQueryParameter("state", state)
            .appendQueryParameter("code_challenge", codeChallenge)
            .appendQueryParameter("code_challenge_method", "S256")
        if (register) {
            builder.appendQueryParameter("flow", "register")
        }

        return AuthorizationRequest(
            authorizeUri = builder.build(),
            state = state,
            codeVerifier = codeVerifier,
            redirectUri = NebulaOAuthConfig.REDIRECT_URI
        )
    }

    /**
     * Drive the full flow: launch Custom Tabs, await the redirect, validate state,
     * exchange the code → tokens.
     */
    suspend fun authenticate(context: Context, register: Boolean): NebulaTokens {
        if (!NebulaOAuthConfig.isConfigured) {
            throw NebulaOAuthException("Nebula OAuth 未配置")
        }
        val request = makeAuthorizationRequest(register)
        val appContext = context.applicationContext

        val callback = NebulaOAuthCoordinator.awaitCallback {
            launchCustomTab(appContext, request.authorizeUri)
        }

        // Validate the redirect.
        val error = callback.getQueryParameter("error")
        if (!error.isNullOrBlank()) {
            val description = callback.getQueryParameter("error_description")?.takeIf { it.isNotBlank() } ?: error
            throw NebulaOAuthException(description)
        }
        val returnedState = callback.getQueryParameter("state")
        if (returnedState != request.state) {
            throw NebulaOAuthException("Nebula 回调状态校验失败")
        }
        val code = callback.getQueryParameter("code")
        if (code.isNullOrBlank()) {
            throw NebulaOAuthException("Nebula 回调缺少授权码")
        }

        return exchangeAuthorizationCode(code, request)
    }

    private fun launchCustomTab(context: Context, uri: Uri) {
        val intent = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .build()
        intent.intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { intent.launchUrl(context, uri) }
            .onFailure { NebulaOAuthCoordinator.fail(NebulaOAuthException("无法打开系统浏览器进行 Nebula 授权", it)) }
    }

    private suspend fun exchangeAuthorizationCode(
        code: String,
        request: AuthorizationRequest
    ): NebulaTokens {
        val tokenUrl = "${NebulaOAuthConfig.baseURL}/oauth/token"
        val resp: HttpResponse = httpClient.submitForm(
            url = tokenUrl,
            formParameters = Parameters.build {
                append("grant_type", "authorization_code")
                append("client_id", NebulaOAuthConfig.clientId)
                append("code", code)
                append("redirect_uri", request.redirectUri)
                append("code_verifier", request.codeVerifier)
            }
        ) {
            header(HttpHeaders.Accept, "application/json")
        }

        if (!resp.status.isSuccess()) {
            val body = try {
                resp.body<String>()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                ""
            }
            throw NebulaOAuthException("Nebula 令牌交换失败：HTTP ${resp.status.value} ${body.take(200)}")
        }

        val bodyText: String = resp.body()
        val obj = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull()
            ?: throw NebulaOAuthException("Nebula 令牌响应不可解析")

        val idToken = obj["id_token"]?.jsonPrimitive?.contentOrNull
        val accessToken = obj["access_token"]?.jsonPrimitive?.contentOrNull
        val refreshToken = obj["refresh_token"]?.jsonPrimitive?.contentOrNull

        // Supabase id_token grant strictly needs an OIDC id_token. Fail honestly if absent.
        if (idToken.isNullOrBlank()) {
            throw NebulaOAuthException("Nebula 未返回 id_token（OIDC），无法完成 Supabase 登录")
        }

        return NebulaTokens(
            idToken = idToken,
            accessToken = accessToken,
            refreshToken = refreshToken
        )
    }

    private fun generateCodeVerifier(): String = base64Url(randomBytes(32))

    private fun codeChallenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
        return base64Url(digest)
    }

    private fun generateState(): String = base64Url(randomBytes(24))

    private fun randomBytes(size: Int): ByteArray {
        val bytes = ByteArray(size)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    private fun base64Url(bytes: ByteArray): String =
        android.util.Base64.encodeToString(
            bytes,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
}
