use skybridge_core::SignalingLifecyclePhase;

#[derive(Debug, Default)]
pub(super) struct InlineConnectState {
    pub(super) signaling_stream_closed: bool,
    pub(super) signaling_bound: bool,
    pub(super) join_sent: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct InlineLifecycleDecision {
    pub(super) send_join: bool,
    pub(super) failed_before_bound: bool,
}

impl InlineConnectState {
    pub(super) fn apply_lifecycle_phase(
        &mut self,
        phase: SignalingLifecyclePhase,
    ) -> InlineLifecycleDecision {
        let send_join = phase == SignalingLifecyclePhase::Bound && !self.join_sent;
        if send_join {
            self.signaling_bound = true;
            self.join_sent = true;
        }
        let failed_before_bound = phase == SignalingLifecyclePhase::Failed && !self.signaling_bound;
        if matches!(
            phase,
            SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed
        ) {
            self.signaling_stream_closed = true;
        }
        InlineLifecycleDecision {
            send_join,
            failed_before_bound,
        }
    }
}
