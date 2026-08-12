package com.skybridge.compass.android.webrtc

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.Environment
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoEncoderFactory
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class WebRtcNativeRuntimeSmokeTest {
    @Test
    fun pinnedArtifactCreatesAndDisposesNativePeerConnectionFactory() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .createInitializationOptions(),
        )

        val environment = Environment.builder().setFieldTrials("").build()
        assertNotEquals(0L, environment.ref())
        environment.close()

        val factory = PeerConnectionFactory.builder()
            .setFieldTrials("")
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .setVideoDecoderFactory(SoftwareVideoDecoderFactory())
            .createPeerConnectionFactory()

        try {
            assertNotNull(factory)
        } finally {
            factory.dispose()
        }
    }

    @Test
    fun pinnedArtifactCreatesPeerConnectionsAndExchangesBinaryDataChannelPayload() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .createInitializationOptions(),
        )
        val factory = PeerConnectionFactory.builder()
            .setFieldTrials("")
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .setVideoDecoderFactory(SoftwareVideoDecoderFactory())
            .createPeerConnectionFactory()

        val failure = AtomicReference<String?>()
        val negotiationComplete = CountDownLatch(1)
        val channelsOpen = CountDownLatch(2)
        val messageReceived = CountDownLatch(1)
        val receivedPayload = AtomicReference<ByteArray?>()
        val answererChannel = AtomicReference<DataChannel?>()
        val offererCandidates = CandidateRouter(failure, negotiationComplete, channelsOpen, messageReceived)
        val answererCandidates = CandidateRouter(failure, negotiationComplete, channelsOpen, messageReceived)
        var offerer: PeerConnection? = null
        var answerer: PeerConnection? = null
        var offererChannel: DataChannel? = null

        try {
            offerer = requireNotNull(
                factory.createPeerConnection(
                    PeerConnection.RTCConfiguration(emptyList()),
                    peerObserver(
                        onIceCandidate = offererCandidates::route,
                        onDataChannel = { channel ->
                            recordFailure(
                                failure,
                                negotiationComplete,
                                channelsOpen,
                                messageReceived,
                                "offerer received an unexpected remote DataChannel ${channel.label()}"
                            )
                        }
                    )
                )
            )
            answerer = requireNotNull(
                factory.createPeerConnection(
                    PeerConnection.RTCConfiguration(emptyList()),
                    peerObserver(
                        onIceCandidate = answererCandidates::route,
                        onDataChannel = { channel ->
                            if (channel.label() != "skybridge") {
                                recordFailure(
                                    failure,
                                    negotiationComplete,
                                    channelsOpen,
                                    messageReceived,
                                    "answerer received unexpected DataChannel label ${channel.label()}"
                                )
                                channel.close()
                                channel.dispose()
                                return@peerObserver
                            }
                            if (!answererChannel.compareAndSet(null, channel)) {
                                recordFailure(
                                    failure,
                                    negotiationComplete,
                                    channelsOpen,
                                    messageReceived,
                                    "answerer received a duplicate DataChannel"
                                )
                                channel.close()
                                channel.dispose()
                                return@peerObserver
                            }
                            val observer = dataChannelObserver(
                                channel = channel,
                                channelsOpen = channelsOpen,
                                onMessage = { buffer ->
                                        if (!buffer.binary) {
                                            recordFailure(
                                                failure,
                                                negotiationComplete,
                                                channelsOpen,
                                                messageReceived,
                                                "answerer received a text DataChannel message"
                                            )
                                            return@dataChannelObserver
                                        }
                                        val bytes = ByteArray(buffer.data.remaining())
                                        buffer.data.get(bytes)
                                        receivedPayload.set(bytes)
                                        messageReceived.countDown()
                                }
                            )
                            channel.registerObserver(observer)
                            observer.onStateChange()
                        }
                    )
                )
            )
            offererCandidates.target.set(answerer)
            answererCandidates.target.set(offerer)

            offererChannel = requireNotNull(
                offerer.createDataChannel(
                    "skybridge",
                    DataChannel.Init().apply {
                        ordered = true
                        negotiated = false
                    }
                )
            )
            val offererObserver = dataChannelObserver(
                channel = offererChannel,
                channelsOpen = channelsOpen,
                onMessage = {
                        recordFailure(
                            failure,
                            negotiationComplete,
                            channelsOpen,
                            messageReceived,
                            "offerer received an unexpected response"
                        )
                }
            )
            offererChannel.registerObserver(offererObserver)
            offererObserver.onStateChange()

            negotiate(
                offerer = offerer,
                answerer = answerer,
                offererCandidates = offererCandidates,
                answererCandidates = answererCandidates,
                failure = failure,
                negotiationComplete = negotiationComplete,
                channelsOpen = channelsOpen,
                messageReceived = messageReceived
            )

            assertTrue(
                failure.get() ?: "native WebRTC negotiation timed out",
                negotiationComplete.await(20, TimeUnit.SECONDS)
            )
            assertNull(failure.get(), failure.get())
            assertTrue(
                failure.get() ?: "native DataChannels did not open",
                channelsOpen.await(20, TimeUnit.SECONDS)
            )
            assertNull(failure.get(), failure.get())

            val payload = "skybridge-native-datachannel".toByteArray(Charsets.UTF_8)
            assertTrue(offererChannel.send(DataChannel.Buffer(ByteBuffer.wrap(payload), true)))
            assertTrue(
                failure.get() ?: "native DataChannel payload was not delivered",
                messageReceived.await(10, TimeUnit.SECONDS)
            )
            assertNull(failure.get(), failure.get())
            assertArrayEquals(payload, receivedPayload.get())
            assertEquals("skybridge", answererChannel.get()?.label())
        } finally {
            answererChannel.getAndSet(null)?.let { channel ->
                disposeDataChannel(channel)
            }
            offererChannel?.let { channel ->
                disposeDataChannel(channel)
            }
            answerer?.close()
            answerer?.dispose()
            offerer?.close()
            offerer?.dispose()
            factory.dispose()
        }
    }

    private fun negotiate(
        offerer: PeerConnection,
        answerer: PeerConnection,
        offererCandidates: CandidateRouter,
        answererCandidates: CandidateRouter,
        failure: AtomicReference<String?>,
        negotiationComplete: CountDownLatch,
        channelsOpen: CountDownLatch,
        messageReceived: CountDownLatch
    ) {
        fun fail(stage: String, detail: String) {
            recordFailure(
                failure,
                negotiationComplete,
                channelsOpen,
                messageReceived,
                "$stage failed: $detail"
            )
        }

        offerer.createOffer(
            sdpObserver(
                onCreateSuccess = { offer ->
                    offerer.setLocalDescription(
                        sdpObserver(
                            onSetSuccess = {
                                answerer.setRemoteDescription(
                                    sdpObserver(
                                        onSetSuccess = {
                                            offererCandidates.markRemoteDescriptionReady()
                                            answerer.createAnswer(
                                                sdpObserver(
                                                    onCreateSuccess = { answer ->
                                                        answerer.setLocalDescription(
                                                            sdpObserver(
                                                                onSetSuccess = {
                                                                    offerer.setRemoteDescription(
                                                                        sdpObserver(
                                                                            onSetSuccess = {
                                                                                answererCandidates.markRemoteDescriptionReady()
                                                                                negotiationComplete.countDown()
                                                                            },
                                                                            onFailure = { fail("offerer set remote answer", it) }
                                                                        ),
                                                                        answer
                                                                    )
                                                                },
                                                                onFailure = { fail("answerer set local answer", it) }
                                                            ),
                                                            answer
                                                        )
                                                    },
                                                    onFailure = { fail("answerer create answer", it) }
                                                ),
                                                MediaConstraints()
                                            )
                                        },
                                        onFailure = { fail("answerer set remote offer", it) }
                                    ),
                                    offer
                                )
                            },
                            onFailure = { fail("offerer set local offer", it) }
                        ),
                        offer
                    )
                },
                onFailure = { fail("offerer create offer", it) }
            ),
            MediaConstraints()
        )
    }

    private fun peerObserver(
        onIceCandidate: (IceCandidate) -> Unit,
        onDataChannel: (DataChannel) -> Unit
    ): PeerConnection.Observer = object : PeerConnection.Observer {
        override fun onSignalingChange(newState: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidate(candidate: IceCandidate) = onIceCandidate(candidate)
        override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) = Unit
        override fun onAddStream(stream: MediaStream) = Unit
        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onDataChannel(dataChannel: DataChannel) = onDataChannel(dataChannel)
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(receiver: RtpReceiver, mediaStreams: Array<out MediaStream>) = Unit
        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) = Unit
        override fun onStandardizedIceConnectionChange(newState: PeerConnection.IceConnectionState) = Unit
        override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent) = Unit
    }

    private fun dataChannelObserver(
        channel: DataChannel,
        channelsOpen: CountDownLatch,
        onMessage: (DataChannel.Buffer) -> Unit
    ): DataChannel.Observer = object : DataChannel.Observer {
        private var countedOpen = false

        override fun onBufferedAmountChange(previousAmount: Long) = Unit

        override fun onStateChange() {
            if (!countedOpen && channel.state() == DataChannel.State.OPEN) {
                countedOpen = true
                channelsOpen.countDown()
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) = onMessage(buffer)
    }

    private fun sdpObserver(
        onCreateSuccess: (SessionDescription) -> Unit = {},
        onSetSuccess: () -> Unit = {},
        onFailure: (String) -> Unit
    ): SdpObserver = object : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) = onCreateSuccess(description)
        override fun onSetSuccess() = onSetSuccess()
        override fun onCreateFailure(error: String) = onFailure(error)
        override fun onSetFailure(error: String) = onFailure(error)
    }

    private class CandidateRouter(
        private val failure: AtomicReference<String?>,
        private val negotiationComplete: CountDownLatch,
        private val channelsOpen: CountDownLatch,
        private val messageReceived: CountDownLatch
    ) {
        val target = AtomicReference<PeerConnection?>()
        private val pending = ConcurrentLinkedQueue<IceCandidate>()
        @Volatile private var remoteDescriptionReady = false

        fun route(candidate: IceCandidate) {
            pending += candidate
            if (!remoteDescriptionReady) return
            flushPending()
        }

        fun markRemoteDescriptionReady() {
            remoteDescriptionReady = true
            flushPending()
        }

        private fun flushPending() {
            if (!remoteDescriptionReady) return
            val peer = target.get() ?: return
            while (true) {
                val candidate = pending.poll() ?: return
                if (!peer.addIceCandidate(candidate)) {
                    recordFailure(
                        failure,
                        negotiationComplete,
                        channelsOpen,
                        messageReceived,
                        "native PeerConnection rejected an ICE candidate"
                    )
                    return
                }
            }
        }
    }

    companion object {
        private fun disposeDataChannel(channel: DataChannel) {
            try {
                channel.unregisterObserver()
            } finally {
                try {
                    channel.close()
                } finally {
                    channel.dispose()
                }
            }
        }

        private fun recordFailure(
            failure: AtomicReference<String?>,
            negotiationComplete: CountDownLatch,
            channelsOpen: CountDownLatch,
            messageReceived: CountDownLatch,
            message: String
        ) {
            failure.compareAndSet(null, message)
            negotiationComplete.countDown()
            while (channelsOpen.count > 0) channelsOpen.countDown()
            messageReceived.countDown()
        }
    }
}
