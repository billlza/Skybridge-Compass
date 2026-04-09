package com.skybridge.compass.screenmirroring.negotiation

import org.junit.Assert.*
import org.junit.Test
import java.util.Random

/**
 * 参数协商属性测试
 * 
 * **Feature: core-features-completion, Property 6: Resolution Negotiation Validity**
 * **Validates: Requirements 3.8**
 */
class ParameterNegotiatorTest {
    
    private val negotiator = ParameterNegotiator()
    
    /**
     * Property 6: Resolution Negotiation Validity
     * 
     * For any two sets of device capabilities, the negotiated resolution 
     * and frame rate should be within the intersection of both devices' 
     * supported ranges.
     */
    @Test
    fun `negotiated resolution is within both devices capabilities`() {
        val testCases = listOf(
            // 两个设备都支持 FHD
            Pair(
                createCapabilities("device1", Resolution.FHD, listOf(Resolution.HD, Resolution.FHD)),
                createCapabilities("device2", Resolution.FHD, listOf(Resolution.HD, Resolution.FHD))
            ),
            // 一个支持 4K，一个只支持 FHD
            Pair(
                createCapabilities("device1", Resolution.UHD, listOf(Resolution.HD, Resolution.FHD, Resolution.UHD)),
                createCapabilities("device2", Resolution.FHD, listOf(Resolution.HD, Resolution.FHD))
            ),
            // 只有 HD 是公共的
            Pair(
                createCapabilities("device1", Resolution.FHD, listOf(Resolution.HD, Resolution.FHD)),
                createCapabilities("device2", Resolution.QHD, listOf(Resolution.HD, Resolution.QHD))
            )
        )
        
        testCases.forEach { (local, remote) ->
            val result = negotiator.negotiate(local, remote)
            
            // 验证分辨率在两个设备的最大分辨率范围内
            assertTrue(
                "Negotiated resolution should not exceed local max",
                result.resolution.pixels <= local.maxResolution.pixels
            )
            assertTrue(
                "Negotiated resolution should not exceed remote max",
                result.resolution.pixels <= remote.maxResolution.pixels
            )
        }
    }
    
    @Test
    fun `negotiated frame rate is within both devices capabilities`() {
        val testCases = listOf(
            Pair(
                createCapabilities("device1", Resolution.FHD, listOf(Resolution.FHD), listOf(30, 60)),
                createCapabilities("device2", Resolution.FHD, listOf(Resolution.FHD), listOf(30, 60))
            ),
            Pair(
                createCapabilities("device1", Resolution.FHD, listOf(Resolution.FHD), listOf(30, 60)),
                createCapabilities("device2", Resolution.FHD, listOf(Resolution.FHD), listOf(15, 30))
            )
        )
        
        testCases.forEach { (local, remote) ->
            val result = negotiator.negotiate(local, remote)
            
            assertTrue(
                "Negotiated frame rate should not exceed local max",
                result.frameRate <= local.maxFrameRate
            )
            assertTrue(
                "Negotiated frame rate should not exceed remote max",
                result.frameRate <= remote.maxFrameRate
            )
        }
    }
    
    @Test
    fun `negotiated codec is supported by both devices`() {
        val testCases = listOf(
            Pair(
                createCapabilities("device1", codecs = listOf("h264", "h265", "jpeg")),
                createCapabilities("device2", codecs = listOf("h264", "jpeg"))
            ),
            Pair(
                createCapabilities("device1", codecs = listOf("h265", "jpeg")),
                createCapabilities("device2", codecs = listOf("h264", "jpeg"))
            )
        )
        
        testCases.forEach { (local, remote) ->
            val result = negotiator.negotiate(local, remote)
            
            assertTrue(
                "Negotiated codec should be supported by local",
                local.supportedCodecs.contains(result.codec)
            )
            assertTrue(
                "Negotiated codec should be supported by remote",
                remote.supportedCodecs.contains(result.codec)
            )
        }
    }
    
    @Test
    fun `negotiated bitrate is within both devices range`() {
        val testCases = listOf(
            Pair(
                createCapabilities("device1", minBitrate = 500_000, maxBitrate = 10_000_000),
                createCapabilities("device2", minBitrate = 1_000_000, maxBitrate = 8_000_000)
            ),
            Pair(
                createCapabilities("device1", minBitrate = 100_000, maxBitrate = 20_000_000),
                createCapabilities("device2", minBitrate = 500_000, maxBitrate = 5_000_000)
            )
        )
        
        testCases.forEach { (local, remote) ->
            val result = negotiator.negotiate(local, remote)
            
            val effectiveMin = maxOf(local.minBitrate, remote.minBitrate)
            val effectiveMax = minOf(local.maxBitrate, remote.maxBitrate)
            
            assertTrue(
                "Negotiated bitrate should be >= effective min",
                result.bitrate >= effectiveMin
            )
            assertTrue(
                "Negotiated bitrate should be <= effective max",
                result.bitrate <= effectiveMax
            )
        }
    }
    
    @Test
    fun `random capabilities negotiation produces valid results`() {
        val random = Random(42)
        val resolutions = listOf(Resolution.HD, Resolution.FHD, Resolution.QHD, Resolution.UHD)
        val frameRates = listOf(15, 24, 30, 60)
        val codecs = listOf("h264", "h265", "vp8", "vp9", "jpeg")
        
        repeat(50) {
            // 生成随机能力
            val localResolutions = resolutions.shuffled(random).take(random.nextInt(3) + 1)
            val remoteResolutions = resolutions.shuffled(random).take(random.nextInt(3) + 1)
            val localFrameRates = frameRates.shuffled(random).take(random.nextInt(3) + 1)
            val remoteFrameRates = frameRates.shuffled(random).take(random.nextInt(3) + 1)
            val localCodecs = (codecs.shuffled(random).take(random.nextInt(3) + 1) + "jpeg").distinct()
            val remoteCodecs = (codecs.shuffled(random).take(random.nextInt(3) + 1) + "jpeg").distinct()
            
            val local = DeviceCapabilities(
                deviceId = "local",
                deviceName = "Local Device",
                platform = "android",
                supportedResolutions = localResolutions,
                maxResolution = localResolutions.maxByOrNull { it.pixels } ?: Resolution.HD,
                nativeResolution = localResolutions.maxByOrNull { it.pixels } ?: Resolution.HD,
                supportedFrameRates = localFrameRates,
                maxFrameRate = localFrameRates.maxOrNull() ?: 30,
                supportedCodecs = localCodecs,
                preferredCodec = localCodecs.first(),
                hasHardwareEncoder = random.nextBoolean(),
                hasHardwareDecoder = true,
                minBitrate = 500_000,
                maxBitrate = 10_000_000,
                recommendedBitrate = 4_000_000
            )
            
            val remote = DeviceCapabilities(
                deviceId = "remote",
                deviceName = "Remote Device",
                platform = "macos",
                supportedResolutions = remoteResolutions,
                maxResolution = remoteResolutions.maxByOrNull { it.pixels } ?: Resolution.HD,
                nativeResolution = remoteResolutions.maxByOrNull { it.pixels } ?: Resolution.HD,
                supportedFrameRates = remoteFrameRates,
                maxFrameRate = remoteFrameRates.maxOrNull() ?: 30,
                supportedCodecs = remoteCodecs,
                preferredCodec = remoteCodecs.first(),
                hasHardwareEncoder = random.nextBoolean(),
                hasHardwareDecoder = true,
                minBitrate = 500_000,
                maxBitrate = 10_000_000,
                recommendedBitrate = 4_000_000
            )
            
            val result = negotiator.negotiate(local, remote)
            
            // 验证结果有效性
            assertNotNull("Result should not be null", result)
            assertTrue("Resolution width should be positive", result.resolution.width > 0)
            assertTrue("Resolution height should be positive", result.resolution.height > 0)
            assertTrue("Frame rate should be positive", result.frameRate > 0)
            assertTrue("Bitrate should be positive", result.bitrate > 0)
            assertFalse("Codec should not be empty", result.codec.isEmpty())
        }
    }
    
    @Test
    fun `negotiation is deterministic`() {
        val local = createCapabilities("local", Resolution.FHD, listOf(Resolution.HD, Resolution.FHD))
        val remote = createCapabilities("remote", Resolution.FHD, listOf(Resolution.HD, Resolution.FHD))
        
        val result1 = negotiator.negotiate(local, remote)
        val result2 = negotiator.negotiate(local, remote)
        
        assertEquals("Resolution should be same", result1.resolution, result2.resolution)
        assertEquals("Frame rate should be same", result1.frameRate, result2.frameRate)
        assertEquals("Codec should be same", result1.codec, result2.codec)
        assertEquals("Bitrate should be same", result1.bitrate, result2.bitrate)
    }
    
    // 辅助函数
    
    private fun createCapabilities(
        deviceId: String,
        maxResolution: Resolution = Resolution.FHD,
        resolutions: List<Resolution> = listOf(Resolution.HD, Resolution.FHD),
        frameRates: List<Int> = listOf(30, 60),
        codecs: List<String> = listOf("h264", "jpeg"),
        minBitrate: Int = 500_000,
        maxBitrate: Int = 10_000_000
    ): DeviceCapabilities {
        return DeviceCapabilities(
            deviceId = deviceId,
            deviceName = "Test Device $deviceId",
            platform = "android",
            supportedResolutions = resolutions,
            maxResolution = maxResolution,
            nativeResolution = maxResolution,
            supportedFrameRates = frameRates,
            maxFrameRate = frameRates.maxOrNull() ?: 30,
            supportedCodecs = codecs,
            preferredCodec = codecs.first(),
            hasHardwareEncoder = true,
            hasHardwareDecoder = true,
            minBitrate = minBitrate,
            maxBitrate = maxBitrate,
            recommendedBitrate = 4_000_000
        )
    }
}
