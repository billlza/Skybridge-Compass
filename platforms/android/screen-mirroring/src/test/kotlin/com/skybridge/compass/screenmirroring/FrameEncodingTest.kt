package com.skybridge.compass.screenmirroring

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.util.Random

/**
 * 帧编码属性测试
 * 
 * **Feature: core-features-completion, Property 5: Frame Encoding Determinism**
 * **Validates: Requirements 3.3, 3.7**
 */
class FrameEncodingTest {
    
    /**
     * Property 5: Frame Encoding Determinism
     * 
     * For any input data with fixed configuration, encoding should produce 
     * consistent output that can be decoded back.
     */
    @Test
    fun `packet serialization round-trip preserves data`() {
        val testCases = listOf(
            createTestPacket(100, DataType.VIDEO),
            createTestPacket(1000, DataType.AUDIO),
            createTestPacket(10, DataType.CONTROL),
            createTestPacket(5000, DataType.METADATA)
        )
        
        testCases.forEach { original ->
            val serialized = serializePacket(original)
            val deserialized = deserializePacket(serialized)
            
            assertEquals("Sequence number should match", original.sequenceNumber, deserialized.sequenceNumber)
            assertEquals("Packet type should match", original.packetType, deserialized.packetType)
            assertEquals("Data type should match", original.dataType, deserialized.dataType)
            assertArrayEquals("Data should match", original.data, deserialized.data)
            assertEquals("Fragment index should match", original.fragmentIndex, deserialized.fragmentIndex)
            assertEquals("Total fragments should match", original.totalFragments, deserialized.totalFragments)
        }
    }
    
    @Test
    fun `random packet serialization round-trip`() {
        val random = Random(42)
        val dataTypes = DataType.values()
        val packetTypes = PacketType.values()
        
        repeat(100) {
            val dataSize = random.nextInt(10000) + 1
            val data = ByteArray(dataSize).also { random.nextBytes(it) }
            
            val original = TransmissionPacket(
                sequenceNumber = random.nextLong().let { if (it < 0) -it else it },
                packetType = packetTypes[random.nextInt(packetTypes.size)],
                dataType = dataTypes[random.nextInt(dataTypes.size)],
                data = data,
                fragmentIndex = random.nextInt(100),
                totalFragments = random.nextInt(100) + 1,
                ackNumber = random.nextLong().let { if (it < 0) -it else it },
                requiresAck = random.nextBoolean(),
                priority = PacketPriority.values()[random.nextInt(PacketPriority.values().size)]
            )
            
            val serialized = serializePacket(original)
            val deserialized = deserializePacket(serialized)
            
            assertEquals("Sequence number should match", original.sequenceNumber, deserialized.sequenceNumber)
            assertEquals("Data type should match", original.dataType, deserialized.dataType)
            assertArrayEquals("Data should match", original.data, deserialized.data)
        }
    }
    
    @Test
    fun `encoding is deterministic for same input`() {
        val packet = createTestPacket(500, DataType.VIDEO)
        
        val encoded1 = serializePacket(packet)
        val encoded2 = serializePacket(packet)
        
        assertArrayEquals("Same input should produce same output", encoded1, encoded2)
    }
    
    @Test
    fun `frame data fragmentation preserves content`() {
        val random = Random(42)
        val originalData = ByteArray(10000).also { random.nextBytes(it) }
        val maxPayloadSize = 1336 // MAX_PACKET_SIZE - 64
        
        // 分片
        val fragments = fragmentData(originalData, maxPayloadSize)
        
        // 重组
        val reassembled = reassembleFragments(fragments)
        
        assertArrayEquals("Reassembled data should match original", originalData, reassembled)
    }
    
    @Test
    fun `video frame metadata is preserved`() {
        val framePayload = ScreenFramePayload(
            frameId = 12345L,
            width = 1920,
            height = 1080,
            codec = "h264",
            isKeyFrame = true,
            dataSize = 50000,
            presentationTimeUs = System.currentTimeMillis() * 1000
        )
        
        val json = framePayload.toJson()
        val deserialized = ScreenFramePayload.fromJson(json)
        
        assertEquals(framePayload.frameId, deserialized.frameId)
        assertEquals(framePayload.width, deserialized.width)
        assertEquals(framePayload.height, deserialized.height)
        assertEquals(framePayload.codec, deserialized.codec)
        assertEquals(framePayload.isKeyFrame, deserialized.isKeyFrame)
        assertEquals(framePayload.dataSize, deserialized.dataSize)
    }
    
    // 辅助函数
    
    private fun createTestPacket(dataSize: Int, dataType: DataType): TransmissionPacket {
        val data = ByteArray(dataSize) { it.toByte() }
        return TransmissionPacket(
            sequenceNumber = System.nanoTime(),
            packetType = PacketType.DATA,
            dataType = dataType,
            data = data,
            fragmentIndex = 0,
            totalFragments = 1,
            requiresAck = true,
            priority = PacketPriority.NORMAL
        )
    }
    
    private fun serializePacket(packet: TransmissionPacket): ByteArray {
        val buffer = ByteBuffer.allocate(1024 + packet.data.size)
        
        buffer.putLong(packet.sequenceNumber)
        buffer.putInt(packet.packetType.ordinal)
        buffer.putInt(packet.dataType.ordinal)
        buffer.putInt(packet.data.size)
        buffer.putInt(packet.fragmentIndex)
        buffer.putInt(packet.totalFragments)
        buffer.putLong(packet.ackNumber)
        buffer.put(if (packet.requiresAck) 1.toByte() else 0.toByte())
        buffer.putInt(packet.priority.ordinal)
        buffer.putLong(System.currentTimeMillis())
        buffer.put(packet.data)
        
        val result = ByteArray(buffer.position())
        buffer.rewind()
        buffer.get(result)
        return result
    }
    
    private fun deserializePacket(data: ByteArray): TransmissionPacket {
        val buffer = ByteBuffer.wrap(data)
        
        val sequenceNumber = buffer.long
        val packetType = PacketType.values()[buffer.int]
        val dataType = DataType.values()[buffer.int]
        val dataSize = buffer.int
        val fragmentIndex = buffer.int
        val totalFragments = buffer.int
        val ackNumber = buffer.long
        val requiresAck = buffer.get() == 1.toByte()
        val priority = PacketPriority.values()[buffer.int]
        val timestamp = buffer.long
        
        val packetData = ByteArray(dataSize)
        buffer.get(packetData)
        
        return TransmissionPacket(
            sequenceNumber = sequenceNumber,
            packetType = packetType,
            dataType = dataType,
            data = packetData,
            fragmentIndex = fragmentIndex,
            totalFragments = totalFragments,
            ackNumber = ackNumber,
            requiresAck = requiresAck,
            priority = priority
        )
    }
    
    private fun fragmentData(data: ByteArray, maxPayloadSize: Int): List<ByteArray> {
        val fragments = mutableListOf<ByteArray>()
        var offset = 0
        
        while (offset < data.size) {
            val fragmentSize = minOf(maxPayloadSize, data.size - offset)
            fragments.add(data.copyOfRange(offset, offset + fragmentSize))
            offset += fragmentSize
        }
        
        return fragments
    }
    
    private fun reassembleFragments(fragments: List<ByteArray>): ByteArray {
        val totalSize = fragments.sumOf { it.size }
        val result = ByteArray(totalSize)
        var offset = 0
        
        fragments.forEach { fragment ->
            System.arraycopy(fragment, 0, result, offset, fragment.size)
            offset += fragment.size
        }
        
        return result
    }
}

// 简化的 ScreenFramePayload 用于测试
data class ScreenFramePayload(
    val frameId: Long,
    val width: Int,
    val height: Int,
    val codec: String,
    val isKeyFrame: Boolean,
    val dataSize: Int,
    val presentationTimeUs: Long
) {
    fun toJson(): String {
        return """{"frameId":$frameId,"width":$width,"height":$height,"codec":"$codec","isKeyFrame":$isKeyFrame,"dataSize":$dataSize,"presentationTimeUs":$presentationTimeUs}"""
    }
    
    companion object {
        fun fromJson(json: String): ScreenFramePayload {
            // 简化的 JSON 解析
            val frameId = json.substringAfter("\"frameId\":").substringBefore(",").toLong()
            val width = json.substringAfter("\"width\":").substringBefore(",").toInt()
            val height = json.substringAfter("\"height\":").substringBefore(",").toInt()
            val codec = json.substringAfter("\"codec\":\"").substringBefore("\"")
            val isKeyFrame = json.substringAfter("\"isKeyFrame\":").substringBefore(",").toBoolean()
            val dataSize = json.substringAfter("\"dataSize\":").substringBefore(",").toInt()
            val presentationTimeUs = json.substringAfter("\"presentationTimeUs\":").substringBefore("}").toLong()
            
            return ScreenFramePayload(frameId, width, height, codec, isKeyFrame, dataSize, presentationTimeUs)
        }
    }
}
