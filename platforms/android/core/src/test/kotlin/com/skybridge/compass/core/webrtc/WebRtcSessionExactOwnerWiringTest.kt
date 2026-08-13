package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Locks the pure owner gate into the real manager callback and authority-store paths. */
class WebRtcSessionExactOwnerWiringTest {
    @Test
    fun managerClaimsOwnerAndThreadsItThroughNativeCallbacks() {
        val source = managerSource()

        assertTrue(source.contains("private val sessionOwnerGate = WebRtcSessionOwnerGate()"))
        assertTrue(source.contains("val transition = sessionOwnerGate.begin(sessionId)"))
        assertTrue(source.contains("productSessionAuthorityStore?.claimSession(owner)"))
        assertTrue(source.contains("attachSessionCallbacks(created, owner)"))
        assertTrue(source.contains("private fun attachSessionCallbacks(s: WebRtcSession, owner: ProductSessionOwner)"))
        assertTrue(source.contains("runIfCurrentSession(owner)"))
        assertTrue(source.contains("if (session !== s) return@runIfCurrentSession"))
        assertTrue(source.contains("failCurrentSession(\n                    owner,"))
        assertTrue(source.contains("handleInboundFrame(owner, frame)"))
        assertFalse(source.contains("attachSessionCallbacks(created, sessionId)"))
    }

    @Test
    fun signalingDeadlineHandshakeAndHeartbeatCarryExactOwner() {
        val source = managerSource()

        assertTrue(source.contains("callbackSignaling === signaling && sessionOwnerGate.isCurrent(owner)"))
        assertTrue(source.contains("private fun armEstablishmentDeadline(owner: ProductSessionOwner)"))
        assertTrue(source.contains("if (!sessionOwnerGate.isCurrent(owner)) return@launch"))
        assertTrue(source.contains("private fun onHandshakeEstablished(\n        owner: ProductSessionOwner,"))
        assertTrue(source.contains("private fun onHandshakeFailed(\n        owner: ProductSessionOwner,"))
        assertTrue(source.contains("private fun startAppHeartbeatLoop(owner: ProductSessionOwner)"))
        assertTrue(source.contains("while (sessionOwnerGate.isCurrent(owner) && sessionKeys != null)"))
        assertTrue(source.contains("private fun scheduleHandshakeStart(owner: ProductSessionOwner"))
    }

    @Test
    fun routeAuthorityMutationsNeverUseBareSessionId() {
        val source = managerSource()

        assertTrue(source.contains("sessionOwner = owner"))
        assertTrue(source.contains("clearEstablishedAuthority(owner)"))
        assertTrue(source.contains("markFailed(owner)"))
        assertTrue(source.contains("markDisconnected(owner)"))
        assertFalse(source.contains("productSessionAuthorityStore?.clearSession(sessionId)"))
        assertFalse(source.contains("productSessionAuthorityStore?.clearSession(sessionCode)"))
    }

    @Test
    fun handshakeSuccessDoesNotBecomeDurableTrustWithoutPairingApproval() {
        val source = managerSource()
        assertFalse(source.contains("persistCurrentPathTrust"))
        assertTrue(source.contains("AuthenticatedPairingPersistence("))
        assertTrue(source.contains("observedProtocolFingerprint = observedProtocolFingerprint"))
        assertFalse(source.contains("observedAuthority = currentAuthority"))
        assertTrue(source.contains("observedHandshakeAuthority?.takeIf { it.owner == owner }"))
        assertTrue(source.contains("currentPathExpectedRemoteAuthorityBySessionId[owner.sessionId]"))
        assertTrue(source.contains("private val pairingIdentityExchangeMutex = Mutex()"))
        assertTrue(
            source.contains(
                "PairingTrustManager.requestDecision(\n                request = request,\n                isKnownDevice = exactExistingAuthority != null"
            )
        )
        val establishStart = source.indexOf("private fun onHandshakeEstablished(")
        val exchangeStart = source.indexOf("private suspend fun processIncomingPairingIdentityExchange(")
        require(establishStart >= 0 && exchangeStart > establishStart) {
            "handshake and pairing exchange blocks not found"
        }
        val establishBody = source.substring(establishStart, exchangeStart)
        assertFalse(establishBody.contains("upsertCurrentPathAuthority"))
        assertFalse(establishBody.contains("upsertVerifiedCurrentPathAuthority"))
        assertFalse(establishBody.contains("AuthenticatedPairingPersistence("))
    }

    @Test
    fun preAuthenticationJoinKemRemainsEphemeralUntilVerifiedPairing() {
        val source = managerSource()
        val ingestStart = source.indexOf("private fun ingestJoinBootstrap(")
        val ingestEnd = source.indexOf("private fun rememberJoinBootstrapAuthority(", ingestStart)
        require(ingestStart >= 0 && ingestEnd > ingestStart) {
            "JOIN bootstrap ingress source block not found"
        }
        val ingestBody = source.substring(ingestStart, ingestEnd)

        assertTrue(ingestBody.contains("PeerKemKeyStoreRecords.materialize("))
        assertTrue(ingestBody.contains("pendingJoinBootstrapKem = pending"))
        assertFalse(ingestBody.contains("peerKemStore.save("))
        assertFalse(ingestBody.contains("peerKemStore.saveForAliases("))
        assertFalse(ingestBody.contains("peerKemStore::clearQPeriapt"))
        assertTrue(source.contains("val pending = currentPendingJoinBootstrapKeys(owner, normalizedPeerId)"))
        assertTrue(source.contains("pendingJoinBootstrapKem = null"))
    }

    @Test
    fun allowOnceKemUsesExactOwnerSessionSlotWithoutLegacyOrJoinFallback() {
        val source = managerSource()
        val pairingStart = source.indexOf("private suspend fun processIncomingPairingIdentityExchangeLocked(")
        val pairingEnd = source.indexOf("private suspend fun sendPairingIdentityExchangeIfNeeded(", pairingStart)
        require(pairingStart >= 0 && pairingEnd > pairingStart) {
            "pairing persistence source block not found"
        }
        val pairingBody = source.substring(pairingStart, pairingEnd)
        assertTrue(pairingBody.contains("persistApprovedAttemptWithOutcome("))
        assertTrue(pairingBody.contains("authenticatedSessionPeerKemStore.install(owner, outcome)"))
        assertTrue(pairingBody.contains("persistenceOutcome = outcome"))
        assertTrue(pairingBody.contains("maybeStartPqcRekey(owner, trigger = \"pairing_identity_exchange\")"))

        val rekeyStart = source.indexOf("private suspend fun maybeStartPqcRekey(")
        val rekeyEnd = source.indexOf("private fun currentPeerId()", rekeyStart)
        require(rekeyStart >= 0 && rekeyEnd > rekeyStart) { "PQC rekey source block not found" }
        val rekeyBody = source.substring(rekeyStart, rekeyEnd)
        assertTrue(rekeyBody.contains("authenticatedSessionPeerKemStore.lookup("))
        assertTrue(rekeyBody.contains("resolveAuthenticatedSessionPeerKemForRekey("))
        assertTrue(rekeyBody.contains("peerKemStore.loadVerifiedReadOnly(peerId)"))
        assertFalse(rekeyBody.contains("peerKemStore.load(peerId)"))
        assertFalse(rekeyBody.contains("pendingJoinBootstrapKem"))
    }

    @Test
    fun existingTrustOnlyPathUsesReadOnlyAuthorityAndKemWithoutPersistence() {
        val source = managerSource()
        val pairingStart = source.indexOf("private suspend fun processIncomingPairingIdentityExchangeLocked(")
        val pairingEnd = source.indexOf("private suspend fun sendPairingIdentityExchangeIfNeeded(", pairingStart)
        require(pairingStart >= 0 && pairingEnd > pairingStart) {
            "pairing persistence source block not found"
        }
        val pairingBody = source.substring(pairingStart, pairingEnd)
        val existingOnlyStart = pairingBody.indexOf("if (diagnosticsConfig.existingTrustOnly)")
        val normalPathStart = pairingBody.indexOf(
            "val storeConflict = trustedPeerStore.corruptionConflictOrNull()",
            existingOnlyStart
        )
        val normalDecisionStart = pairingBody.indexOf("val decision = when", normalPathStart)
        require(existingOnlyStart >= 0 && normalPathStart > existingOnlyStart && normalDecisionStart > normalPathStart) {
            "existing-trust-only branch not found before the mutating approval path"
        }
        val existingOnlyBody = pairingBody.substring(existingOnlyStart, normalPathStart)

        assertTrue(existingOnlyBody.contains("evaluateExactExistingAuthorityReadOnly("))
        assertTrue(existingOnlyBody.contains("admission.exactAuthority == null"))
        assertTrue(existingOnlyBody.contains("peerKemStore.loadVerifiedReadOnly(peerId)"))
        assertTrue(existingOnlyBody.contains("existingKem.hasSamePeerKemMaterial(presentedKem)"))
        assertTrue(existingOnlyBody.contains("existingTrustPeerKemAdmissionState.wasSentBy(secureOwner)"))
        assertTrue(existingOnlyBody.contains("existingTrustPeerKemAdmissionState.install(secureOwner)"))
        assertTrue(existingOnlyBody.contains("updateAuthenticatedPeerMetadata(payload)"))
        assertFalse(existingOnlyBody.contains("force = true"))
        assertFalse(existingOnlyBody.contains("PairingTrustManager.requestDecision("))
        assertFalse(existingOnlyBody.contains("AuthenticatedPairingPersistence("))
        assertFalse(existingOnlyBody.contains("peerKemStore.save"))
        assertFalse(existingOnlyBody.contains("corruptionConflictOrNull()"))
        assertFalse(existingOnlyBody.contains("evaluateCurrentPathBinding("))

        assertFalse(pairingBody.contains("failSecureTransport(owner,"))
        assertTrue(pairingBody.contains("failSecureOperation(secureOwner,"))

        val initialKemStart = source.indexOf("private fun initialPeerKem(")
        val initialKemEnd = source.indexOf("private fun currentPendingJoinBootstrapKeys(", initialKemStart)
        val initialKemBody = source.substring(initialKemStart, initialKemEnd)
        assertTrue(initialKemBody.contains("val persisted = normalizedPeerId?.let(::loadPeerKem)"))
        assertTrue(initialKemBody.contains("if (diagnosticsConfig.existingTrustOnly)"))
        assertTrue(initialKemBody.contains("return persisted"))
    }

    @Test
    fun sessionOnlyKemIsClearedOnReplacementTerminalStateAndSuccessfulRekey() {
        val source = managerSource()
        assertTrue(source.contains("private val authenticatedSessionPeerKemStore = AuthenticatedSessionPeerKemStore()"))
        val prepareStart = source.indexOf("private suspend fun prepareForSessionStart(")
        val prepareEnd = source.indexOf("private suspend fun resetConnection(", prepareStart)
        require(prepareStart >= 0 && prepareEnd > prepareStart) {
            "session preparation source block not found"
        }
        val prepareBody = source.substring(prepareStart, prepareEnd)
        val ownerGateIndex = prepareBody.indexOf("sessionOwnerGate.runIfCurrent(owner)")
        val lifecycleCallIndex = prepareBody.indexOf(
            "authenticatedSessionPeerKemStore.applyLifecycleEvent("
        )
        val ownerStartedIndex = prepareBody.indexOf(
            "AuthenticatedSessionPeerKemLifecycleEvent.OWNER_STARTED"
        )
        val pendingJoinClearIndex = prepareBody.indexOf("pendingJoinBootstrapKem = null")
        assertTrue(
            ownerGateIndex >= 0 &&
                lifecycleCallIndex > ownerGateIndex &&
                ownerStartedIndex > lifecycleCallIndex &&
                pendingJoinClearIndex > ownerStartedIndex
        )

        val terminateStart = source.indexOf("private fun terminateDisconnectedOwner(")
        val terminateEnd = source.indexOf("private fun clearSessionCredentials", terminateStart)
        val terminateBody = source.substring(terminateStart, terminateEnd)
        assertTrue(terminateBody.contains("AuthenticatedSessionPeerKemLifecycleEvent.SESSION_DISCONNECTED"))
        assertTrue(
            terminateBody.indexOf("authenticatedSessionPeerKemStore.applyLifecycleEvent(") <
                terminateBody.indexOf("sessionOwnerGate.releaseIfCurrent(owner)")
        )

        val failStart = source.indexOf("private fun failCurrentSession(")
        val failEnd = source.indexOf("private suspend fun dynamicIceConfig", failStart)
        val failBody = source.substring(failStart, failEnd)
        assertTrue(failBody.contains("AuthenticatedSessionPeerKemLifecycleEvent.SESSION_FAILED"))
        assertTrue(
            failBody.indexOf("authenticatedSessionPeerKemStore.applyLifecycleEvent(") <
                failBody.indexOf("sessionOwnerGate.releaseIfCurrent(owner)")
        )

        val establishedStart = source.indexOf("private fun onHandshakeEstablished(")
        val establishedEnd = source.indexOf("private fun onHandshakeFailed(", establishedStart)
        val establishedBody = source.substring(establishedStart, establishedEnd)
        assertTrue(
            establishedBody.contains(
                "AuthenticatedSessionPeerKemLifecycleEvent.REKEY_SUCCEEDED"
            )
        )

        val handshakeFailureStart = source.indexOf("private fun onHandshakeFailed(")
        val handshakeFailureEnd = source.indexOf("private fun armEstablishmentDeadline(", handshakeFailureStart)
        val handshakeFailureBody = source.substring(handshakeFailureStart, handshakeFailureEnd)
        assertTrue(
            handshakeFailureBody.contains(
                "AuthenticatedSessionPeerKemLifecycleEvent.REKEY_FAILED"
            )
        )
    }

    @Test
    fun authorityCapacityRejectionReleasesOwnerAndStopsSessionPreparation() {
        val source = managerSource()

        assertTrue(
            source.contains(
                "val ownerClaim = productSessionAuthorityStore?.claimSession(owner)"
            )
        )
        assertTrue(
            source.contains(
                "ProductSessionOwnerClaimResult.CAPACITY_REACHED ->"
            )
        )
        assertTrue(source.contains("ProductSessionOwnerClaimResult.CLAIMED,"))
        assertTrue(source.contains("ProductSessionOwnerClaimResult.REPLACED_EXISTING_OWNER,"))
        assertTrue(source.contains("ProductSessionOwnerClaimResult.ALREADY_CURRENT,"))
        assertTrue(source.contains("sessionOwnerGate.releaseIfCurrent(owner)"))
        assertTrue(source.contains("SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)"))
        assertTrue(source.contains("throw IllegalStateException(\"Product session owner capacity reached\")"))
    }

    @Test
    fun terminalAuthorityMutationPrecedesOwnerRelease() {
        val source = managerSource()
        val resetStart = source.indexOf("private suspend fun resetConnection(")
        val resetEnd = source.indexOf("private fun bindSignalingCallbacks", resetStart)
        require(resetStart >= 0 && resetEnd > resetStart) { "resetConnection source block not found" }
        val resetBody = source.substring(resetStart, resetEnd)
        assertTrue(resetBody.contains("terminateDisconnectedOwner(owner)"))

        val terminateStart = source.indexOf("private fun terminateDisconnectedOwner(")
        val terminateEnd = source.indexOf("private fun clearSessionCredentials", terminateStart)
        require(terminateStart >= 0 && terminateEnd > terminateStart) {
            "terminateDisconnectedOwner source block not found"
        }
        val terminateBody = source.substring(terminateStart, terminateEnd)
        assertTrue(
            terminateBody.indexOf("productSessionAuthorityStore?.markDisconnected(owner)") <
                terminateBody.indexOf("sessionOwnerGate.releaseIfCurrent(owner)")
        )

        val failStart = source.indexOf("private fun failCurrentSession(")
        val failEnd = source.indexOf("private suspend fun dynamicIceConfig", failStart)
        require(failStart >= 0 && failEnd > failStart) { "failCurrentSession source block not found" }
        val failBody = source.substring(failStart, failEnd)
        assertTrue(failBody.contains("productSessionAuthorityStore?.markFailed(owner)"))
        assertTrue(
            failBody.indexOf("productSessionAuthorityStore?.markFailed(owner)") <
                failBody.indexOf("sessionOwnerGate.releaseIfCurrent(owner)")
        )
    }

    @Test
    fun applicationDataCryptoAndSelectedRouteCarryExactOwner() {
        val source = managerSource()

        assertTrue(source.contains("fun currentEstablishedOwner(): ProductSessionOwner?"))
        assertTrue(source.contains("fun hasSessionKeys(owner: ProductSessionOwner): Boolean"))
        assertTrue(source.contains("fun selectedRoute(owner: ProductSessionOwner): WebRtcSelectedRoute?"))
        assertTrue(source.contains("fun hasDirectRoute(owner: ProductSessionOwner): Boolean"))
        assertTrue(source.contains("owner: ProductSessionOwner,\n        preimage: ByteArray"))
        assertTrue(source.contains("onOwnedPacketData?.invoke(owner, plain, openedEnvelope.packetType)"))
        assertTrue(source.contains("s.onSelectedRoute = { route ->"))
        assertTrue(source.contains("if (session !== s) return@runIfCurrentSession"))
        assertTrue(source.contains("selectedRouteStore.commit(owner, route)"))
        assertTrue(source.contains("fun currentSecureOperationOwner(): WebRtcSecureOperationOwner?"))
        assertTrue(source.contains("secureOperationOwnerState.isCurrent(capability, owner, keys)"))
        assertTrue(source.contains("secureOperationOwnerState.replace(owner, keys)"))
        assertTrue(source.contains("fun failSecureOperation("))
        assertTrue(source.contains("withCurrentSecureOperationOwner(owner, false)"))
        assertTrue(source.contains("val closingSession = session"))
        assertTrue(source.contains("session = null"))
        assertTrue(source.contains("fun runIfCurrentSecureOperationOwner("))
        assertTrue(source.contains("commit()"))
        assertTrue(source.contains("onSecurePacketData?.invoke(secureOwner, plain, openedEnvelope.packetType)"))
    }

    private fun managerSource(): String {
        val sourceFile = listOf(
            File("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"),
            File("src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt")
        ).firstOrNull { it.isFile }
            ?: error("SkyBridgeWebRtcConnectionManager source file not found from cwd=${File(".").absolutePath}")
        return sourceFile.readText()
    }
}
