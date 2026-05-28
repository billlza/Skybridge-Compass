use super::super::super::CheckCoverageEntry;
use super::super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "audio_continuity_gate",
        domain: "performance",
        command: "skybridge check performance --require-audio true",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_audio",
                "audio_explicit_rx_samples",
                "final_audio_status_samples",
                "final_audio_rx_played_max",
                "audio_zero_rx_after_playback_samples",
                "audio_zero_datagram_after_playback_samples",
                "zeroRxAfterPlayback",
                "audio_jitter_evicted",
                "audio_playback_continuity",
            ],
        ),
        evidence: "blocks audio jitter eviction, zero-rx-after-playback, zero-datagram-after-playback, stalls, drops, underflow, missing playback counters, and missing final-window audio progress through doctor checks".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "fallback_detection_gate",
        domain: "correctness",
        command: "skybridge check performance",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_no_fallback",
                "p2p_remote_fallback_parser_flags_real_fallback_lines",
                "attemptedFallback=sampleBufferDisplayLayer",
                "fallbackResult=activated",
                "strict_media_failure",
            ],
        ),
        evidence: "blocks stale fallback and strict media failure checks instead of reporting success on fallback".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "backpressure_bottleneck_gate",
        domain: "performance",
        command: "skybridge check performance",
        covered: source_has_all(
            source,
            &[
                "backpressure",
                "probable_fault_stage",
                "check_p2p_remote_mac_tx",
                "P2P_REMOTE_STRICT_MAC_QUEUED_FRAME_LIMIT",
                "queuedMax",
            ],
        ),
        evidence: "surfaces backpressure and probable fault stage from media telemetry".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_metal_realtime_queue_gate",
        domain: "performance",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "P2P_REMOTE_STRICT_METAL_QUEUE_DEPTH_MAX",
                "P2P_REMOTE_STRICT_METAL_REPLACEMENT_RATIO_MAX",
                "P2P_REMOTE_STRICT_METAL_REPLACEMENT_REASON",
                "queueCapacityMax",
                "replacementStructured",
                "maxAllowedQueueDepth",
                "final_metal_coalesced_total",
                "inputFPSGate",
                "final_metal_display_fps_min",
                "p2p_remote_metal_render_queue_rejects_drop_depth_and_fallback_rendering",
            ],
        ),
        evidence: "requires Metal render telemetry to stay inside the 3-frame realtime queue, with zero final-window realtime replacement and no drawable skips, hard drops, or fallback rendering".to_owned(),
    });
}
