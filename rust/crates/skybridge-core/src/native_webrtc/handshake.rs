use anyhow::Result;

use crate::{
    ClassicHandleResult, ClassicInitiatorConfig, ClassicInitiatorHandshake, ClassicResponderConfig,
    ClassicResponderHandshake, PqcInitiatorConfig, PqcInitiatorHandshake, PqcResponderConfig,
    PqcResponderHandshake,
};

#[derive(Debug)]
enum NativeInitiatorHandshake {
    Classic(ClassicInitiatorHandshake),
    Pqc(PqcInitiatorHandshake),
}

#[derive(Debug)]
enum NativeResponderHandshake {
    Classic(ClassicResponderHandshake),
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
}

impl NativeResponderHandshake {
    fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match self {
            Self::Classic(handshake) => handshake.handle_frame(frame),
            Self::Pqc(handshake) => handshake.handle_frame(frame),
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

    pub(super) fn classic_responder(config: ClassicResponderConfig) -> Result<Self> {
        Ok(Self(NativeSessionHandshakeKind::Responder(
            NativeResponderHandshake::Classic(ClassicResponderHandshake::new(config)?),
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
}
