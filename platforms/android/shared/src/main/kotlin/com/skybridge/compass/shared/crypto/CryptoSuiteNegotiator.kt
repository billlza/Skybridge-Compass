package com.skybridge.compass.shared.crypto

import com.skybridge.compass.shared.crypto.models.CryptoSuite

/**
 * Negotiates the best common CryptoSuite between local and remote peers.
 * 
 * The negotiation process:
 * 1. Find all suites common to both local and remote lists
 * 2. Select the suite that appears earliest in the local list (highest priority)
 * 3. If no common suite exists, throw CryptoNegotiationException
 * 
 * Priority is determined by the order in the local list - earlier = higher priority.
 * This allows each peer to express their preferences while ensuring interoperability.
 */
object CryptoSuiteNegotiator {
    
    /**
     * Callback interface for telemetry events during negotiation.
     */
    interface TelemetryCallback {
        /**
         * Called when negotiation results in a classic suite despite
         * both peers supporting PQC suites.
         * 
         * @param localPQCSuites PQC suites supported by local peer
         * @param remotePQCSuites PQC suites supported by remote peer
         * @param selectedSuite The classic suite that was selected
         */
        fun onCryptoDegradedToClassic(
            localPQCSuites: List<CryptoSuite>,
            remotePQCSuites: List<CryptoSuite>,
            selectedSuite: CryptoSuite
        )
    }
    
    /**
     * Optional telemetry callback for recording degradation events.
     * Set this to receive notifications when PQC is available but classic is selected.
     */
    var telemetryCallback: TelemetryCallback? = null
    
    /**
     * Negotiates the best common CryptoSuite between local and remote supported suites.
     * 
     * Selection algorithm:
     * 1. Find intersection of local and remote suites
     * 2. Return the suite that appears earliest in localSuites (highest local priority)
     * 3. If intersection is empty, throw CryptoNegotiationException
     * 
     * @param localSuites Suites supported by the local peer, ordered by preference (highest first)
     * @param remoteSuites Suites supported by the remote peer
     * @return The highest priority common suite
     * @throws CryptoNegotiationException if no common suite exists
     */
    fun negotiate(
        localSuites: List<CryptoSuite>,
        remoteSuites: List<CryptoSuite>
    ): CryptoSuite {
        require(localSuites.isNotEmpty()) { "localSuites cannot be empty" }
        require(remoteSuites.isNotEmpty()) { "remoteSuites cannot be empty" }
        
        // Convert remote suites to a set for O(1) lookup
        val remoteSet = remoteSuites.toSet()
        
        // Find the first local suite that is also in remote suites
        // This gives us the highest priority common suite
        val selectedSuite = localSuites.firstOrNull { it in remoteSet }
            ?: throw CryptoNegotiationException(
                localSuites = localSuites,
                remoteSuites = remoteSuites,
                message = "No common crypto suite found between local ${localSuites.map { it.rawValue }} " +
                         "and remote ${remoteSuites.map { it.rawValue }}"
            )
        
        // Check for degradation: both peers support PQC but classic was selected
        checkForDegradation(localSuites, remoteSuites, selectedSuite)
        
        return selectedSuite
    }
    
    /**
     * Checks if negotiation resulted in degradation from PQC to classic.
     * Records telemetry event if degradation occurred.
     */
    private fun checkForDegradation(
        localSuites: List<CryptoSuite>,
        remoteSuites: List<CryptoSuite>,
        selectedSuite: CryptoSuite
    ) {
        // Only check if selected suite is classic (non-PQC)
        if (selectedSuite.isPQC) return
        
        val localPQCSuites = localSuites.filter { it.isPQC }
        val remotePQCSuites = remoteSuites.filter { it.isPQC }
        
        // Degradation occurred if both peers have PQC suites but classic was selected
        if (localPQCSuites.isNotEmpty() && remotePQCSuites.isNotEmpty()) {
            telemetryCallback?.onCryptoDegradedToClassic(
                localPQCSuites = localPQCSuites,
                remotePQCSuites = remotePQCSuites,
                selectedSuite = selectedSuite
            )
        }
    }
    
    /**
     * Finds all common suites between local and remote, ordered by local priority.
     * 
     * @param localSuites Suites supported by the local peer
     * @param remoteSuites Suites supported by the remote peer
     * @return List of common suites in local priority order
     */
    fun findCommonSuites(
        localSuites: List<CryptoSuite>,
        remoteSuites: List<CryptoSuite>
    ): List<CryptoSuite> {
        val remoteSet = remoteSuites.toSet()
        return localSuites.filter { it in remoteSet }
    }
    
    /**
     * Checks if negotiation would succeed without actually performing it.
     * 
     * @param localSuites Suites supported by the local peer
     * @param remoteSuites Suites supported by the remote peer
     * @return true if at least one common suite exists
     */
    fun canNegotiate(
        localSuites: List<CryptoSuite>,
        remoteSuites: List<CryptoSuite>
    ): Boolean {
        if (localSuites.isEmpty() || remoteSuites.isEmpty()) return false
        val remoteSet = remoteSuites.toSet()
        return localSuites.any { it in remoteSet }
    }
}
