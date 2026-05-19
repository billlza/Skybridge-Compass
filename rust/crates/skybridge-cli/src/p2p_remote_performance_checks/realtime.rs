mod common;
mod final_window;
mod ios_raw_latency;
mod mac_tx;
mod metal_render_queue;
mod receiver_continuity;
mod timing_correlation;

pub(crate) use final_window::{
    check_p2p_remote_ios_window_fps, check_p2p_remote_mac_final_window_fps,
};
pub(crate) use ios_raw_latency::check_p2p_remote_ios_raw_latency;
pub(crate) use mac_tx::check_p2p_remote_mac_tx;
pub(crate) use metal_render_queue::check_p2p_remote_metal_render_queue;
pub(crate) use receiver_continuity::{check_p2p_remote_audio, check_p2p_remote_decode_queue};
pub(crate) use timing_correlation::check_p2p_remote_timing_correlation;
