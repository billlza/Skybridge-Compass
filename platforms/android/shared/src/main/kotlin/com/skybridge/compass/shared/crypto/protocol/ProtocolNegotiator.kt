package com.skybridge.compass.shared.crypto.protocol

/**
 * Negotiates protocol versions between peers and manages migration phases.
 * 
 * Protocol versions:
 * - V1 (0x0001): Legacy protocol without PQC support
 * - V2 (0x0002): Current protocol with PQC hybrid encryption support
 * 
 * During migration phases, the system supports dual-write mode where
 * messages are sent in both V1 and V2 formats for backward compatibility.
 */
object ProtocolNegotiator {
    
    /**
     * Current protocol version.
     */
    const val CURRENT_VERSION: UShort = 0x0002u
    
    /**
     * Legacy protocol version (V1).
     */
    const val LEGACY_VERSION: UShort = 0x0001u
    
    /**
     * Minimum supported protocol version.
     */
    const val MIN_SUPPORTED_VERSION: UShort = 0x0001u
    
    /**
     * Maximum supported protocol version.
     */
    const val MAX_SUPPORTED_VERSION: UShort = 0x0002u
    
    /**
     * Configuration for migration phase behavior.
     * Set this to true during migration to enable dual-write mode.
     */
    var migrationPhaseEnabled: Boolean = false
    
    /**
     * Negotiates the protocol version to use between local and remote peers.
     * 
     * Selection algorithm:
     * 1. Find the highest version supported by both peers
     * 2. Return that version, or throw if no common version exists
     * 
     * @param localVersions List of versions supported by local peer (highest first)
     * @param remoteVersions List of versions supported by remote peer
     * @return The negotiated protocol version
     * @throws ProtocolNegotiationException if no common version exists
     */
    fun negotiateVersion(
        localVersions: List<UShort> = getSupportedVersions(),
        remoteVersions: List<UShort>
    ): UShort {
        require(localVersions.isNotEmpty()) { "localVersions cannot be empty" }
        require(remoteVersions.isNotEmpty()) { "remoteVersions cannot be empty" }
        
        val remoteSet = remoteVersions.toSet()
        
        // Find highest common version (local list is ordered highest first)
        return localVersions.firstOrNull { it in remoteSet }
            ?: throw ProtocolNegotiationException(
                localVersions = localVersions,
                remoteVersions = remoteVersions,
                message = "No common protocol version found"
            )
    }
    
    /**
     * Returns the list of protocol versions supported by this implementation.
     * Ordered from highest (preferred) to lowest.
     * 
     * @return List of supported protocol versions
     */
    fun getSupportedVersions(): List<UShort> {
        return listOf(CURRENT_VERSION, LEGACY_VERSION)
    }
    
    /**
     * Checks if dual-write mode should be used during migration.
     * 
     * When enabled, messages are sent in both V1 and V2 formats to ensure
     * backward compatibility with peers that haven't upgraded yet.
     * 
     * @return true if dual-write mode is enabled
     */
    fun shouldDualWrite(): Boolean {
        return migrationPhaseEnabled
    }
    
    /**
     * Checks if this implementation can read V1 protocol messages.
     * 
     * This is always true to maintain backward compatibility.
     * 
     * @return true (V1 reading is always supported)
     */
    fun canReadV1(): Boolean {
        return true
    }
    
    /**
     * Checks if a given protocol version is supported.
     * 
     * @param version The protocol version to check
     * @return true if the version is supported
     */
    fun isVersionSupported(version: UShort): Boolean {
        return version in MIN_SUPPORTED_VERSION..MAX_SUPPORTED_VERSION
    }
    
    /**
     * Checks if a given protocol version supports PQC.
     * 
     * @param version The protocol version to check
     * @return true if the version supports PQC
     */
    fun versionSupportsPQC(version: UShort): Boolean {
        return version >= CURRENT_VERSION
    }
    
    /**
     * Returns the magic bytes for a given protocol version.
     * 
     * @param version The protocol version
     * @return Magic bytes for the version's handshake messages
     */
    fun getMagicBytes(version: UShort): ByteArray {
        return when (version) {
            CURRENT_VERSION -> byteArrayOf(0x53, 0x42, 0x56, 0x32) // "SBV2"
            LEGACY_VERSION -> byteArrayOf(0x53, 0x42, 0x56, 0x31)  // "SBV1"
            else -> throw IllegalArgumentException("Unknown protocol version: $version")
        }
    }
    
    /**
     * Detects the protocol version from message magic bytes.
     * 
     * @param data The message data (at least 4 bytes)
     * @return The detected protocol version, or null if unknown
     */
    fun detectVersion(data: ByteArray): UShort? {
        if (data.size < 4) return null
        
        val magic = data.sliceArray(0 until 4)
        
        return when {
            magic.contentEquals(getMagicBytes(CURRENT_VERSION)) -> CURRENT_VERSION
            magic.contentEquals(getMagicBytes(LEGACY_VERSION)) -> LEGACY_VERSION
            else -> null
        }
    }
}

/**
 * Exception thrown when protocol version negotiation fails.
 */
class ProtocolNegotiationException(
    val localVersions: List<UShort>,
    val remoteVersions: List<UShort>,
    message: String = "Protocol negotiation failed"
) : Exception(message)
