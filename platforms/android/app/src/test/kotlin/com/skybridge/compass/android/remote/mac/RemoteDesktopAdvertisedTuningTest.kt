package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.android.data.RemoteDesktopQualityPreset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [RemoteDesktopAdvertisedTuning] (Task 13.3, Requirement 6.2).
 *
 * Covers: advertised values stay within the defined enums; no "adaptive"/"none" leaks;
 * jitterBufferFrames is present and in {1,2,3}; values are consistent with the preset table when the
 * viewer implements the behavior; and (honesty) the advertised values equal what the current viewer
 * actually implements (the conservative fallback).
 */
class RemoteDesktopAdvertisedTuningTest {

    private val allPresets = RemoteDesktopQualityPreset.entries

    @Test
    fun advertisedValues_alwaysWithinDefinedEnums_forCurrentViewer() {
        for (preset in allPresets) {
            val tuning = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer(preset)
            assertTrue(
                "jitterBufferFrames must be in {1,2,3} for $preset, was ${tuning.jitterBufferFrames}",
                tuning.jitterBufferFrames in
                    RemoteDesktopAdvertisedTuning.MIN_JITTER_BUFFER_FRAMES..
                    RemoteDesktopAdvertisedTuning.MAX_JITTER_BUFFER_FRAMES
            )
            assertTrue(
                "lossRecoveryMode must be a defined enum member for $preset, was ${tuning.lossRecoveryMode}",
                tuning.lossRecoveryMode in RemoteDesktopAdvertisedTuning.VALID_LOSS_RECOVERY_MODES
            )
            assertTrue(
                "refreshStrategy must be a defined enum member for $preset, was ${tuning.refreshStrategy}",
                tuning.refreshStrategy in RemoteDesktopAdvertisedTuning.VALID_REFRESH_STRATEGIES
            )
        }
    }

    @Test
    fun advertisedValues_neverLeakAdaptiveOrNone() {
        for (preset in allPresets) {
            val tuning = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer(preset)
            assertTrue("refreshStrategy must not be 'adaptive'", tuning.refreshStrategy != "adaptive")
            assertTrue("lossRecoveryMode must not be 'none'", tuning.lossRecoveryMode != "none")
        }
    }

    @Test
    fun currentViewer_advertisesConservativeHonestValues_regardlessOfPreset() {
        // The current viewer (SurfaceBackedRemoteVideoDecoder) renders immediately with a single-frame
        // depth, no retransmit and no damage-aware refresh. So no matter which preset is selected, the
        // honest advertised tuning is the conservative floor.
        for (preset in allPresets) {
            val tuning = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer(preset)
            assertEquals("jitterBufferFrames for $preset", 1, tuning.jitterBufferFrames)
            assertEquals(
                "lossRecoveryMode for $preset",
                RemoteDesktopAdvertisedTuning.CONSERVATIVE_LOSS_RECOVERY_MODE,
                tuning.lossRecoveryMode
            )
            assertEquals(
                "refreshStrategy for $preset",
                RemoteDesktopAdvertisedTuning.CONSERVATIVE_REFRESH_STRATEGY,
                tuning.refreshStrategy
            )
        }
    }

    @Test
    fun everyPresetTableValue_isItselfEnumValid() {
        // Guards the preset table (RemoteDesktopQualityPreset) against out-of-enum values: the derive
        // logic only ever forwards a preset value when the viewer implements the behavior, so the
        // source values must be enum-valid too.
        for (preset in allPresets) {
            assertTrue(
                "preset $preset jitterBufferFrames ${preset.jitterBufferFrames} must be in {1,2,3}",
                preset.jitterBufferFrames in
                    RemoteDesktopAdvertisedTuning.MIN_JITTER_BUFFER_FRAMES..
                    RemoteDesktopAdvertisedTuning.MAX_JITTER_BUFFER_FRAMES
            )
            assertTrue(
                "preset $preset lossRecoveryMode ${preset.lossRecoveryMode} must be a defined enum member",
                preset.lossRecoveryMode in RemoteDesktopAdvertisedTuning.VALID_LOSS_RECOVERY_MODES
            )
            assertTrue(
                "preset $preset refreshStrategy ${preset.refreshStrategy} must be a defined enum member",
                preset.refreshStrategy in RemoteDesktopAdvertisedTuning.VALID_REFRESH_STRATEGIES
            )
        }
    }

    @Test
    fun whenViewerImplementsBehavior_advertisedValuesMatchPresetTable() {
        // Honesty in the other direction: IF a future viewer actually implements the buffer depth /
        // retransmit / damage-aware refresh, the advertised values rise to the preset's request
        // (bounded by the implemented depth). This proves derive() is preset-aware, not a constant.
        val fullyCapable = RemoteDesktopAdvertisedTuning.ViewerReceiveCapabilities(
            maxImplementedJitterBufferFrames = RemoteDesktopAdvertisedTuning.MAX_JITTER_BUFFER_FRAMES,
            implementsLossRecovery = true,
            implementsDamageAwareRefresh = true
        )
        for (preset in allPresets) {
            val tuning = RemoteDesktopAdvertisedTuning.derive(preset, fullyCapable)
            assertEquals(
                "jitterBufferFrames should match preset $preset when fully capable",
                preset.jitterBufferFrames,
                tuning.jitterBufferFrames
            )
            assertEquals(
                "lossRecoveryMode should match preset $preset when fully capable",
                preset.lossRecoveryMode,
                tuning.lossRecoveryMode
            )
            assertEquals(
                "refreshStrategy should match preset $preset when fully capable",
                preset.refreshStrategy,
                tuning.refreshStrategy
            )
        }
    }

    @Test
    fun jitterBuffer_isClampedToImplementedDepth() {
        // A viewer that implements a 2-frame buffer must never advertise 3 even for a preset that asks
        // for 3 (FLUID asks for 3), but may advertise the preset's 1 or 2.
        val twoFrameViewer = RemoteDesktopAdvertisedTuning.ViewerReceiveCapabilities(
            maxImplementedJitterBufferFrames = 2,
            implementsLossRecovery = false,
            implementsDamageAwareRefresh = false
        )
        for (preset in allPresets) {
            val tuning = RemoteDesktopAdvertisedTuning.derive(preset, twoFrameViewer)
            assertTrue(
                "jitterBufferFrames must not exceed implemented depth 2 for $preset, was ${tuning.jitterBufferFrames}",
                tuning.jitterBufferFrames <= 2
            )
            assertEquals(
                "jitterBufferFrames should be min(preset, 2) for $preset",
                minOf(preset.jitterBufferFrames, 2),
                tuning.jitterBufferFrames
            )
        }
    }

    @Test
    fun deriveForCurrentViewer_defaultsToAutomaticPreset() {
        val default = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer()
        val explicit = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer(
            RemoteDesktopQualityPreset.AUTOMATIC
        )
        assertEquals(explicit, default)
        assertEquals(1, default.jitterBufferFrames)
        assertEquals("balanced", default.lossRecoveryMode)
        assertEquals("balanced", default.refreshStrategy)
    }
}
