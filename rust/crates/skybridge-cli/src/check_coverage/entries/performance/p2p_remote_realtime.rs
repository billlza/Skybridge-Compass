use super::super::super::CheckCoverageEntry;
use super::super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_sender_cadence_gate",
        domain: "performance",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "max_frames_per_drain_limit_max",
                "mac_final_window_max_frames_per_drain_limit_max",
                "P2P_REMOTE_STRICT_MAX_FRAMES_PER_DRAIN",
                "P2P_REMOTE_STRICT_SCK_CADENCE_CATCH_UP_LIMIT",
                "P2P_REMOTE_STRICT_HEVC_MAX_FRAME_DELAY_COUNT",
                "sck_max_frame_delay_count_max",
                "missedCadenceSlotsMax",
                "mac_final_window_missed_cadence_slots_max",
                "sckCadenceBatchMax",
            ],
        ),
        evidence: "requires bounded 2-frame Mac SCK display cadence and bounded 3-frame SBC2 sender cadence with zero stale replay or missed slots".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_final_window_fps_gate",
        domain: "performance",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact> --min-fps 59 --min-pass-window-seconds 10",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_mac_final_window_fps",
                "P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS",
                "pass-window-start",
                "update_p2p_remote_final_window_ios_evidence",
                "final_ios_window_fps",
                "mac_final_window_min_sent_fps",
                "p2p_remote_performance_rejects_short_final_pass_window",
                "p2p_remote_mac_final_window_rejects_low_min_sent_fps_inside_final_window",
            ],
        ),
        evidence: "requires iOS display/rx plus Mac encoded/sent FPS and bounded SCK source freshness inside a sustained final pass window, preventing short-window, stale-source, or late-sample fake passes".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_ios_raw_latency_gate",
        domain: "performance",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_ios_raw_latency",
                "P2P_REMOTE_STRICT_RAW_RECEIVE_GAP_FRAME_BUDGET",
                "P2P_REMOTE_STRICT_IOS_COMPLETE_FRAMES_PER_DRAIN_LIMIT",
                "P2P_REMOTE_STRICT_IOS_PARSER_DRAIN_BUDGET_MS",
                "P2P_REMOTE_STRICT_IOS_PARSER_MODE",
                "P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE",
                "P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE",
                "parserStrictSamples",
                "expectedParser=",
                "secure-off-main-actor",
                "screenDeliveryAttempted",
                "screenDeliveryBackpressure",
                "screenDeliveryQueueDepthMax",
                "screenDeliveryDelayMaxMs",
                "P2P_REMOTE_STRICT_IOS_DECODE_FEED_MODE",
                "decodeFeed",
                "decodeAttempted",
                "decodeAccepted",
                "decodeDropped",
                "decodePendingMax",
                "decodeInFlightMax",
                "decodeWaitingSyncSamples",
                "decodeResets",
                "P2P_REMOTE_STRICT_IOS_SCREEN_WIRE_FORMAT",
                "screenWireStrictSamples",
                "sbc2StrictSamples",
                "sbc2FrameSamples",
                "sbc2ChunkSamples",
                "sbc2Frames",
                "sbc2Chunks",
                "completeFramesPerDrainMax",
                "maxMainHopMs",
                "parserDrainMaxMs",
                "parserBudgetMsMax",
                "p2p_remote_raw_latency_rejects_batched_receive_drains",
            ],
        ),
        evidence: "requires raw NWConnection receive gaps, off-MainActor secure parsing, bounded complete-frame and 6ms parser drains, per-sample SBC2 chunked screen wire evidence, exact attempted-to-delivered screen feed and ordered VideoToolbox decode-feed counts, zero decode drop/reset, bounded delivery delay/depth, and strict decoded-to-Metal 60Hz delivery to stay inside the 2K60 receive budget while retaining retry backpressure as diagnostic detail".to_owned(),
    });
}
