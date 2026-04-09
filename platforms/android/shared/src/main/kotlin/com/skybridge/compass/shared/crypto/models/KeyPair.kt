package com.skybridge.compass.shared.crypto.models

/**
 * Represents a cryptographic key pair (public + private key).
 * 
 * @property publicKey The public key material
 * @property privateKey The private key material
 */
data class KeyPair(
    val publicKey: KeyMaterial,
    val privateKey: KeyMaterial
) {
    init {
        require(publicKey.suite == privateKey.suite) {
            "Public and private key must use the same suite"
        }
        require(publicKey.usage == privateKey.usage) {
            "Public and private key must have the same usage"
        }
    }
    
    /**
     * The CryptoSuite this key pair belongs to.
     */
    val suite: CryptoSuite
        get() = publicKey.suite
    
    /**
     * The intended usage of this key pair.
     */
    val usage: com.skybridge.compass.shared.crypto.KeyUsage
        get() = publicKey.usage
    
    /**
     * Securely clears both keys from memory.
     * Call this when the key pair is no longer needed.
     */
    fun clear() {
        publicKey.clear()
        privateKey.clear()
    }
    
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is KeyPair) return false
        
        return publicKey == other.publicKey && privateKey == other.privateKey
    }
    
    override fun hashCode(): Int {
        var result = publicKey.hashCode()
        result = 31 * result + privateKey.hashCode()
        return result
    }
}
