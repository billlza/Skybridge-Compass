use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncomingTransferSource {
    MacLanJson,
    QuantumWire,
    WebRtcDataChannel,
}

#[derive(Debug, Clone)]
pub struct IncomingTransferRequest {
    pub source: IncomingTransferSource,
    pub transfer_id: String,
    pub file_name: String,
    pub file_size: u64,
    pub sender_device_id: Option<String>,
    pub sender_device_name: Option<String>,
    pub target_dir: PathBuf,
}

#[derive(Debug, Clone)]
pub struct IncomingTransferDecision {
    pub accept: bool,
    pub save_path: Option<PathBuf>,
    pub overwrite: bool,
}

impl IncomingTransferDecision {
    pub fn decline() -> Self {
        Self {
            accept: false,
            save_path: None,
            overwrite: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct IncomingTransferCompleted {
    pub source: IncomingTransferSource,
    pub transfer_id: String,
    pub file_name: String,
    pub save_path: Option<PathBuf>,
    pub success: bool,
    pub received_bytes: u64,
    pub error: Option<String>,
    pub sender_device_id: Option<String>,
    pub sender_device_name: Option<String>,
}

pub struct IncomingTransferPromptRequest {
    pub request: IncomingTransferRequest,
    pub decision_tx: oneshot::Sender<IncomingTransferDecision>,
}

#[derive(Debug, Clone)]
pub struct IncomingTransferPromptConfig {
    pub request_tx: mpsc::UnboundedSender<IncomingTransferPromptRequest>,
    pub completed_tx: Option<mpsc::UnboundedSender<IncomingTransferCompleted>>,
    pub decision_timeout: Duration,
}
