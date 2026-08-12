package com.skybridge.compass.core.p2p

import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.Dispatchers
import java.net.InetSocketAddress
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.nio.channels.ClosedByInterruptException
import java.io.Closeable

/** A Bonjour endpoint whose host has already been resolved to a numeric address. */
class ResolvedBootstrapControlEndpoint private constructor(
    val hostAddress: String,
    val port: Int
) {
    companion object {
        fun fromResolvedBonjour(hostAddress: String, port: Int): ResolvedBootstrapControlEndpoint {
            require(port in 1..65_535) { "resolved Bonjour port is invalid" }
            val normalizedHost = hostAddress.trim()
            require(normalizedHost.isNotEmpty()) { "resolved Bonjour host address is required" }
            require(normalizedHost.none { it.code < 0x20 || it.code == 0x7f }) {
                "resolved Bonjour host address is invalid"
            }
            val address = BootstrapControlNumericAddress.parse(normalizedHost)
            require(!address.isAnyLocalAddress) { "resolved Bonjour host cannot be an any-local address" }
            require(!address.isLoopbackAddress) { "resolved Bonjour host cannot be a loopback address" }
            require(!address.isMulticastAddress) { "resolved Bonjour host cannot be a multicast address" }
            return ResolvedBootstrapControlEndpoint(normalizedHost, port)
        }
    }
}

/**
 * One-request/one-response transport for the unauthenticated bootstrap-control socket.
 *
 * Authentication is deliberately owned by PIB-1/SKR-1. This transport uses a non-blocking channel
 * so connect, the complete bounded write, and both bounded reads share one monotonic deadline.
 */
internal fun interface BootstrapControlExchange {
    suspend fun exchange(host: String, port: Int, body: ByteArray, timeoutMs: Int): ByteArray
}

internal class BootstrapControlTransport(
    private val nanoTime: () -> Long = System::nanoTime,
    private val channelFactory: () -> SocketChannel = SocketChannel::open,
    private val selectorFactory: () -> Selector = Selector::open
) : BootstrapControlExchange {
    class TransportException(message: String, cause: Throwable? = null) : Exception(message, cause)

    override suspend fun exchange(
        host: String,
        port: Int,
        body: ByteArray,
        timeoutMs: Int
    ): ByteArray = runInterruptible(Dispatchers.IO) {
        exchangeInterruptibly(host = host, port = port, body = body, timeoutMs = timeoutMs)
    }

    private fun exchangeInterruptibly(
        host: String,
        port: Int,
        body: ByteArray,
        timeoutMs: Int
    ): ByteArray {
        validateEndpoint(host = host, port = port, timeoutMs = timeoutMs)
        if (body.size !in 1..MAX_BODY_BYTES) {
            throw TransportException("invalid outbound bootstrap-control frame length=${body.size}")
        }

        val deadlineNanos = BootstrapControlDeadline.deadlineNanos(
            startNanos = nanoTime(),
            timeoutMillis = timeoutMs
        )
        var channel: SocketChannel? = null
        var selector: Selector? = null
        var primaryFailure: Throwable? = null
        try {
            val ownedChannel = channelFactory().also { channel = it }
            val ownedSelector = selectorFactory().also { selector = it }
            ownedChannel.configureBlocking(false)
            ownedChannel.socket().tcpNoDelay = true
            val key = ownedChannel.register(ownedSelector, SelectionKey.OP_CONNECT)
            val resolvedAddress = try {
                BootstrapControlNumericAddress.parse(host)
            } catch (e: IllegalArgumentException) {
                throw TransportException(e.message ?: "bootstrap-control host address is invalid", e)
            }
            BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())
            if (!ownedChannel.connect(InetSocketAddress(resolvedAddress, port))) {
                awaitReady(ownedSelector, key, SelectionKey.OP_CONNECT, deadlineNanos)
                if (!ownedChannel.finishConnect()) {
                    throw TransportException("bootstrap-control connect did not complete")
                }
            }
            BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())

            val outbound = ByteBuffer.allocate(LENGTH_PREFIX_BYTES + body.size)
            outbound.putInt(body.size)
            outbound.put(body)
            outbound.flip()
            transferUntilComplete(
                selector = ownedSelector,
                key = key,
                operation = SelectionKey.OP_WRITE,
                deadlineNanos = deadlineNanos,
                isComplete = { !outbound.hasRemaining() },
                transfer = {
                    if (ownedChannel.write(outbound) < 0) {
                        throw TransportException("bootstrap-control connection closed during write")
                    }
                }
            )

            val encodedLength = ByteBuffer.allocate(LENGTH_PREFIX_BYTES)
            readUntilComplete(ownedChannel, ownedSelector, key, encodedLength, deadlineNanos)
            encodedLength.flip()
            val responseLength = encodedLength.int
            if (responseLength !in 1..MAX_BODY_BYTES) {
                throw TransportException("invalid inbound bootstrap-control frame length=$responseLength")
            }
            val response = ByteBuffer.allocate(responseLength)
            readUntilComplete(ownedChannel, ownedSelector, key, response, deadlineNanos)
            BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())
            return response.array()
        } catch (e: TransportException) {
            primaryFailure = e
            throw e
        } catch (e: InterruptedException) {
            primaryFailure = e
            throw e
        } catch (e: ClosedByInterruptException) {
            val interrupted = InterruptedException("bootstrap-control exchange interrupted").also {
                it.initCause(e)
            }
            primaryFailure = interrupted
            throw interrupted
        } catch (e: Exception) {
            if (Thread.currentThread().isInterrupted) {
                val interrupted = InterruptedException("bootstrap-control exchange interrupted").also {
                    it.initCause(e)
                }
                primaryFailure = interrupted
                throw interrupted
            }
            val wrapped = TransportException(
                "bootstrap-control exchange failed (${e.javaClass.simpleName})",
                e
            )
            primaryFailure = wrapped
            throw wrapped
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            val closeFailure = BootstrapControlResourceCloser.close(
                primaryFailure = primaryFailure,
                resources = buildList<Closeable> {
                    channel?.let(::add)
                    selector?.let(::add)
                }
            )
            if (closeFailure != null) {
                throw TransportException(
                    "bootstrap-control resource close failed (${closeFailure.javaClass.simpleName})",
                    closeFailure
                )
            }
        }
    }

    private fun readUntilComplete(
        channel: SocketChannel,
        selector: Selector,
        key: SelectionKey,
        destination: ByteBuffer,
        deadlineNanos: Long
    ) = transferUntilComplete(
        selector = selector,
        key = key,
        operation = SelectionKey.OP_READ,
        deadlineNanos = deadlineNanos,
        isComplete = { !destination.hasRemaining() },
        transfer = {
            if (channel.read(destination) < 0) {
                throw TransportException(
                    "bootstrap-control connection closed before ${destination.capacity()} bytes"
                )
            }
        }
    )

    private inline fun transferUntilComplete(
        selector: Selector,
        key: SelectionKey,
        operation: Int,
        deadlineNanos: Long,
        isComplete: () -> Boolean,
        transfer: () -> Unit
    ) = BootstrapControlTransfer.untilComplete(
        deadlineNanos = deadlineNanos,
        nanoTime = nanoTime,
        isComplete = isComplete,
        transfer = transfer,
        awaitReady = {
            awaitReady(selector, key, operation, deadlineNanos)
        }
    )

    private fun awaitReady(
        selector: Selector,
        key: SelectionKey,
        operation: Int,
        deadlineNanos: Long
    ) {
        while (true) {
            BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())
            key.interestOps(operation)
            val readyCount = selector.select(remainingMillisCeiling(deadlineNanos))
            if (Thread.currentThread().isInterrupted) {
                throw InterruptedException("bootstrap-control exchange interrupted")
            }
            if (readyCount == 0) continue
            val iterator = selector.selectedKeys().iterator()
            var ready = false
            while (iterator.hasNext()) {
                val selected = iterator.next()
                iterator.remove()
                if (selected === key && selected.isValid && selected.readyOps() and operation != 0) {
                    ready = true
                }
            }
            if (ready) return
        }
    }

    private fun remainingMillisCeiling(deadlineNanos: Long): Long {
        val remainingNanos = BootstrapControlDeadline.remainingNanos(deadlineNanos, nanoTime())
        if (remainingNanos <= 0L) {
            throw TransportException("bootstrap-control exchange timed out")
        }
        val wholeMillis = remainingNanos / BootstrapControlDeadline.NANOS_PER_MILLISECOND
        val hasFraction =
            remainingNanos % BootstrapControlDeadline.NANOS_PER_MILLISECOND != 0L
        return (wholeMillis + if (hasFraction) 1L else 0L).coerceAtLeast(1L)
    }

    private fun validateEndpoint(host: String, port: Int, timeoutMs: Int) {
        if (host.isBlank()) throw TransportException("bootstrap-control host is required")
        if (host.any { it.code < 0x20 || it.code == 0x7f }) {
            throw TransportException("bootstrap-control host is invalid")
        }
        if (port !in 1..65_535) throw TransportException("bootstrap-control port is invalid")
        if (timeoutMs !in 1..MAX_TIMEOUT_MS) {
            throw TransportException("bootstrap-control timeout is outside the allowed range")
        }
    }

    companion object {
        internal const val MAX_BODY_BYTES = 1_048_576
        internal const val MAX_TIMEOUT_MS = 315_000
        private const val LENGTH_PREFIX_BYTES = 4
    }
}

internal object BootstrapControlNumericAddress {
    fun parse(rawHost: String): InetAddress {
        val host = rawHost.trim().removeSurrounding("[", "]")
        val ipv4 = host.split('.').takeIf { it.size == 4 }?.map { component ->
            component.toIntOrNull()?.takeIf { it in 0..255 }
        }
        if (ipv4 != null && ipv4.all { it != null }) {
            return InetAddress.getByAddress(ipv4.map { requireNotNull(it).toByte() }.toByteArray())
        }
        if (':' !in host) {
            throw IllegalArgumentException(
                "bootstrap-control host must be a resolved numeric Bonjour address"
            )
        }
        return try {
            InetAddress.getByName(host)
        } catch (e: Exception) {
            throw IllegalArgumentException(
                "bootstrap-control IPv6 address is invalid",
                e
            )
        }
    }
}

internal object BootstrapControlDeadline {
    internal const val NANOS_PER_MILLISECOND = 1_000_000L

    fun deadlineNanos(startNanos: Long, timeoutMillis: Int): Long =
        startNanos + timeoutMillis.toLong() * NANOS_PER_MILLISECOND

    /** Wrap-safe for every configured timeout because the duration is far below 2^63 nanoseconds. */
    fun remainingNanos(deadlineNanos: Long, nowNanos: Long): Long = deadlineNanos - nowNanos

    fun requireRemaining(deadlineNanos: Long, nowNanos: Long) {
        if (remainingNanos(deadlineNanos, nowNanos) <= 0L) {
            throw BootstrapControlTransport.TransportException(
                "bootstrap-control exchange timed out"
            )
        }
    }
}

internal object BootstrapControlTransfer {
    inline fun untilComplete(
        deadlineNanos: Long,
        nanoTime: () -> Long,
        isComplete: () -> Boolean,
        transfer: () -> Unit,
        awaitReady: () -> Unit
    ) {
        while (!isComplete()) {
            BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())
            transfer()
            BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())
            if (!isComplete()) awaitReady()
        }
        BootstrapControlDeadline.requireRemaining(deadlineNanos, nanoTime())
    }
}

internal object BootstrapControlResourceCloser {
    /** Returns the first close failure only when there is no primary failure to preserve. */
    fun close(primaryFailure: Throwable?, resources: List<Closeable>): Throwable? {
        val closeFailures = buildList {
            resources.forEach { resource ->
                try {
                    resource.close()
                } catch (failure: Throwable) {
                    add(failure)
                }
            }
        }
        if (closeFailures.isEmpty()) return null
        if (primaryFailure != null) {
            closeFailures.filterNot { it === primaryFailure }.forEach(primaryFailure::addSuppressed)
            return null
        }
        val first = closeFailures.first()
        closeFailures.drop(1).forEach(first::addSuppressed)
        return first
    }
}
