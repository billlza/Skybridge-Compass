//! Stub implementations for non-Linux platforms

use tokio::sync::mpsc;

use crate::remote::capture::{
    CaptureBackend, CaptureConfig, CaptureError, CaptureState, CapturedFrame, DisplayServer,
    ScreenInfo,
};

/// Stub Wayland capture for non-Linux platforms
pub struct WaylandCapture;

impl WaylandCapture {
    /// Create a new stub Wayland capture
    pub fn new() -> Self {
        Self
    }
}

impl Default for WaylandCapture {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl CaptureBackend for WaylandCapture {
    async fn initialize(&mut self) -> Result<(), CaptureError> {
        Err(CaptureError::Wayland(
            "Wayland capture not supported on this platform".to_string(),
        ))
    }

    async fn get_screens(&self) -> Result<Vec<ScreenInfo>, CaptureError> {
        Err(CaptureError::NotInitialized)
    }

    async fn start(
        &mut self,
        _config: &CaptureConfig,
    ) -> Result<mpsc::Receiver<CapturedFrame>, CaptureError> {
        Err(CaptureError::NotInitialized)
    }

    async fn stop(&mut self) -> Result<(), CaptureError> {
        Ok(())
    }

    async fn pause(&mut self) -> Result<(), CaptureError> {
        Ok(())
    }

    async fn resume(&mut self) -> Result<(), CaptureError> {
        Err(CaptureError::NotInitialized)
    }

    fn state(&self) -> CaptureState {
        CaptureState::Uninitialized
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::Wayland
    }
}

/// Stub X11 capture for non-Linux platforms
pub struct X11Capture;

impl X11Capture {
    /// Create a new stub X11 capture
    pub fn new() -> Self {
        Self
    }
}

impl Default for X11Capture {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl CaptureBackend for X11Capture {
    async fn initialize(&mut self) -> Result<(), CaptureError> {
        Err(CaptureError::X11(
            "X11 capture not supported on this platform".to_string(),
        ))
    }

    async fn get_screens(&self) -> Result<Vec<ScreenInfo>, CaptureError> {
        Err(CaptureError::NotInitialized)
    }

    async fn start(
        &mut self,
        _config: &CaptureConfig,
    ) -> Result<mpsc::Receiver<CapturedFrame>, CaptureError> {
        Err(CaptureError::NotInitialized)
    }

    async fn stop(&mut self) -> Result<(), CaptureError> {
        Ok(())
    }

    async fn pause(&mut self) -> Result<(), CaptureError> {
        Ok(())
    }

    async fn resume(&mut self) -> Result<(), CaptureError> {
        Err(CaptureError::NotInitialized)
    }

    fn state(&self) -> CaptureState {
        CaptureState::Uninitialized
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::X11
    }
}
