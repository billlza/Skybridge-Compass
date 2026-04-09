package com.skybridge.compass.core.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import kotlinx.coroutines.flow.StateFlow

/**
 * Thin adapter layer for Android cross-network WebRTC.
 *
 * Purpose:
 * - keep UI / feature modules independent from the concrete manager implementation
 * - expose the same high-level concepts used by macOS / iOS / Ubuntu:
 *   state, signaling status, DataChannel config status, send/receive
 */
interface CrossNetworkWebRtcTransportAdapter {
    val state: StateFlow<SkyBridgeWebRtcConnectionManager.State>
    val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus>
    val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus>

    var onData: ((ByteArray) -> Unit)?

    fun hasSessionKeys(): Boolean
    fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray?
    fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean
    fun setLocalDeviceId(id: String)
    fun setPqcEnabled(enabled: Boolean)
    fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?)
    suspend fun generateConnectionCode(): String
    fun startOfferer(code: String)
    fun startAnswerer(code: String)
    fun send(bytes: ByteArray): Boolean
    fun disconnect()
    fun release()
}

class AndroidCrossNetworkWebRtcTransportAdapter(
    private val manager: SkyBridgeWebRtcConnectionManager
) : CrossNetworkWebRtcTransportAdapter {
    override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> = manager.state
    override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> = manager.signalingStatus
    override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> = manager.dataChannelConfigStatus

    override var onData: ((ByteArray) -> Unit)?
        get() = manager.onData
        set(value) {
            manager.onData = value
        }

    override fun hasSessionKeys(): Boolean = manager.hasSessionKeys()

    override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? =
        manager.computeOutboundHmacSha256(preimage)

    override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
        manager.verifyInboundHmacSha256(preimage, mac)

    override fun setLocalDeviceId(id: String) = manager.setLocalDeviceId(id)

    override fun setPqcEnabled(enabled: Boolean) = manager.setPqcEnabled(enabled)

    override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) =
        manager.setHandshakePolicyOverride(policy)

    override suspend fun generateConnectionCode(): String = manager.generateConnectionCode()

    override fun startOfferer(code: String) = manager.startOfferer(code)

    override fun startAnswerer(code: String) = manager.startAnswerer(code)

    override fun send(bytes: ByteArray): Boolean = manager.send(bytes)

    override fun disconnect() = manager.disconnect()

    override fun release() = manager.release()
}
