use crate::error::{CoreError, CoreResult};
use std::sync::Mutex;

/// Represents runtime state of a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    ShuttingDown,
}

/// Thread-safe state machine guarding engine lifecycle transitions.
#[derive(Debug)]
pub struct SessionStateMachine {
    state: Mutex<SessionState>,
}

impl SessionStateMachine {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(SessionState::Disconnected),
        }
    }

    /// Returns the current session state.
    pub fn current(&self) -> SessionState {
        *self.state.lock().unwrap()
    }

    /// Attempts a state transition using an explicit table of allowed predecessors.
    pub fn transition(&self, next: SessionState) -> CoreResult<()> {
        let allowed = Self::allowed_predecessors(next);
        let mut guard = self.state.lock().unwrap();
        let current = *guard;

        if !allowed.contains(&current) {
            return Err(CoreError::InvalidState {
                expected: Self::describe_expected(allowed),
                actual: current,
            });
        }

        *guard = next;
        Ok(())
    }

    fn allowed_predecessors(target: SessionState) -> &'static [SessionState] {
        match target {
            SessionState::Disconnected => &[
                SessionState::ShuttingDown,
                SessionState::Connecting,
                SessionState::Reconnecting,
                SessionState::Connected,
                SessionState::Disconnected,
            ],
            SessionState::Connecting => &[SessionState::Disconnected],
            SessionState::Connected => &[SessionState::Connecting, SessionState::Reconnecting],
            SessionState::Reconnecting => &[SessionState::Connected],
            SessionState::ShuttingDown => &[
                SessionState::Connected,
                SessionState::Reconnecting,
                SessionState::Connecting,
                SessionState::Disconnected,
            ],
        }
    }

    fn describe_expected(states: &[SessionState]) -> String {
        states
            .iter()
            .map(|state| match state {
                SessionState::Disconnected => "Disconnected",
                SessionState::Connecting => "Connecting",
                SessionState::Connected => "Connected",
                SessionState::Reconnecting => "Reconnecting",
                SessionState::ShuttingDown => "ShuttingDown",
            })
            .collect::<Vec<_>>()
            .join("|")
    }
}

impl Default for SessionStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

/// Configuration for establishing a new session.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub client_id: String,
    pub heartbeat_interval_ms: u64,
    pub peer_public_key: Option<Vec<u8>>,
}

/// Trait to be implemented by session managers.
#[async_trait::async_trait(?Send)]
pub trait AsyncSessionManager {
    async fn establish_async(&self, config: SessionConfig) -> CoreResult<()>;
    async fn reconnect_async(&self) -> CoreResult<()>;
    async fn terminate_async(&self);
    fn state(&self) -> SessionState;
}

/// Heartbeat hook for the platform layer.
#[async_trait::async_trait(?Send)]
pub trait HeartbeatEmitter {
    async fn emit(&self) -> CoreResult<()>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transition_table_allows_happy_path() {
        let machine = SessionStateMachine::new();
        machine.transition(SessionState::Connecting).unwrap();
        assert_eq!(machine.current(), SessionState::Connecting);
        machine.transition(SessionState::Connected).unwrap();
        assert_eq!(machine.current(), SessionState::Connected);
        machine.transition(SessionState::Reconnecting).unwrap();
        machine.transition(SessionState::Connected).unwrap();
        machine.transition(SessionState::ShuttingDown).unwrap();
        machine.transition(SessionState::Disconnected).unwrap();
        assert_eq!(machine.current(), SessionState::Disconnected);
    }

    #[test]
    fn invalid_transition_reports_expected_states() {
        let machine = SessionStateMachine::new();
        let err = machine
            .transition(SessionState::Connected)
            .expect_err("cannot connect directly from disconnected");

        match err {
            CoreError::InvalidState { expected, actual } => {
                assert_eq!(actual, SessionState::Disconnected);
                assert_eq!(expected, "Connecting|Reconnecting");
            }
            other => panic!("unexpected error: {:?}", other),
        }
    }
}
