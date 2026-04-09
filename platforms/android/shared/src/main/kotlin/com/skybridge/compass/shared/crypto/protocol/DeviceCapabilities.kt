package com.skybridge.compass.shared.crypto.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Device capabilities advertised during handshake.
 * 
 * @property supportsPQC Whether device supports post-quantum cryptography
 * @property supportsScreenMirroring Whether device supports screen mirroring
 * @property supportsFileTransfer Whether device supports file transfer
 * @property supportsRemoteControl Whether device supports remote control
 */
data class DeviceCapabilities(
    val supportsPQC: Boolean = true,
    val supportsScreenMirroring: Boolean = true,
    val supportsFileTransfer: Boolean = true,
    val supportsRemoteControl: Boolean = true
) {
    /**
     * Serializes capabilities to a 4-byte flags field.
     */
    fun serialize(): ByteArray {
        var flags = 0
        if (supportsPQC) flags = flags or FLAG_PQC
        if (supportsScreenMirroring) flags = flags or FLAG_SCREEN_MIRROR
        if (supportsFileTransfer) flags = flags or FLAG_FILE_TRANSFER
        if (supportsRemoteControl) flags = flags or FLAG_REMOTE_CONTROL
        
        return ByteBuffer.allocate(4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(flags)
            .array()
    }
    
    companion object {
        const val FLAG_PQC = 0x0001
        const val FLAG_SCREEN_MIRROR = 0x0002
        const val FLAG_FILE_TRANSFER = 0x0004
        const val FLAG_REMOTE_CONTROL = 0x0008
        
        fun parse(data: ByteArray, offset: Int = 0): DeviceCapabilities {
            require(data.size >= offset + 4) { "Data too short for capabilities" }
            
            val flags = ByteBuffer.wrap(data, offset, 4)
                .order(ByteOrder.LITTLE_ENDIAN)
                .int
            
            return DeviceCapabilities(
                supportsPQC = (flags and FLAG_PQC) != 0,
                supportsScreenMirroring = (flags and FLAG_SCREEN_MIRROR) != 0,
                supportsFileTransfer = (flags and FLAG_FILE_TRANSFER) != 0,
                supportsRemoteControl = (flags and FLAG_REMOTE_CONTROL) != 0
            )
        }
    }
}
