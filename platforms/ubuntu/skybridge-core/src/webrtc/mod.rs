//! WebRTC interop types (protocol-level).
//!
//! This module intentionally contains **no actual WebRTC implementation** yet.
//! It provides wire-compatible signaling message types so Linux can mirror
//! macOS/iOS behavior without copying their code.

#![allow(missing_docs)]

mod file_transfer_wire;
mod remote_wire;
mod serde_bytes_flex;
mod signaling;
#[cfg(feature = "webrtc")]
mod signaling_rest;

#[cfg(feature = "webrtc")]
mod cross_network_manager;
#[cfg(feature = "webrtc")]
mod session;
#[cfg(feature = "webrtc")]
mod signaling_ws;
#[cfg(feature = "webrtc")]
mod turn_uri;

pub use file_transfer_wire::{CrossNetworkFileTransferMessage, CrossNetworkFileTransferOp};
pub use remote_wire::{
    KeyboardEventTypeWire, KeyboardEventWire, MouseEventTypeWire, MouseEventWire,
    RemoteMessageTypeWire, RemoteMessageWire, ScreenDataWire,
};
pub use signaling::now_epoch_seconds;
pub use signaling::{WebRtcSignalingEnvelope, WebRtcSignalingPayload, WebRtcSignalingType};
#[cfg(feature = "webrtc")]
pub use signaling_rest::{
    CurrentPathRemoteAuthority, LookupLease, ProtocolIdentityBinding, RedeemSessionLease,
    RegisterCodeLease, RegisterSessionLease, SignalingControlClient, SignalingControlError,
    TurnCredentialResponse, normalize_device_id, validate_current_path_origin,
    websocket_url_matches_origin,
};

#[cfg(feature = "webrtc")]
pub use cross_network_manager::{
    CrossNetworkEvent, WebRtcCrossNetworkHandle, WebRtcCrossNetworkManager, WebRtcStartParams,
    canonical_pqc_rekey_election_device_id, should_initiate_pqc_rekey,
};
#[cfg(feature = "webrtc")]
pub use session::{IceConfig, WebRtcRole, WebRtcSession, WebRtcSessionError};
#[cfg(feature = "webrtc")]
pub use signaling_ws::{WebRtcSignalingClient, WebRtcSignalingClientConfig};
#[cfg(feature = "webrtc")]
pub use turn_uri::{preferred_turn_uri_for_webrtc_rs, preferred_turn_uri_with_override};
