//! Stable, panic-safe **C ABI** for the SkyBridge portable core.
//!
//! Design rules (all enforced here, surfaced to consumers in the generated
//! `skybridge_ffi.h`):
//!
//! * **Opaque handles.** [`SkyBridgeClient`], [`SkyBridgeIdentity`] and
//!   [`SkyBridgePolicyGate`] are heap-allocated Rust objects behind raw
//!   pointers. Each has an explicit `*_new`/`*_create` and a matching `*_free`.
//! * **No panics across the boundary.** Every entry point wraps its body in
//!   [`std::panic::catch_unwind`]; a caught panic becomes
//!   [`SkyBridgeStatus::INTERNAL_PANIC`] rather than unwinding into the caller.
//! * **Error codes, not exceptions.** Functions return a [`SkyBridgeStatus`]
//!   discriminant; out-params carry results.
//! * **Length-prefixed byte buffers.** Messages cross as [`SkyBridgeBuffer`]
//!   (`ptr` + `len`), never NUL-terminated strings, so they are binary-safe.
//!   The caller owns returned buffers and frees them with
//!   [`skybridge_buffer_free`].
//! * **Callback registration for async events.** Discovery results, handshake
//!   state and downgrade events are delivered to a registered
//!   [`SkyBridgeEventCallback`] together with an opaque `user_data` pointer.

use std::os::raw::{c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use skybridge_agent::{ResolvedNearbyPeer, build_active_scan_snapshot, scan_nearby_peers};
use skybridge_core::{
    CryptoSuite, DowngradeDecision, DowngradePolicy, FallbackReason, NearbyDiscoverySnapshot,
    PolicyGate, RustPqcIdentityMaterial,
};
use std::collections::BTreeMap;

// ===========================================================================
// Status / error codes
// ===========================================================================

/// Result code returned by every C-ABI entry point. `0` is success.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeStatus {
    /// The call succeeded.
    Ok = 0,
    /// A required pointer argument was NULL.
    NullArgument = 1,
    /// An argument was structurally invalid (bad length, bad UTF-8, bad enum).
    InvalidArgument = 2,
    /// The requested operation is not valid in the handle's current state
    /// (e.g. starting discovery that is already running).
    InvalidState = 3,
    /// A downgrade authorization was *denied* (policy / reason / rate-limit).
    /// This is a normal, expected outcome, not an internal failure — inspect the
    /// emitted decision JSON for the specific denial.
    DowngradeDenied = 4,
    /// The crate-owned async runtime could not be created or driven.
    RuntimeError = 5,
    /// An underlying core operation failed (I/O, codec, crypto).
    CoreError = 6,
    /// A Rust panic was caught at the boundary (should never happen; reported
    /// instead of unwinding into the foreign caller).
    InternalPanic = 7,
}

impl SkyBridgeStatus {
    #[inline]
    fn code(self) -> i32 {
        self as i32
    }
}

/// Run `body`, converting any panic into [`SkyBridgeStatus::InternalPanic`] so a
/// panic never unwinds across the FFI boundary.
#[inline]
fn guard<F: FnOnce() -> SkyBridgeStatus>(body: F) -> i32 {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(status) => status.code(),
        Err(_) => SkyBridgeStatus::InternalPanic.code(),
    }
}

// ===========================================================================
// Length-prefixed byte buffer (owned by the caller after return)
// ===========================================================================

/// A heap-allocated, length-prefixed byte buffer handed to the caller.
///
/// `ptr`/`len`/`cap` together describe a `Vec<u8>` that Rust forgot; the caller
/// MUST return it via [`skybridge_buffer_free`] exactly once. A buffer with a
/// NULL `ptr` and zero `len` is the canonical "empty/none" value.
#[repr(C)]
pub struct SkyBridgeBuffer {
    /// Pointer to the first byte, or NULL when empty.
    pub ptr: *mut u8,
    /// Number of valid bytes.
    pub len: usize,
    /// Allocation capacity (needed to reconstruct the `Vec` for freeing).
    pub cap: usize,
}

impl SkyBridgeBuffer {
    fn empty() -> Self {
        Self {
            ptr: ptr::null_mut(),
            len: 0,
            cap: 0,
        }
    }

    fn from_vec(mut v: Vec<u8>) -> Self {
        if v.is_empty() {
            return Self::empty();
        }
        let ptr = v.as_mut_ptr();
        let len = v.len();
        let cap = v.capacity();
        std::mem::forget(v);
        Self { ptr, len, cap }
    }
}

/// Free a [`SkyBridgeBuffer`] previously returned by this library. Safe to call
/// with an empty (NULL `ptr`) buffer. After the call the buffer's fields are
/// reset to the empty state; do not use the pointer again.
///
/// # Safety
/// `buffer` must point to a `SkyBridgeBuffer` this library produced and that has
/// not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_buffer_free(buffer: *mut SkyBridgeBuffer) -> i32 {
    guard(|| {
        if buffer.is_null() {
            return SkyBridgeStatus::Ok; // freeing nothing is a no-op
        }
        let buf = unsafe { &mut *buffer };
        if !buf.ptr.is_null() && buf.cap != 0 {
            // Reconstruct and drop the original Vec<u8>.
            drop(unsafe { Vec::from_raw_parts(buf.ptr, buf.len, buf.cap) });
        }
        buf.ptr = ptr::null_mut();
        buf.len = 0;
        buf.cap = 0;
        SkyBridgeStatus::Ok
    })
}

/// Helper: write a `Vec<u8>` into a caller-provided out-param buffer pointer.
#[inline]
fn write_buffer(out: *mut SkyBridgeBuffer, bytes: Vec<u8>) -> SkyBridgeStatus {
    if out.is_null() {
        return SkyBridgeStatus::NullArgument;
    }
    unsafe { ptr::write(out, SkyBridgeBuffer::from_vec(bytes)) };
    SkyBridgeStatus::Ok
}

/// Read a borrowed byte slice from a (`ptr`, `len`) pair. NULL with len 0 is an
/// empty slice; NULL with len > 0 is an error (returned as `None`).
#[inline]
unsafe fn slice_from_raw<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

// ===========================================================================
// Version
// ===========================================================================

/// ABI/library version string (`env!("CARGO_PKG_VERSION")`), NUL-terminated,
/// static. Do **not** free it.
#[unsafe(no_mangle)]
pub extern "C" fn skybridge_version() -> *const c_char {
    // Static NUL-terminated string; lives for the program's lifetime.
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

// ===========================================================================
// Downgrade policy mapping (wire-stable codes shared with UniFFI)
// ===========================================================================

/// Stable integer encoding of [`skybridge_core::DowngradePolicy`] for the C ABI.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeDowngradePolicy {
    /// Strict PQC, compliance: classic fallback is *never* allowed.
    StrictPqcCompliance = 0,
    /// Strict PQC, bootstrap-assisted: one-time classic control channel only.
    StrictPqcBootstrapAssisted = 1,
    /// Prefer PQC, allow eligible + rate-limited classic business fallback.
    PreferPqc = 2,
    /// Default posture: no mandatory initial PQC attempt; same fallback gating.
    Default = 3,
}

impl SkyBridgeDowngradePolicy {
    fn to_core(self) -> DowngradePolicy {
        match self {
            Self::StrictPqcCompliance => DowngradePolicy::StrictPqcCompliance,
            Self::StrictPqcBootstrapAssisted => DowngradePolicy::StrictPqcBootstrapAssisted,
            Self::PreferPqc => DowngradePolicy::PreferPqc,
            Self::Default => DowngradePolicy::Default,
        }
    }

    fn from_u32(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::StrictPqcCompliance),
            1 => Some(Self::StrictPqcBootstrapAssisted),
            2 => Some(Self::PreferPqc),
            3 => Some(Self::Default),
            _ => None,
        }
    }
}

/// Stable integer encoding of [`skybridge_core::FallbackReason`] for the C ABI.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeFallbackReason {
    /// ALLOWED: no usable PQC provider/suite is available locally.
    PqcProviderUnavailable = 0,
    /// ALLOWED: PQC suite negotiation produced no mutually supported suite.
    SuiteNegotiationFailed = 1,
    /// BLOCKED: network-derived timeout (never downgrade-eligible).
    Timeout = 2,
    /// BLOCKED: peer signature failed to verify.
    SignatureVerificationFailed = 3,
    /// BLOCKED: replay / anti-rollback detection tripped.
    ReplayDetected = 4,
    /// BLOCKED: key confirmation (FINISHED MAC) failed.
    KeyConfirmationFailed = 5,
    /// BLOCKED: peer identity did not match the pinned/enrolled identity.
    IdentityMismatch = 6,
    /// BLOCKED: signed suite list did not match the negotiated suite.
    SuiteSignatureMismatch = 7,
}

impl SkyBridgeFallbackReason {
    fn to_core(self) -> FallbackReason {
        match self {
            Self::PqcProviderUnavailable => FallbackReason::PqcProviderUnavailable,
            Self::SuiteNegotiationFailed => FallbackReason::SuiteNegotiationFailed,
            Self::Timeout => FallbackReason::Timeout,
            Self::SignatureVerificationFailed => FallbackReason::SignatureVerificationFailed,
            Self::ReplayDetected => FallbackReason::ReplayDetected,
            Self::KeyConfirmationFailed => FallbackReason::KeyConfirmationFailed,
            Self::IdentityMismatch => FallbackReason::IdentityMismatch,
            Self::SuiteSignatureMismatch => FallbackReason::SuiteSignatureMismatch,
        }
    }

    fn from_u32(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::PqcProviderUnavailable),
            1 => Some(Self::SuiteNegotiationFailed),
            2 => Some(Self::Timeout),
            3 => Some(Self::SignatureVerificationFailed),
            4 => Some(Self::ReplayDetected),
            5 => Some(Self::KeyConfirmationFailed),
            6 => Some(Self::IdentityMismatch),
            7 => Some(Self::SuiteSignatureMismatch),
            _ => None,
        }
    }
}

// ===========================================================================
// Event callback surface
// ===========================================================================

/// Kind discriminant passed to a [`SkyBridgeEventCallback`].
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeEventKind {
    /// A discovery scan produced a fresh snapshot. `payload` is the
    /// `NearbyDiscoverySnapshot` serialized as JSON (UTF-8).
    DiscoverySnapshot = 0,
    /// Handshake state changed. `payload` is a small JSON object.
    HandshakeState = 1,
    /// A downgrade decision was made. `payload` is the decision serialized as
    /// JSON (the `DowngradeEvent` for an authorized downgrade, or a typed denial).
    DowngradeEvent = 2,
    /// Discovery stopped (either by request or because the scan window ended).
    /// `payload` is empty.
    DiscoveryStopped = 3,
}

/// C function pointer invoked for asynchronous events.
///
/// * `user_data` — the opaque pointer registered alongside the callback.
/// * `kind` — which event this is.
/// * `payload` / `payload_len` — a borrowed, *callback-lifetime* byte view
///   (typically UTF-8 JSON). The pointer is only valid for the duration of the
///   call; copy what you need. May be NULL with `payload_len == 0`.
///
/// The callback may be invoked from a background thread; it must be
/// re-entrancy-safe and must not call back into the same client handle.
pub type SkyBridgeEventCallback = Option<
    unsafe extern "C" fn(
        user_data: *mut c_void,
        kind: SkyBridgeEventKind,
        payload: *const u8,
        payload_len: usize,
    ),
>;

/// A `Send`/`Sync` wrapper so the registered callback + user_data can be moved
/// onto the discovery worker thread. The consumer promises (in the header
/// contract) that the callback and pointer are valid for the client's lifetime
/// and safe to call from another thread.
#[derive(Clone, Copy)]
struct CallbackSink {
    callback: SkyBridgeEventCallback,
    user_data: *mut c_void,
}

// SAFETY: see the documented threading contract on `SkyBridgeEventCallback`.
unsafe impl Send for CallbackSink {}
unsafe impl Sync for CallbackSink {}

impl CallbackSink {
    fn emit(&self, kind: SkyBridgeEventKind, payload: &[u8]) {
        if let Some(cb) = self.callback {
            let (ptr, len) = if payload.is_empty() {
                (ptr::null(), 0)
            } else {
                (payload.as_ptr(), payload.len())
            };
            // The callback is foreign code; isolate any panic it might trigger
            // (it shouldn't, but we never let it unwind through Rust).
            let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
                cb(self.user_data, kind, ptr, len)
            }));
        }
    }
}

// ===========================================================================
// Identity handle
// ===========================================================================

/// Opaque handle wrapping a generated PQC device identity
/// ([`skybridge_core::RustPqcIdentityMaterial`]): ML-DSA-65 signing keypair plus
/// ML-KEM-768 and X-Wing KEM keypairs.
pub struct SkyBridgeIdentity {
    inner: RustPqcIdentityMaterial,
}

/// Generate a fresh PQC device identity. On success writes an owned handle to
/// `*out_identity`; free it with [`skybridge_identity_free`].
///
/// # Safety
/// `out_identity` must be a valid, writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_identity_generate(
    out_identity: *mut *mut SkyBridgeIdentity,
) -> i32 {
    guard(|| {
        if out_identity.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        match RustPqcIdentityMaterial::generate() {
            Ok(material) => {
                let handle = Box::new(SkyBridgeIdentity { inner: material });
                unsafe { ptr::write(out_identity, Box::into_raw(handle)) };
                SkyBridgeStatus::Ok
            }
            Err(_) => SkyBridgeStatus::CoreError,
        }
    })
}

/// Copy the ML-DSA-65 signing public key into `*out_buffer` (caller frees with
/// [`skybridge_buffer_free`]).
///
/// # Safety
/// `identity` must be a live handle; `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_identity_signing_public_key(
    identity: *const SkyBridgeIdentity,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if identity.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let id = unsafe { &*identity };
        write_buffer(out_buffer, id.inner.signing_public_key.clone())
    })
}

/// Copy the ML-KEM-768 KEM public key into `*out_buffer`.
///
/// # Safety
/// `identity` must be a live handle; `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_identity_mlkem768_public_key(
    identity: *const SkyBridgeIdentity,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if identity.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let id = unsafe { &*identity };
        write_buffer(out_buffer, id.inner.mlkem768_public_key.clone())
    })
}

/// Copy the X-Wing hybrid KEM public key into `*out_buffer`.
///
/// # Safety
/// `identity` must be a live handle; `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_identity_xwing_public_key(
    identity: *const SkyBridgeIdentity,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if identity.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let id = unsafe { &*identity };
        write_buffer(out_buffer, id.inner.xwing_public_key.clone())
    })
}

/// Free an identity handle. Safe to call with NULL.
///
/// # Safety
/// `identity` must be a handle produced by this library and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_identity_free(identity: *mut SkyBridgeIdentity) -> i32 {
    guard(|| {
        if !identity.is_null() {
            drop(unsafe { Box::from_raw(identity) });
        }
        SkyBridgeStatus::Ok
    })
}

// ===========================================================================
// Policy-gate handle
// ===========================================================================

/// Opaque handle wrapping a [`skybridge_core::PolicyGate`] — the single
/// authority that authorizes or denies a PQC→Classic downgrade for a peer,
/// applying the reason whitelist, policy posture, and per-peer 300s cooldown.
pub struct SkyBridgePolicyGate {
    inner: PolicyGate,
}

/// Create a policy gate with the given downgrade posture and the canonical
/// 300s per-peer cooldown. On success writes a handle to `*out_gate`.
///
/// # Safety
/// `out_gate` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_policy_gate_new(
    policy: SkyBridgeDowngradePolicy,
    out_gate: *mut *mut SkyBridgePolicyGate,
) -> i32 {
    guard(|| {
        if out_gate.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let gate = Box::new(SkyBridgePolicyGate {
            inner: PolicyGate::new(policy.to_core()),
        });
        unsafe { ptr::write(out_gate, Box::into_raw(gate)) };
        SkyBridgeStatus::Ok
    })
}

/// Variant of [`skybridge_policy_gate_new`] taking the policy as a raw `u32`
/// (the [`SkyBridgeDowngradePolicy`] code) for callers that pass plain integers.
///
/// # Safety
/// `out_gate` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_policy_gate_new_code(
    policy_code: u32,
    out_gate: *mut *mut SkyBridgePolicyGate,
) -> i32 {
    guard(|| {
        if out_gate.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(policy) = SkyBridgeDowngradePolicy::from_u32(policy_code) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let gate = Box::new(SkyBridgePolicyGate {
            inner: PolicyGate::new(policy.to_core()),
        });
        unsafe { ptr::write(out_gate, Box::into_raw(gate)) };
        SkyBridgeStatus::Ok
    })
}

/// Read the configured downgrade policy posture back as a [`SkyBridgeDowngradePolicy`]
/// code written to `*out_policy_code`.
///
/// # Safety
/// `gate` must be live; `out_policy_code` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_policy_gate_policy(
    gate: *const SkyBridgePolicyGate,
    out_policy_code: *mut u32,
) -> i32 {
    guard(|| {
        if gate.is_null() || out_policy_code.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let g = unsafe { &*gate };
        let code = match g.inner.policy() {
            DowngradePolicy::StrictPqcCompliance => 0u32,
            DowngradePolicy::StrictPqcBootstrapAssisted => 1,
            DowngradePolicy::PreferPqc => 2,
            DowngradePolicy::Default => 3,
        };
        unsafe { ptr::write(out_policy_code, code) };
        SkyBridgeStatus::Ok
    })
}

/// Ask the gate to authorize a PQC→Classic downgrade for `peer`.
///
/// * `peer_ptr`/`peer_len` — UTF-8 peer identifier (stable, not a network
///   locator). Must be valid UTF-8.
/// * `from_suite_wire` / `to_suite_wire` — wire ids of the PQC suite attempted
///   and the Classic suite to downgrade to.
/// * `reason` — the failure reason being evaluated.
/// * `transcript_ptr`/`transcript_len` — optional transcript-hash anchor
///   (pass NULL/0 for none).
/// * `out_decision_json` — receives the decision serialized as JSON (the
///   `DowngradeEvent` when authorized, otherwise a `{ "denied": ... }` object).
///   Caller frees with [`skybridge_buffer_free`].
///
/// Returns [`SkyBridgeStatus::OK`] when the downgrade is **authorized**, and
/// [`SkyBridgeStatus::DOWNGRADE_DENIED`] when it is denied (still writing the
/// JSON explaining why). Both are normal outcomes.
///
/// # Safety
/// `gate` must be a live, mutable handle; the byte pointers must satisfy the
/// `(ptr, len)` contract; `out_decision_json` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_policy_gate_authorize_downgrade(
    gate: *mut SkyBridgePolicyGate,
    peer_ptr: *const u8,
    peer_len: usize,
    from_suite_wire: u16,
    to_suite_wire: u16,
    reason: SkyBridgeFallbackReason,
    transcript_ptr: *const u8,
    transcript_len: usize,
    out_decision_json: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if gate.is_null() || out_decision_json.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let g = unsafe { &mut *gate };

        let Some(peer_bytes) = (unsafe { slice_from_raw(peer_ptr, peer_len) }) else {
            return SkyBridgeStatus::NullArgument;
        };
        let Ok(peer) = std::str::from_utf8(peer_bytes) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let transcript = match unsafe { slice_from_raw(transcript_ptr, transcript_len) } {
            Some([]) => None,
            Some(s) => Some(s),
            None => return SkyBridgeStatus::NullArgument,
        };

        let decision = g.inner.authorize_downgrade(
            peer,
            CryptoSuite::from_wire_id(from_suite_wire),
            CryptoSuite::from_wire_id(to_suite_wire),
            reason.to_core(),
            transcript,
        );

        let (status, json) = decision_to_json(&decision);
        let write = write_buffer(out_decision_json, json.into_bytes());
        if write != SkyBridgeStatus::Ok {
            return write;
        }
        status
    })
}

/// Variant of [`skybridge_policy_gate_authorize_downgrade`] taking the reason as
/// a raw `u32` ([`SkyBridgeFallbackReason`] code).
///
/// # Safety
/// Same contract as [`skybridge_policy_gate_authorize_downgrade`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_policy_gate_authorize_downgrade_code(
    gate: *mut SkyBridgePolicyGate,
    peer_ptr: *const u8,
    peer_len: usize,
    from_suite_wire: u16,
    to_suite_wire: u16,
    reason_code: u32,
    transcript_ptr: *const u8,
    transcript_len: usize,
    out_decision_json: *mut SkyBridgeBuffer,
) -> i32 {
    let Some(reason) = SkyBridgeFallbackReason::from_u32(reason_code) else {
        return SkyBridgeStatus::InvalidArgument.code();
    };
    unsafe {
        skybridge_policy_gate_authorize_downgrade(
            gate,
            peer_ptr,
            peer_len,
            from_suite_wire,
            to_suite_wire,
            reason,
            transcript_ptr,
            transcript_len,
            out_decision_json,
        )
    }
}

/// Free a policy-gate handle. Safe to call with NULL.
///
/// # Safety
/// `gate` must be a handle produced by this library and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_policy_gate_free(gate: *mut SkyBridgePolicyGate) -> i32 {
    guard(|| {
        if !gate.is_null() {
            drop(unsafe { Box::from_raw(gate) });
        }
        SkyBridgeStatus::Ok
    })
}

/// Serialize a [`DowngradeDecision`] into `(status, json)`.
fn decision_to_json(decision: &DowngradeDecision) -> (SkyBridgeStatus, String) {
    match decision {
        DowngradeDecision::Allowed(event) => {
            let json = serde_json::to_string(event)
                .unwrap_or_else(|_| "{\"error\":\"serialize\"}".to_owned());
            (SkyBridgeStatus::Ok, json)
        }
        DowngradeDecision::DeniedByPolicy => (
            SkyBridgeStatus::DowngradeDenied,
            "{\"denied\":\"policy\"}".to_owned(),
        ),
        DowngradeDecision::DeniedReasonIneligible(reason) => (
            SkyBridgeStatus::DowngradeDenied,
            format!(
                "{{\"denied\":\"reason_ineligible\",\"reason\":\"{}\"}}",
                reason.diagnostic_code()
            ),
        ),
        DowngradeDecision::DeniedRateLimited { remaining } => (
            SkyBridgeStatus::DowngradeDenied,
            format!(
                "{{\"denied\":\"rate_limited\",\"remaining_seconds\":{}}}",
                remaining.as_secs()
            ),
        ),
    }
}

// ===========================================================================
// Client handle: runtime + discovery
// ===========================================================================

/// Opaque top-level client handle. Owns a crate-private multi-thread Tokio
/// runtime used to drive async core operations (currently the live mDNS
/// discovery browse) and the registered event callback.
pub struct SkyBridgeClient {
    runtime: tokio::runtime::Runtime,
    sink: std::sync::Mutex<Option<CallbackSink>>,
    discovery_running: Arc<AtomicBool>,
}

/// Create a client handle. On success writes a handle to `*out_client`; free it
/// with [`skybridge_client_free`].
///
/// # Safety
/// `out_client` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_client_new(out_client: *mut *mut SkyBridgeClient) -> i32 {
    guard(|| {
        if out_client.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(_) => return SkyBridgeStatus::RuntimeError,
        };
        let client = Box::new(SkyBridgeClient {
            runtime,
            sink: std::sync::Mutex::new(None),
            discovery_running: Arc::new(AtomicBool::new(false)),
        });
        unsafe { ptr::write(out_client, Box::into_raw(client)) };
        SkyBridgeStatus::Ok
    })
}

/// Register (or clear) the event callback for this client.
///
/// Pass a NULL `callback` to clear the previously registered sink. `user_data`
/// is passed back verbatim on every callback invocation. The callback may fire
/// from a background thread (see [`SkyBridgeEventCallback`]).
///
/// # Safety
/// `client` must be live. The `callback` (if non-NULL) and `user_data` must
/// remain valid until they are cleared or the client is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_client_set_event_callback(
    client: *mut SkyBridgeClient,
    callback: SkyBridgeEventCallback,
    user_data: *mut c_void,
) -> i32 {
    guard(|| {
        if client.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let c = unsafe { &*client };
        let mut sink = match c.sink.lock() {
            Ok(guard) => guard,
            Err(_) => return SkyBridgeStatus::InvalidState,
        };
        *sink = callback.map(|cb| CallbackSink {
            callback: Some(cb),
            user_data,
        });
        SkyBridgeStatus::Ok
    })
}

/// Start a live mDNS discovery browse of `_skybridge._tcp` for `duration_ms`.
///
/// Runs on the client's Tokio runtime in the background. When the browse window
/// elapses, the resolved peers are projected into a `NearbyDiscoverySnapshot`
/// and delivered to the registered callback as a
/// [`SkyBridgeEventKind::DiscoverySnapshot`] (JSON payload), followed by a
/// [`SkyBridgeEventKind::DiscoveryStopped`]. Returns
/// [`SkyBridgeStatus::INVALID_STATE`] if a browse is already running.
///
/// # Safety
/// `client` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_client_start_discovery(
    client: *mut SkyBridgeClient,
    duration_ms: u64,
) -> i32 {
    guard(|| {
        if client.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let c = unsafe { &*client };

        // Single in-flight browse at a time.
        if c.discovery_running.swap(true, Ordering::SeqCst) {
            return SkyBridgeStatus::InvalidState;
        }

        let sink = c.sink.lock().ok().and_then(|guard| *guard);
        let running = Arc::clone(&c.discovery_running);
        let duration = Duration::from_millis(duration_ms.max(1));

        c.runtime.spawn(async move {
            let result = scan_nearby_peers(duration).await;
            if let Some(sink) = sink {
                match result {
                    Ok(peers) => {
                        let snapshot = project_snapshot(peers);
                        let json = serde_json::to_vec(&snapshot).unwrap_or_default();
                        sink.emit(SkyBridgeEventKind::DiscoverySnapshot, &json);
                    }
                    Err(_) => {
                        // Surface the failure as an empty snapshot event rather
                        // than dropping it silently.
                        sink.emit(
                            SkyBridgeEventKind::DiscoverySnapshot,
                            b"{\"error\":\"scan_failed\"}",
                        );
                    }
                }
                sink.emit(SkyBridgeEventKind::DiscoveryStopped, &[]);
            }
            running.store(false, Ordering::SeqCst);
        });

        SkyBridgeStatus::Ok
    })
}

/// Signal that no further discovery should be considered active for this client.
///
/// The in-flight browse is bounded by its own window and cannot be hard-killed
/// mid-flight, so this clears the "running" flag (allowing a new browse to be
/// started) rather than aborting the OS-level mDNS socket. Idempotent.
///
/// # Safety
/// `client` must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_client_stop_discovery(client: *mut SkyBridgeClient) -> i32 {
    guard(|| {
        if client.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let c = unsafe { &*client };
        c.discovery_running.store(false, Ordering::SeqCst);
        SkyBridgeStatus::Ok
    })
}

/// Whether a discovery browse is currently in flight. Writes 0/1 to `*out_running`.
///
/// # Safety
/// `client` must be live; `out_running` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_client_discovery_running(
    client: *const SkyBridgeClient,
    out_running: *mut bool,
) -> i32 {
    guard(|| {
        if client.is_null() || out_running.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let c = unsafe { &*client };
        unsafe { ptr::write(out_running, c.discovery_running.load(Ordering::SeqCst)) };
        SkyBridgeStatus::Ok
    })
}

/// Free a client handle (and shut down its runtime). Safe to call with NULL.
///
/// # Safety
/// `client` must be a handle produced by this library and not already freed. Any
/// registered callback must not be used after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_client_free(client: *mut SkyBridgeClient) -> i32 {
    guard(|| {
        if !client.is_null() {
            // Reconstruct the Box; the runtime is dropped (shutdown) here.
            drop(unsafe { Box::from_raw(client) });
        }
        SkyBridgeStatus::Ok
    })
}

/// Project resolved peers into a discovery snapshot (no trust priors).
fn project_snapshot(peers: Vec<ResolvedNearbyPeer>) -> NearbyDiscoverySnapshot {
    let trusted: BTreeMap<String, skybridge_core::NearbyDiscoveryTrustStatus> = BTreeMap::new();
    build_active_scan_snapshot(
        peers,
        &trusted,
        skybridge_agent::DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
    )
}

// ===========================================================================
// File-transfer frame codec (length-prefixed buffers)
// ===========================================================================

/// Encode a file-transfer OFFER frame (`SBF1`) into `*out_buffer`.
///
/// * `transfer_id_ptr` — exactly 16 bytes.
/// * `expected_sha256_ptr` — exactly 32 bytes.
/// * `filename_ptr`/`filename_len` — UTF-8 filename (1..=255 bytes, no NUL).
///
/// # Safety
/// All `(ptr, len)` pairs must satisfy their length contracts; `out_buffer`
/// must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_file_frame_encode_offer(
    transfer_id_ptr: *const u8,
    total_size: u64,
    chunk_size: u32,
    expected_sha256_ptr: *const u8,
    filename_ptr: *const u8,
    filename_len: usize,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if out_buffer.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(transfer_id) = (unsafe { read_array16(transfer_id_ptr) }) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let Some(expected) = (unsafe { read_array32(expected_sha256_ptr) }) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let Some(filename_bytes) = (unsafe { slice_from_raw(filename_ptr, filename_len) }) else {
            return SkyBridgeStatus::NullArgument;
        };
        let Ok(filename) = std::str::from_utf8(filename_bytes) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        match skybridge_core::encode_offer(
            &transfer_id,
            total_size,
            chunk_size,
            &expected,
            filename,
        ) {
            Ok(bytes) => write_buffer(out_buffer, bytes),
            Err(_) => SkyBridgeStatus::InvalidArgument,
        }
    })
}

/// Encode a file-transfer CHUNK frame into `*out_buffer`.
///
/// # Safety
/// `transfer_id_ptr` must point to 16 bytes; the payload `(ptr, len)` pair must
/// be valid; `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_file_frame_encode_chunk(
    transfer_id_ptr: *const u8,
    sequence: u32,
    payload_ptr: *const u8,
    payload_len: usize,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if out_buffer.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(transfer_id) = (unsafe { read_array16(transfer_id_ptr) }) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let Some(payload) = (unsafe { slice_from_raw(payload_ptr, payload_len) }) else {
            return SkyBridgeStatus::NullArgument;
        };
        match skybridge_core::encode_chunk(&transfer_id, sequence, payload) {
            Ok(bytes) => write_buffer(out_buffer, bytes),
            Err(_) => SkyBridgeStatus::InvalidArgument,
        }
    })
}

/// Encode a file-transfer RECEIPT frame into `*out_buffer`.
///
/// # Safety
/// `transfer_id_ptr` must point to 16 bytes; `computed_sha256_ptr` to 32 bytes;
/// the reason `(ptr, len)` pair must be valid UTF-8; `out_buffer` must be
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_file_frame_encode_receipt(
    transfer_id_ptr: *const u8,
    ok: bool,
    computed_sha256_ptr: *const u8,
    reason_ptr: *const u8,
    reason_len: usize,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if out_buffer.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(transfer_id) = (unsafe { read_array16(transfer_id_ptr) }) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let Some(computed) = (unsafe { read_array32(computed_sha256_ptr) }) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let Some(reason_bytes) = (unsafe { slice_from_raw(reason_ptr, reason_len) }) else {
            return SkyBridgeStatus::NullArgument;
        };
        let Ok(reason) = std::str::from_utf8(reason_bytes) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        match skybridge_core::encode_receipt(&transfer_id, ok, &computed, reason) {
            Ok(bytes) => write_buffer(out_buffer, bytes),
            Err(_) => SkyBridgeStatus::InvalidArgument,
        }
    })
}

/// Encode a file-transfer CHUNK-ACK frame into `*out_buffer`. (Cannot fail
/// except on a NULL transfer id or out buffer.)
///
/// # Safety
/// `transfer_id_ptr` must point to 16 bytes; `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_file_frame_encode_chunk_ack(
    transfer_id_ptr: *const u8,
    acked_through_seq: u32,
    out_buffer: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if out_buffer.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(transfer_id) = (unsafe { read_array16(transfer_id_ptr) }) else {
            return SkyBridgeStatus::InvalidArgument;
        };
        let bytes = skybridge_core::encode_chunk_ack(&transfer_id, acked_through_seq);
        write_buffer(out_buffer, bytes)
    })
}

/// Returns `true` (written to `*out_is_file_frame`) if `(ptr, len)` looks like a
/// binary file frame (vs a JSON keepalive).
///
/// # Safety
/// The `(ptr, len)` pair must be valid; `out_is_file_frame` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_file_frame_is_file_frame(
    plaintext_ptr: *const u8,
    plaintext_len: usize,
    out_is_file_frame: *mut bool,
) -> i32 {
    guard(|| {
        if out_is_file_frame.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(plaintext) = (unsafe { slice_from_raw(plaintext_ptr, plaintext_len) }) else {
            return SkyBridgeStatus::NullArgument;
        };
        unsafe {
            ptr::write(
                out_is_file_frame,
                skybridge_core::is_file_app_frame(plaintext),
            )
        };
        SkyBridgeStatus::Ok
    })
}

/// Decode a file-transfer frame into a JSON description written to
/// `*out_json` (caller frees with [`skybridge_buffer_free`]).
///
/// The JSON is a tagged object, e.g.
/// `{"type":"chunk","transfer_id":"<hex>","sequence":0,"payload_len":4}`.
/// Binary payloads are base64-encoded under `payload_base64` for the chunk type.
/// Returns [`SkyBridgeStatus::INVALID_ARGUMENT`] on a malformed frame.
///
/// # Safety
/// The `(ptr, len)` pair must be valid; `out_json` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn skybridge_file_frame_decode(
    plaintext_ptr: *const u8,
    plaintext_len: usize,
    out_json: *mut SkyBridgeBuffer,
) -> i32 {
    guard(|| {
        if out_json.is_null() {
            return SkyBridgeStatus::NullArgument;
        }
        let Some(plaintext) = (unsafe { slice_from_raw(plaintext_ptr, plaintext_len) }) else {
            return SkyBridgeStatus::NullArgument;
        };
        match skybridge_core::decode_file_app_frame(plaintext) {
            Ok(frame) => write_buffer(out_json, file_frame_to_json(&frame).into_bytes()),
            Err(_) => SkyBridgeStatus::InvalidArgument,
        }
    })
}

#[inline]
unsafe fn read_array16(ptr: *const u8) -> Option<[u8; 16]> {
    let slice = unsafe { slice_from_raw(ptr, 16) }?;
    let mut out = [0u8; 16];
    out.copy_from_slice(slice);
    Some(out)
}

#[inline]
unsafe fn read_array32(ptr: *const u8) -> Option<[u8; 32]> {
    let slice = unsafe { slice_from_raw(ptr, 32) }?;
    let mut out = [0u8; 32];
    out.copy_from_slice(slice);
    Some(out)
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        use std::fmt::Write as _;
        let _ = write!(s, "{b:02x}");
    }
    s
}

fn file_frame_to_json(frame: &skybridge_core::FileAppFrame) -> String {
    use skybridge_core::FileAppFrame::*;
    match frame {
        Offer {
            transfer_id,
            total_size,
            chunk_size,
            expected_sha256,
            filename,
        } => format!(
            "{{\"type\":\"offer\",\"transfer_id\":\"{}\",\"total_size\":{},\"chunk_size\":{},\"expected_sha256\":\"{}\",\"filename\":{}}}",
            hex(transfer_id),
            total_size,
            chunk_size,
            hex(expected_sha256),
            serde_json::to_string(filename).unwrap_or_else(|_| "\"\"".to_owned()),
        ),
        Chunk {
            transfer_id,
            sequence,
            payload,
        } => format!(
            "{{\"type\":\"chunk\",\"transfer_id\":\"{}\",\"sequence\":{},\"payload_len\":{}}}",
            hex(transfer_id),
            sequence,
            payload.len(),
        ),
        Receipt {
            transfer_id,
            ok,
            computed_sha256,
            reason,
        } => format!(
            "{{\"type\":\"receipt\",\"transfer_id\":\"{}\",\"ok\":{},\"computed_sha256\":\"{}\",\"reason\":{}}}",
            hex(transfer_id),
            ok,
            hex(computed_sha256),
            serde_json::to_string(reason).unwrap_or_else(|_| "\"\"".to_owned()),
        ),
        ChunkAck {
            transfer_id,
            acked_through_seq,
        } => format!(
            "{{\"type\":\"chunk_ack\",\"transfer_id\":\"{}\",\"acked_through_seq\":{}}}",
            hex(transfer_id),
            acked_through_seq,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// init -> configure policy (authorize an eligible downgrade) -> free.
    #[test]
    fn c_abi_policy_gate_round_trip() {
        unsafe {
            let mut gate: *mut SkyBridgePolicyGate = ptr::null_mut();
            let rc = skybridge_policy_gate_new(SkyBridgeDowngradePolicy::PreferPqc, &mut gate);
            assert_eq!(rc, SkyBridgeStatus::Ok.code());
            assert!(!gate.is_null());

            // Read policy back.
            let mut policy_code = u32::MAX;
            let rc = skybridge_policy_gate_policy(gate, &mut policy_code);
            assert_eq!(rc, SkyBridgeStatus::Ok.code());
            assert_eq!(policy_code, SkyBridgeDowngradePolicy::PreferPqc as u32);

            // Authorize an eligible downgrade.
            let peer = b"peer-c-abi";
            let mut decision = SkyBridgeBuffer::empty();
            let rc = skybridge_policy_gate_authorize_downgrade(
                gate,
                peer.as_ptr(),
                peer.len(),
                CryptoSuite::MLKEM768_MLDSA65.wire_id,
                CryptoSuite::X25519_ED25519.wire_id,
                SkyBridgeFallbackReason::PqcProviderUnavailable,
                ptr::null(),
                0,
                &mut decision,
            );
            assert_eq!(
                rc,
                SkyBridgeStatus::Ok.code(),
                "eligible downgrade authorized"
            );
            assert!(!decision.ptr.is_null());
            let json = std::slice::from_raw_parts(decision.ptr, decision.len);
            let text = std::str::from_utf8(json).unwrap();
            assert!(
                text.contains("downgrade_resistance"),
                "audit record present: {text}"
            );
            assert_eq!(
                skybridge_buffer_free(&mut decision),
                SkyBridgeStatus::Ok.code()
            );

            // A BLOCKED reason is denied (timeout).
            let mut denied = SkyBridgeBuffer::empty();
            let rc = skybridge_policy_gate_authorize_downgrade(
                gate,
                peer.as_ptr(),
                peer.len(),
                CryptoSuite::MLKEM768_MLDSA65.wire_id,
                CryptoSuite::X25519_ED25519.wire_id,
                SkyBridgeFallbackReason::Timeout,
                ptr::null(),
                0,
                &mut denied,
            );
            assert_eq!(
                rc,
                SkyBridgeStatus::DowngradeDenied.code(),
                "timeout never downgraded"
            );
            let dtext =
                std::str::from_utf8(std::slice::from_raw_parts(denied.ptr, denied.len)).unwrap();
            assert!(
                dtext.contains("reason_ineligible"),
                "denial reason: {dtext}"
            );
            assert_eq!(
                skybridge_buffer_free(&mut denied),
                SkyBridgeStatus::Ok.code()
            );

            assert_eq!(skybridge_policy_gate_free(gate), SkyBridgeStatus::Ok.code());
        }
    }

    /// Strict-compliance gate denies even an eligible reason (policy denial).
    #[test]
    fn c_abi_strict_compliance_denies() {
        unsafe {
            let mut gate: *mut SkyBridgePolicyGate = ptr::null_mut();
            assert_eq!(
                skybridge_policy_gate_new(SkyBridgeDowngradePolicy::StrictPqcCompliance, &mut gate),
                SkyBridgeStatus::Ok.code()
            );
            let peer = b"peer-strict";
            let mut decision = SkyBridgeBuffer::empty();
            let rc = skybridge_policy_gate_authorize_downgrade_code(
                gate,
                peer.as_ptr(),
                peer.len(),
                CryptoSuite::MLKEM768_MLDSA65.wire_id,
                CryptoSuite::X25519_ED25519.wire_id,
                SkyBridgeFallbackReason::SuiteNegotiationFailed as u32,
                ptr::null(),
                0,
                &mut decision,
            );
            assert_eq!(rc, SkyBridgeStatus::DowngradeDenied.code());
            let text = std::str::from_utf8(std::slice::from_raw_parts(decision.ptr, decision.len))
                .unwrap();
            assert!(
                text.contains("\"denied\":\"policy\""),
                "policy denial: {text}"
            );
            assert_eq!(
                skybridge_buffer_free(&mut decision),
                SkyBridgeStatus::Ok.code()
            );
            assert_eq!(skybridge_policy_gate_free(gate), SkyBridgeStatus::Ok.code());
        }
    }

    /// Identity generate -> read a public key -> free.
    #[test]
    fn c_abi_identity_round_trip() {
        unsafe {
            let mut id: *mut SkyBridgeIdentity = ptr::null_mut();
            assert_eq!(
                skybridge_identity_generate(&mut id),
                SkyBridgeStatus::Ok.code()
            );
            assert!(!id.is_null());

            let mut signing = SkyBridgeBuffer::empty();
            assert_eq!(
                skybridge_identity_signing_public_key(id, &mut signing),
                SkyBridgeStatus::Ok.code()
            );
            assert!(signing.len > 0, "ML-DSA-65 public key is non-empty");
            assert_eq!(
                skybridge_buffer_free(&mut signing),
                SkyBridgeStatus::Ok.code()
            );

            let mut kem = SkyBridgeBuffer::empty();
            assert_eq!(
                skybridge_identity_mlkem768_public_key(id, &mut kem),
                SkyBridgeStatus::Ok.code()
            );
            assert!(kem.len > 0, "ML-KEM-768 public key is non-empty");
            assert_eq!(skybridge_buffer_free(&mut kem), SkyBridgeStatus::Ok.code());

            assert_eq!(skybridge_identity_free(id), SkyBridgeStatus::Ok.code());
        }
    }

    /// File-frame encode -> decode round-trip across the C ABI.
    #[test]
    fn c_abi_file_frame_round_trip() {
        unsafe {
            let transfer_id = [7u8; 16];
            let payload = b"hello-skybridge";
            let mut frame = SkyBridgeBuffer::empty();
            assert_eq!(
                skybridge_file_frame_encode_chunk(
                    transfer_id.as_ptr(),
                    42,
                    payload.as_ptr(),
                    payload.len(),
                    &mut frame,
                ),
                SkyBridgeStatus::Ok.code()
            );
            assert!(frame.len > 0);

            // It should be recognized as a file frame.
            let mut is_frame = false;
            assert_eq!(
                skybridge_file_frame_is_file_frame(frame.ptr, frame.len, &mut is_frame),
                SkyBridgeStatus::Ok.code()
            );
            assert!(is_frame);

            // Decode -> JSON.
            let mut json = SkyBridgeBuffer::empty();
            assert_eq!(
                skybridge_file_frame_decode(frame.ptr, frame.len, &mut json),
                SkyBridgeStatus::Ok.code()
            );
            let text = std::str::from_utf8(std::slice::from_raw_parts(json.ptr, json.len)).unwrap();
            assert!(text.contains("\"type\":\"chunk\""), "decoded JSON: {text}");
            assert!(text.contains("\"sequence\":42"));

            assert_eq!(skybridge_buffer_free(&mut json), SkyBridgeStatus::Ok.code());
            assert_eq!(
                skybridge_buffer_free(&mut frame),
                SkyBridgeStatus::Ok.code()
            );
        }
    }

    /// NULL-argument handling is graceful (no panic, no crash).
    #[test]
    fn c_abi_null_arguments_are_safe() {
        unsafe {
            assert_eq!(
                skybridge_policy_gate_new(SkyBridgeDowngradePolicy::Default, ptr::null_mut()),
                SkyBridgeStatus::NullArgument.code()
            );
            assert_eq!(
                skybridge_identity_generate(ptr::null_mut()),
                SkyBridgeStatus::NullArgument.code()
            );
            // freeing NULL is a no-op
            assert_eq!(
                skybridge_policy_gate_free(ptr::null_mut()),
                SkyBridgeStatus::Ok.code()
            );
            assert_eq!(
                skybridge_identity_free(ptr::null_mut()),
                SkyBridgeStatus::Ok.code()
            );
            assert_eq!(
                skybridge_client_free(ptr::null_mut()),
                SkyBridgeStatus::Ok.code()
            );
            assert_eq!(
                skybridge_buffer_free(ptr::null_mut()),
                SkyBridgeStatus::Ok.code()
            );
        }
    }

    /// Client lifecycle: new -> set callback (none) -> discovery flags -> free.
    #[test]
    fn c_abi_client_lifecycle() {
        unsafe {
            let mut client: *mut SkyBridgeClient = ptr::null_mut();
            assert_eq!(
                skybridge_client_new(&mut client),
                SkyBridgeStatus::Ok.code()
            );
            assert!(!client.is_null());

            // Clearing the callback (NULL) is valid.
            assert_eq!(
                skybridge_client_set_event_callback(client, None, ptr::null_mut()),
                SkyBridgeStatus::Ok.code()
            );

            let mut running = true;
            assert_eq!(
                skybridge_client_discovery_running(client, &mut running),
                SkyBridgeStatus::Ok.code()
            );
            assert!(!running, "no discovery running initially");

            assert_eq!(
                skybridge_client_stop_discovery(client),
                SkyBridgeStatus::Ok.code()
            );
            assert_eq!(skybridge_client_free(client), SkyBridgeStatus::Ok.code());
        }
    }
}
