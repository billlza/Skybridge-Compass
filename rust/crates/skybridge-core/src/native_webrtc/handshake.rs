use anyhow::Result;

use crate::{
    ClassicHandleResult, ClassicInitiatorConfig, ClassicInitiatorHandshake, PqcInitiatorConfig,
    PqcInitiatorHandshake, PqcResponderConfig, PqcResponderHandshake,
};

#[derive(Debug)]
enum NativeInitiatorHandshake {
    Classic(ClassicInitiatorHandshake),
    Pqc(PqcInitiatorHandshake),
}

#[derive(Debug)]
enum NativeResponderHandshake {
    Pqc(PqcResponderHandshake),
}

#[derive(Debug)]
enum NativeSessionHandshakeKind {
    Initiator(NativeInitiatorHandshake),
    Responder(NativeResponderHandshake),
}

#[derive(Debug)]
pub(super) struct NativeSessionHandshake(NativeSessionHandshakeKind);

impl NativeInitiatorHandshake {
    fn start(&mut self) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.start(),
            Self::Pqc(handshake) => handshake.start(),
        }
    }

    fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match self {
            Self::Classic(handshake) => handshake.handle_frame(frame),
            Self::Pqc(handshake) => handshake.handle_frame(frame),
        }
    }

    fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_heartbeat_frame(),
            Self::Pqc(handshake) => handshake.build_heartbeat_frame(),
        }
    }

    fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_pong_frame(id),
            Self::Pqc(handshake) => handshake.build_pong_frame(id),
        }
    }

    fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_ping_frame(id),
            Self::Pqc(handshake) => handshake.build_ping_frame(id),
        }
    }
}

impl NativeResponderHandshake {
    fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match self {
            Self::Pqc(handshake) => handshake.handle_frame(frame),
        }
    }

    fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_heartbeat_frame(),
        }
    }

    fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_pong_frame(id),
        }
    }

    fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_ping_frame(id),
        }
    }
}

impl NativeSessionHandshake {
    pub(super) fn classic_initiator(config: ClassicInitiatorConfig) -> Result<Self> {
        Ok(Self(NativeSessionHandshakeKind::Initiator(
            NativeInitiatorHandshake::Classic(ClassicInitiatorHandshake::new(config)?),
        )))
    }

    pub(super) fn pqc_initiator(config: PqcInitiatorConfig) -> Result<Self> {
        Ok(Self(NativeSessionHandshakeKind::Initiator(
            NativeInitiatorHandshake::Pqc(PqcInitiatorHandshake::new(config)?),
        )))
    }

    pub(super) fn pqc_responder(config: PqcResponderConfig) -> Result<Self> {
        Ok(Self(NativeSessionHandshakeKind::Responder(
            NativeResponderHandshake::Pqc(PqcResponderHandshake::new(config)?),
        )))
    }

    pub(super) fn start(&mut self) -> Result<Vec<u8>> {
        match &mut self.0 {
            NativeSessionHandshakeKind::Initiator(handshake) => handshake.start(),
            NativeSessionHandshakeKind::Responder(_) => Ok(Vec::new()),
        }
    }

    pub(super) fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match &mut self.0 {
            NativeSessionHandshakeKind::Initiator(handshake) => handshake.handle_frame(frame),
            NativeSessionHandshakeKind::Responder(handshake) => handshake.handle_frame(frame),
        }
    }

    pub(super) fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        match &self.0 {
            NativeSessionHandshakeKind::Initiator(handshake) => handshake.build_heartbeat_frame(),
            NativeSessionHandshakeKind::Responder(handshake) => handshake.build_heartbeat_frame(),
        }
    }

    pub(super) fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        match &self.0 {
            NativeSessionHandshakeKind::Initiator(handshake) => handshake.build_pong_frame(id),
            NativeSessionHandshakeKind::Responder(handshake) => handshake.build_pong_frame(id),
        }
    }

    pub(super) fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        match &self.0 {
            NativeSessionHandshakeKind::Initiator(handshake) => handshake.build_ping_frame(id),
            NativeSessionHandshakeKind::Responder(handshake) => handshake.build_ping_frame(id),
        }
    }
}
