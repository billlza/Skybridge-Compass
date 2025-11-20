use crate::error::CoreError;

/// Represents bitrate control requests.
#[derive(Debug, Clone, Copy)]
pub struct FlowRate {
    pub target_bitrate_bps: u64,
    pub max_latency_ms: u32,
}

/// Stream telemetry exported to UI.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamMetrics {
    pub bitrate_bps: u64,
    pub packet_loss: f32,
}

/// API surface for controlling the remote desktop stream pipeline.
#[async_trait::async_trait(?Send)]
pub trait StreamController {
    async fn adjust_flow(&self, rate: FlowRate);
    async fn metrics(&self) -> StreamMetrics;
}

/// Marker trait for file transfer actions.
#[async_trait::async_trait(?Send)]
pub trait FileTransferCoordinator {
    async fn upload(&self, path: &str) -> Result<(), CoreError>;
    async fn download(&self, remote_path: &str) -> Result<(), CoreError>;
}
