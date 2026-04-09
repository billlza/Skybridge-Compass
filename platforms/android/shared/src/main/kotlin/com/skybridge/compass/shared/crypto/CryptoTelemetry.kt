package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite

/**
 * Telemetry service for cryptographic operations.
 * 
 * Records events related to crypto suite negotiation, key exchange,
 * and security-relevant operations for monitoring and debugging.
 */
object CryptoTelemetry : CryptoSuiteNegotiator.TelemetryCallback {
    
    /**
     * Listener interface for telemetry events.
     */
    interface EventListener {
        fun onEvent(eventName: String, properties: Map<String, Any>)
    }
    
    private val listeners = mutableListOf<EventListener>()
    
    /**
     * Registers a listener for telemetry events.
     */
    fun addListener(listener: EventListener) {
        listeners.add(listener)
    }
    
    /**
     * Removes a previously registered listener.
     */
    fun removeListener(listener: EventListener) {
        listeners.remove(listener)
    }
    
    /**
     * Records a telemetry event with the given name and properties.
     */
    fun recordEvent(eventName: String, properties: Map<String, Any> = emptyMap()) {
        listeners.forEach { it.onEvent(eventName, properties) }
    }
    
    /**
     * Called when negotiation results in a classic suite despite
     * both peers supporting PQC suites.
     * 
     * Records the "crypto_degraded_to_classic" telemetry event.
     */
    override fun onCryptoDegradedToClassic(
        localPQCSuites: List<CryptoSuite>,
        remotePQCSuites: List<CryptoSuite>,
        selectedSuite: CryptoSuite
    ) {
        recordEvent(
            eventName = EVENT_CRYPTO_DEGRADED_TO_CLASSIC,
            properties = mapOf(
                "local_pqc_suites" to localPQCSuites.map { it.rawValue },
                "remote_pqc_suites" to remotePQCSuites.map { it.rawValue },
                "selected_suite" to selectedSuite.rawValue,
                "selected_wire_id" to selectedSuite.wireId.toString()
            )
        )
    }
    
    /**
     * Initializes the telemetry system and registers with CryptoSuiteNegotiator.
     * Call this during application startup.
     */
    fun initialize() {
        CryptoSuiteNegotiator.telemetryCallback = this
    }
    
    /**
     * Event name for crypto degradation from PQC to classic.
     * 
     * This event is recorded when:
     * - Both local and remote peers support at least one PQC suite
     * - But negotiation resulted in a classic (non-PQC) suite being selected
     * 
     * This may indicate a configuration issue or incompatible PQC implementations.
     */
    const val EVENT_CRYPTO_DEGRADED_TO_CLASSIC = "crypto_degraded_to_classic"
    
    /**
     * Event name for successful PQC handshake.
     */
    const val EVENT_PQC_HANDSHAKE_SUCCESS = "pqc_handshake_success"
    
    /**
     * Event name for classic handshake (no PQC).
     */
    const val EVENT_CLASSIC_HANDSHAKE_SUCCESS = "classic_handshake_success"
    
    /**
     * Event name for handshake failure.
     */
    const val EVENT_HANDSHAKE_FAILURE = "handshake_failure"
}
