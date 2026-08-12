package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.productsession.ProductSessionOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Attribution of the candidate pair currently selected by WebRTC.
 *
 * [DIRECT] means only that neither selected candidate is a TURN relay candidate. It is not a
 * stronger claim about NAT topology or physical network adjacency. Missing or unrecognized
 * candidate metadata is always [UNKNOWN], so direct-only callers fail closed.
 */
enum class WebRtcSelectedRoute {
    DIRECT,
    RELAY,
    UNKNOWN
}

/** Route evidence bound to one exact product-session incarnation. */
data class WebRtcSelectedRouteWitness(
    val owner: ProductSessionOwner,
    val route: WebRtcSelectedRoute
)

/**
 * Pure policy for classifying the selected ICE candidate pair.
 *
 * Candidate addresses are deliberately neither retained nor returned. A relay on either side is
 * conclusive relay evidence; otherwise both candidate types must be recognized before the pair can
 * be called direct.
 */
internal object WebRtcSelectedCandidatePairPolicy {
    private enum class CandidateType {
        HOST,
        SERVER_REFLEXIVE,
        PEER_REFLEXIVE,
        RELAY
    }

    fun classify(
        localCandidateSdp: String?,
        remoteCandidateSdp: String?
    ): WebRtcSelectedRoute {
        val localType = candidateType(localCandidateSdp)
        val remoteType = candidateType(remoteCandidateSdp)
        if (localType == CandidateType.RELAY || remoteType == CandidateType.RELAY) {
            return WebRtcSelectedRoute.RELAY
        }
        if (localType == null || remoteType == null) {
            return WebRtcSelectedRoute.UNKNOWN
        }
        return WebRtcSelectedRoute.DIRECT
    }

    private fun candidateType(candidateSdp: String?): CandidateType? {
        val tokens = candidateSdp
            ?.trim()
            ?.removePrefix("a=")
            ?.split(Regex("\\s+"))
            ?.takeIf { parts -> parts.firstOrNull()?.startsWith("candidate:") == true }
            ?: return null
        val typeIndex = tokens.indexOfFirst { it.equals("typ", ignoreCase = true) }
        val rawType = tokens.getOrNull(typeIndex + 1)?.lowercase() ?: return null
        return when (rawType) {
            "host" -> CandidateType.HOST
            "srflx" -> CandidateType.SERVER_REFLEXIVE
            "prflx" -> CandidateType.PEER_REFLEXIVE
            "relay" -> CandidateType.RELAY
            else -> null
        }
    }
}

/** Direct-only admission is exact-owner and fail-closed. */
object WebRtcDirectRouteAdmissionPolicy {
    fun allows(
        owner: ProductSessionOwner,
        witness: WebRtcSelectedRouteWitness?
    ): Boolean = witness?.owner == owner && witness.route == WebRtcSelectedRoute.DIRECT
}

/**
 * Stores only the current owner's route witness. Binding a replacement publishes UNKNOWN before
 * it can acquire route evidence, and a delayed callback from the replaced owner cannot commit.
 */
internal class OwnerBoundWebRtcRouteStore {
    private val lock = Any()
    private val mutableWitness = MutableStateFlow<WebRtcSelectedRouteWitness?>(null)

    val witness: StateFlow<WebRtcSelectedRouteWitness?> = mutableWitness.asStateFlow()

    fun bind(owner: ProductSessionOwner) = synchronized(lock) {
        mutableWitness.value = WebRtcSelectedRouteWitness(owner, WebRtcSelectedRoute.UNKNOWN)
    }

    fun commit(owner: ProductSessionOwner, route: WebRtcSelectedRoute): Boolean =
        synchronized(lock) {
            val current = mutableWitness.value
            if (current?.owner != owner) {
                return@synchronized false
            }
            mutableWitness.value = WebRtcSelectedRouteWitness(owner, route)
            true
        }

    fun current(owner: ProductSessionOwner): WebRtcSelectedRoute? = synchronized(lock) {
        mutableWitness.value
            ?.takeIf { it.owner == owner }
            ?.route
    }

    fun clearIfOwned(owner: ProductSessionOwner): Boolean = synchronized(lock) {
        if (mutableWitness.value?.owner != owner) {
            return@synchronized false
        }
        mutableWitness.value = null
        true
    }

    fun clear() = synchronized(lock) {
        mutableWitness.value = null
    }
}
