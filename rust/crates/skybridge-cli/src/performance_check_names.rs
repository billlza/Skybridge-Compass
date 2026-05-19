pub(crate) fn required_p2p_remote_performance_check_names() -> &'static [&'static str] {
    &[
        "p2p_remote_sources",
        "p2p_remote_complete_artifact",
        "p2p_remote_no_hidden_failure",
        "p2p_remote_lan_route",
        "p2p_remote_xwing",
        "p2p_remote_protocol_identity_binding",
        "p2p_remote_signed_kem_refresh",
        "p2p_remote_hevc_main_path",
        "p2p_remote_resolution",
        "p2p_remote_ios_window_fps",
        "p2p_remote_mac_tx_backpressure",
        "p2p_remote_mac_final_window_fps",
        "p2p_remote_timing_correlation",
        "p2p_remote_ios_raw_latency",
        "p2p_remote_metal_render_queue",
        "p2p_remote_decode_queue",
        "p2p_remote_audio_continuity",
        "p2p_remote_no_fallback",
    ]
}

pub(crate) fn required_file_transfer_performance_check_names() -> &'static [&'static str] {
    &[
        "file_transfer_sources",
        "file_transfer_no_hidden_failure",
        "file_transfer_xwing",
        "file_transfer_protocol_identity_binding",
        "file_transfer_signed_kem_refresh",
        "file_transfer_skr_direct_route",
        "file_transfer_bidirectional",
        "file_transfer_success",
        "file_transfer_route_evidence",
    ]
}

pub(crate) fn required_webrtc_performance_check_names() -> &'static [&'static str] {
    &[
        "video_fps",
        "native_video_health",
        "native_video_rtc_stats",
        "sck_vt_encode_latency",
        "native_video_receiver",
        "visible_native_render",
        "visible_render_fps",
        "audio_activity_continuity",
        "audio_playback_continuity",
        "strict_media_failure",
        "stale_fallback",
        "backpressure",
        "probable_fault_stage",
    ]
}
