package com.skybridge.compass.discovery.data.services

import com.skybridge.compass.discovery.domain.entities.*
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe
import io.kotest.matchers.collections.shouldContainExactlyInAnyOrder
import io.kotest.property.Arb
import io.kotest.property.arbitrary.*
import io.kotest.property.checkAll

/**
 * DeviceListService 属性测试
 */
class DeviceListServiceTest : FunSpec({
    
    val service = DeviceListServiceImpl()
    
    // 生成随机 DiscoveredDevice
    val deviceArb = arbitrary {
        DiscoveredDevice(
            id = Arb.string(8..16, Codepoint.alphanumeric()).bind(),
            name = Arb.string(4..20).bind(),
            type = Arb.enum<DeviceType>().bind(),
            capabilities = Arb.set(Arb.enum<DeviceCapability>(), 0..5).bind(),
            connectionInfo = ConnectionInfo(
                protocol = Arb.enum<DiscoveryProtocol>().bind(),
                address = "${Arb.int(1..255).bind()}.${Arb.int(0..255).bind()}.${Arb.int(0..255).bind()}.${Arb.int(1..255).bind()}",
                port = Arb.int(1024..65535).bind()
            ),
            signalStrength = Arb.int(-100..0).bind(),
            lastSeen = Arb.long(0L..System.currentTimeMillis()).bind(),
            isConnected = Arb.boolean().bind(),
            batteryLevel = Arb.int(0..100).orNull().bind(),
            osVersion = Arb.string(3..10).orNull().bind()
        )
    }
    
    val deviceListArb = Arb.list(deviceArb, 0..20)
    
    test("Property 7: Device List Serialization Round-Trip") {
        checkAll(100, deviceListArb) { devices ->
            // 导出
            val json = service.exportDevices(devices)
            
            // 导入
            val result = service.importDevices(json)
            
            // 验证成功
            result.isSuccess shouldBe true
            
            // 验证内容一致
            val imported = result.getOrThrow()
            imported shouldBe devices
        }
    }
    
    test("Property 8: Device List Merge Idempotence") {
        checkAll(100, deviceListArb) { devices ->
            // 合并自身
            val merged = service.mergeDevices(devices, devices)
            
            // 验证幂等性：合并后设备数量不变
            merged.size shouldBe devices.distinctBy { it.id }.size
            
            // 验证所有原始设备 ID 都存在
            val originalIds = devices.map { it.id }.toSet()
            val mergedIds = merged.map { it.id }.toSet()
            mergedIds shouldBe originalIds
        }
    }
    
    test("Merge prefers newer devices by lastSeen") {
        val oldDevice = DiscoveredDevice(
            id = "device-1",
            name = "Old Name",
            type = DeviceType.ANDROID,
            capabilities = emptySet(),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BONJOUR,
                address = "192.168.1.1",
                port = 8080
            ),
            signalStrength = -50,
            lastSeen = 1000L
        )
        
        val newDevice = oldDevice.copy(
            name = "New Name",
            lastSeen = 2000L
        )
        
        val merged = service.mergeDevices(listOf(oldDevice), listOf(newDevice))
        
        merged.size shouldBe 1
        merged[0].name shouldBe "New Name"
        merged[0].lastSeen shouldBe 2000L
    }
    
    test("Merge adds new devices") {
        val device1 = DiscoveredDevice(
            id = "device-1",
            name = "Device 1",
            type = DeviceType.ANDROID,
            capabilities = emptySet(),
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BONJOUR,
                address = "192.168.1.1",
                port = 8080
            ),
            signalStrength = -50,
            lastSeen = 1000L
        )
        
        val device2 = device1.copy(id = "device-2", name = "Device 2")
        
        val merged = service.mergeDevices(listOf(device1), listOf(device2))
        
        merged.size shouldBe 2
        merged.map { it.id } shouldContainExactlyInAnyOrder listOf("device-1", "device-2")
    }
    
    test("Import fails with invalid JSON") {
        val result = service.importDevices("not valid json")
        result.isFailure shouldBe true
        result.exceptionOrNull() shouldBe io.kotest.matchers.types.beInstanceOf<InvalidFormatException>()
    }
})
