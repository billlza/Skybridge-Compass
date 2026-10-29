use std::sync::Arc;

use bytes::BytesMut;
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelId};
use webrtc::error::Result;

/// The operations owned by SkyBridge's control-channel lifecycle. Upstream's
/// DataChannel trait is sealed; keep fault injection at our boundary instead
/// of implementing an upstream trait or replacing the real transport.
#[async_trait::async_trait]
pub(super) trait ControlDataChannel: Send + Sync + 'static {
    fn id(&self) -> RTCDataChannelId;
    async fn label(&self) -> Result<String>;
    async fn send(&self, data: BytesMut) -> Result<()>;
    async fn poll(&self) -> Option<DataChannelEvent>;
    async fn close(&self) -> Result<()>;
}

pub(super) struct NativeControlDataChannel(pub(super) Arc<dyn DataChannel>);

#[async_trait::async_trait]
impl ControlDataChannel for NativeControlDataChannel {
    fn id(&self) -> RTCDataChannelId {
        self.0.id()
    }

    async fn label(&self) -> Result<String> {
        self.0.label().await
    }

    async fn send(&self, data: BytesMut) -> Result<()> {
        self.0.send(data).await
    }

    async fn poll(&self) -> Option<DataChannelEvent> {
        self.0.poll().await
    }

    async fn close(&self) -> Result<()> {
        self.0.close().await
    }
}
