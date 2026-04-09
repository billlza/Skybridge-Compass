//! Wayland capture backed by xdg-desktop-portal and a real PipeWire stream.
//!
//! This backend intentionally fails closed when portal restore, PipeWire
//! connection, or frame delivery stop being real. Production should never see
//! fabricated success states here.

use std::os::fd::IntoRawFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc as std_mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use lamco_pipewire::{
    PipeWireThreadCommand, PipeWireThreadManager, PixelFormat as PipeWirePixelFormat,
    PwStreamState, StreamConfig,
};
use tokio::sync::{mpsc, oneshot};

use crate::remote::capture::{
    CaptureBackend, CaptureConfig, CaptureError, CaptureRegion, CaptureState, CapturedFrame,
    DisplayServer, PixelFormat, ScreenInfo,
};
use crate::remote::portal::{
    PortalCaptureContext, PortalError, active_portal_call_context, active_portal_capture_context,
    ensure_runtime_portal_session,
};

const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(15);
const FRAME_STALL_TIMEOUT: Duration = Duration::from_secs(5);

/// Wayland screen capture via the shared portal coordinator.
pub struct WaylandCapture {
    state: CaptureState,
    config: Option<CaptureConfig>,
    stop_flag: Arc<AtomicBool>,
    capture_task: Option<tokio::task::JoinHandle<()>>,
}

impl WaylandCapture {
    /// Create a new Wayland capture backend.
    pub fn new() -> Self {
        Self {
            state: CaptureState::Uninitialized,
            config: None,
            stop_flag: Arc::new(AtomicBool::new(false)),
            capture_task: None,
        }
    }
}

impl Default for WaylandCapture {
    fn default() -> Self {
        Self::new()
    }
}

fn map_portal_error(error: PortalError) -> CaptureError {
    match error {
        PortalError::PermissionDenied => CaptureError::PermissionDenied,
        PortalError::BootstrapRequired | PortalError::RebootstrapRequired => {
            CaptureError::Portal(error.to_string())
        }
        PortalError::PersistentOutputLost => CaptureError::Portal(error.to_string()),
        PortalError::SecretStoreUnavailable(_) => CaptureError::Portal(error.to_string()),
        PortalError::Portal(_) | PortalError::Io(_) | PortalError::Serde(_) => {
            CaptureError::Portal(error.to_string())
        }
    }
}

fn portal_screen_info(id: u32, width: u32, height: u32) -> ScreenInfo {
    ScreenInfo {
        id,
        name: "Wayland Persistent Output".to_string(),
        width,
        height,
        x: 0,
        y: 0,
        refresh_rate: 60.0,
        scale: 1.0,
        is_primary: true,
    }
}

fn build_stream_config(stream: &PortalCaptureContext, config: &CaptureConfig) -> StreamConfig {
    let mut stream_config = StreamConfig::new("skybridge-wayland")
        .with_resolution(stream.stream.width.max(1), stream.stream.height.max(1))
        .with_framerate(config.target_fps.max(1))
        .with_dmabuf(config.hardware_accel)
        .with_buffer_count(4);
    stream_config.preferred_format = Some(PipeWirePixelFormat::BGRA);
    stream_config
}

fn timestamp_ns(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64
}

fn normalize_pipewire_frame(
    frame: &lamco_pipewire::VideoFrame,
    frame_number: u64,
) -> Result<CapturedFrame, CaptureError> {
    let (format, force_opaque_alpha) = match frame.format {
        PipeWirePixelFormat::BGRA => (PixelFormat::Bgra8888, false),
        PipeWirePixelFormat::BGRx => (PixelFormat::Bgra8888, true),
        PipeWirePixelFormat::RGBA => (PixelFormat::Rgba8888, false),
        PipeWirePixelFormat::RGBx => (PixelFormat::Rgba8888, true),
        PipeWirePixelFormat::RGB => (PixelFormat::Rgb888, false),
        PipeWirePixelFormat::BGR => (PixelFormat::Bgr888, false),
        other => {
            return Err(CaptureError::Portal(format!(
                "Unsupported PipeWire pixel format: {:?}",
                other
            )));
        }
    };

    let bytes_per_pixel = format.bytes_per_pixel();
    let row_bytes = frame.width as usize * bytes_per_pixel;
    let stride = frame.stride as usize;
    let raw = frame.data.as_slice();
    let required_len = stride
        .checked_mul(frame.height as usize)
        .ok_or_else(|| CaptureError::Portal("PipeWire frame size overflow".to_string()))?;

    if stride < row_bytes {
        return Err(CaptureError::Portal(format!(
            "PipeWire stride {} is smaller than row size {}",
            stride, row_bytes
        )));
    }
    if raw.len() < required_len {
        return Err(CaptureError::Portal(format!(
            "PipeWire frame payload too small: {} < {}",
            raw.len(),
            required_len
        )));
    }

    let mut data = Vec::with_capacity(row_bytes * frame.height as usize);
    for row in 0..frame.height as usize {
        let start = row * stride;
        let end = start + row_bytes;
        data.extend_from_slice(&raw[start..end]);
    }

    if force_opaque_alpha {
        for alpha_index in (3..data.len()).step_by(4) {
            data[alpha_index] = 0xff;
        }
    }

    Ok(CapturedFrame {
        width: frame.width,
        height: frame.height,
        format,
        data,
        timestamp: timestamp_ns(frame.capture_time),
        frame_number,
        capture_latency_us: frame.capture_time.elapsed().unwrap_or_default().as_micros() as u64,
    })
}

fn crop_frame(frame: CapturedFrame, region: CaptureRegion) -> Result<CapturedFrame, CaptureError> {
    let start_x = region.x.max(0) as u32;
    let start_y = region.y.max(0) as u32;
    if start_x >= frame.width || start_y >= frame.height {
        return Err(CaptureError::Wayland(
            "Requested capture region is outside the persistent output".to_string(),
        ));
    }

    let width = region.width.min(frame.width - start_x);
    let height = region.height.min(frame.height - start_y);
    if width == 0 || height == 0 {
        return Err(CaptureError::Wayland(
            "Requested capture region resolved to zero pixels".to_string(),
        ));
    }

    let bytes_per_pixel = frame.format.bytes_per_pixel();
    let src_stride = frame.width as usize * bytes_per_pixel;
    let row_bytes = width as usize * bytes_per_pixel;
    let mut data = Vec::with_capacity(row_bytes * height as usize);

    for row in 0..height as usize {
        let src_start =
            ((start_y as usize + row) * src_stride) + start_x as usize * bytes_per_pixel;
        let src_end = src_start + row_bytes;
        data.extend_from_slice(&frame.data[src_start..src_end]);
    }

    Ok(CapturedFrame {
        width,
        height,
        format: frame.format,
        data,
        timestamp: frame.timestamp,
        frame_number: frame.frame_number,
        capture_latency_us: frame.capture_latency_us,
    })
}

fn encode_from_rgba(rgba: &[u8], width: u32, target: PixelFormat) -> Vec<u8> {
    match target {
        PixelFormat::Rgba8888 => rgba.to_vec(),
        PixelFormat::Bgra8888 => {
            let mut bgra = Vec::with_capacity(rgba.len());
            for chunk in rgba.chunks_exact(4) {
                bgra.push(chunk[2]);
                bgra.push(chunk[1]);
                bgra.push(chunk[0]);
                bgra.push(chunk[3]);
            }
            bgra
        }
        PixelFormat::Rgb888 => {
            let mut rgb =
                Vec::with_capacity((width as usize * 3) * (rgba.len() / (width as usize * 4)));
            for chunk in rgba.chunks_exact(4) {
                rgb.push(chunk[0]);
                rgb.push(chunk[1]);
                rgb.push(chunk[2]);
            }
            rgb
        }
        PixelFormat::Bgr888 => {
            let mut bgr =
                Vec::with_capacity((width as usize * 3) * (rgba.len() / (width as usize * 4)));
            for chunk in rgba.chunks_exact(4) {
                bgr.push(chunk[2]);
                bgr.push(chunk[1]);
                bgr.push(chunk[0]);
            }
            bgr
        }
    }
}

fn convert_frame_format(frame: CapturedFrame, target: PixelFormat) -> CapturedFrame {
    if frame.format == target {
        return frame;
    }

    let rgba = frame.to_rgba();
    let data = encode_from_rgba(&rgba, frame.width, target);
    CapturedFrame {
        width: frame.width,
        height: frame.height,
        format: target,
        data,
        timestamp: frame.timestamp,
        frame_number: frame.frame_number,
        capture_latency_us: frame.capture_latency_us,
    }
}

fn finalize_frame(
    frame: &lamco_pipewire::VideoFrame,
    frame_number: u64,
    config: &CaptureConfig,
) -> Result<CapturedFrame, CaptureError> {
    let frame = normalize_pipewire_frame(frame, frame_number)?;
    let frame = match config.region {
        Some(region) => crop_frame(frame, region)?,
        None => frame,
    };
    Ok(convert_frame_format(frame, config.pixel_format))
}

fn notify_startup(
    ready_tx: &mut Option<oneshot::Sender<Result<(), CaptureError>>>,
    result: Result<(), CaptureError>,
) {
    if let Some(tx) = ready_tx.take() {
        let _ = tx.send(result);
    }
}

fn destroy_stream(manager: &PipeWireThreadManager, stream_id: u32) {
    let (response_tx, response_rx) = std_mpsc::sync_channel(1);
    if manager
        .send_command(PipeWireThreadCommand::DestroyStream {
            stream_id,
            response_tx,
        })
        .is_ok()
    {
        let _ = response_rx.recv_timeout(Duration::from_secs(2));
    }
}

fn run_pipewire_capture_loop(
    capture_context: PortalCaptureContext,
    config: CaptureConfig,
    stop_flag: Arc<AtomicBool>,
    tx: mpsc::Sender<CapturedFrame>,
    mut ready_tx: Option<oneshot::Sender<Result<(), CaptureError>>>,
) {
    let stream_id = 1u32;
    let stream_config = build_stream_config(&capture_context, &config);
    let node_id = capture_context.stream.pipewire_node_id;
    let pipewire_fd = capture_context.pipewire_fd.into_raw_fd();

    let mut manager = match PipeWireThreadManager::new(pipewire_fd) {
        Ok(manager) => manager,
        Err(err) => {
            notify_startup(
                &mut ready_tx,
                Err(CaptureError::Portal(format!(
                    "PipeWire thread initialization failed: {}",
                    err
                ))),
            );
            return;
        }
    };

    let (response_tx, response_rx) = std_mpsc::sync_channel(1);
    if let Err(err) = manager.send_command(PipeWireThreadCommand::CreateStream {
        stream_id,
        node_id,
        config: stream_config,
        response_tx,
    }) {
        notify_startup(
            &mut ready_tx,
            Err(CaptureError::Portal(format!(
                "Failed to request PipeWire stream creation: {}",
                err
            ))),
        );
        let _ = manager.shutdown();
        return;
    }

    match response_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            notify_startup(
                &mut ready_tx,
                Err(CaptureError::Portal(format!(
                    "PipeWire stream creation failed: {}",
                    err
                ))),
            );
            let _ = manager.shutdown();
            return;
        }
        Err(err) => {
            notify_startup(
                &mut ready_tx,
                Err(CaptureError::Portal(format!(
                    "Timed out waiting for PipeWire stream creation: {}",
                    err
                ))),
            );
            let _ = manager.shutdown();
            return;
        }
    }

    let first_frame_deadline = std::time::Instant::now() + FIRST_FRAME_TIMEOUT;
    let mut last_frame_at: Option<std::time::Instant> = None;
    let mut frame_number = 0u64;
    let mut startup_notified = false;

    while !stop_flag.load(Ordering::SeqCst) {
        for event in manager.drain_state_events() {
            if let PwStreamState::Error(message) = event.state {
                let error = CaptureError::Portal(format!(
                    "PipeWire stream {} entered error state: {}",
                    event.stream_id, message
                ));
                if !startup_notified {
                    notify_startup(&mut ready_tx, Err(error));
                }
                destroy_stream(&manager, stream_id);
                let _ = manager.shutdown();
                return;
            }
        }

        match manager.recv_frame_timeout(Duration::from_millis(250)) {
            Some(frame) => {
                frame_number += 1;
                last_frame_at = Some(std::time::Instant::now());

                match finalize_frame(&frame, frame_number, &config) {
                    Ok(captured) => {
                        if !startup_notified {
                            notify_startup(&mut ready_tx, Ok(()));
                            startup_notified = true;
                        }
                        if tx.blocking_send(captured).is_err() {
                            break;
                        }
                    }
                    Err(err) => {
                        tracing::warn!("Wayland PipeWire frame rejected: {}", err);
                    }
                }
            }
            None => {
                if !startup_notified && std::time::Instant::now() >= first_frame_deadline {
                    notify_startup(
                        &mut ready_tx,
                        Err(CaptureError::Portal(
                            "PipeWire stream never delivered a real frame before startup timeout"
                                .to_string(),
                        )),
                    );
                    destroy_stream(&manager, stream_id);
                    let _ = manager.shutdown();
                    return;
                }

                if let Some(last_frame_at) = last_frame_at {
                    if last_frame_at.elapsed() >= FRAME_STALL_TIMEOUT {
                        tracing::warn!(
                            "Wayland PipeWire stream stalled for {:?}; failing closed",
                            FRAME_STALL_TIMEOUT
                        );
                        break;
                    }
                }
            }
        }
    }

    if !startup_notified {
        notify_startup(
            &mut ready_tx,
            Err(CaptureError::Portal(
                "Wayland capture stopped before the first real frame was confirmed".to_string(),
            )),
        );
    }

    destroy_stream(&manager, stream_id);
    let _ = manager.shutdown();
}

#[async_trait::async_trait]
impl CaptureBackend for WaylandCapture {
    async fn initialize(&mut self) -> Result<(), CaptureError> {
        if !DisplayServer::detect().is_wayland() {
            return Err(CaptureError::Wayland("Not running on Wayland".to_string()));
        }
        self.state = CaptureState::Ready;
        Ok(())
    }

    async fn get_screens(&self) -> Result<Vec<ScreenInfo>, CaptureError> {
        if self.state == CaptureState::Uninitialized {
            return Err(CaptureError::NotInitialized);
        }

        if let Ok(context) = active_portal_call_context().await {
            return Ok(vec![portal_screen_info(
                context.stream_node_id,
                context.stream.width.max(1),
                context.stream.height.max(1),
            )]);
        }

        Ok(vec![portal_screen_info(0, 1920, 1080)])
    }

    async fn start(
        &mut self,
        config: &CaptureConfig,
    ) -> Result<mpsc::Receiver<CapturedFrame>, CaptureError> {
        if self.state == CaptureState::Uninitialized {
            return Err(CaptureError::NotInitialized);
        }
        if self.state == CaptureState::Capturing {
            return Err(CaptureError::AlreadyCapturing);
        }

        let session = ensure_runtime_portal_session(config.capture_cursor)
            .await
            .map_err(map_portal_error)?;
        let capture_context = active_portal_capture_context()
            .await
            .map_err(map_portal_error)?;

        if let Some(screen_id) = config.screen_id {
            let active_id = session.stream.pipewire_node_id;
            if screen_id != active_id {
                return Err(CaptureError::Wayland(format!(
                    "Requested screen {} does not match the active persistent output {}",
                    screen_id, active_id
                )));
            }
        }

        self.config = Some(config.clone());
        let (tx, rx) = mpsc::channel(config.target_fps.max(1) as usize * 2);
        let (ready_tx, ready_rx) = oneshot::channel();

        self.stop_flag.store(false, Ordering::SeqCst);
        self.state = CaptureState::Capturing;

        let stop_flag = Arc::clone(&self.stop_flag);
        let capture_config = config.clone();
        let task = tokio::task::spawn_blocking(move || {
            run_pipewire_capture_loop(
                capture_context,
                capture_config,
                stop_flag,
                tx,
                Some(ready_tx),
            );
        });

        match tokio::time::timeout(FIRST_FRAME_TIMEOUT + Duration::from_secs(1), ready_rx).await {
            Ok(Ok(Ok(()))) => {
                self.capture_task = Some(task);
                Ok(rx)
            }
            Ok(Ok(Err(err))) => {
                self.state = CaptureState::Error;
                self.stop_flag.store(true, Ordering::SeqCst);
                task.abort();
                let _ = task.await;
                Err(err)
            }
            Ok(Err(_)) => {
                self.state = CaptureState::Error;
                self.stop_flag.store(true, Ordering::SeqCst);
                task.abort();
                let _ = task.await;
                Err(CaptureError::Portal(
                    "Wayland capture initialization channel closed unexpectedly".to_string(),
                ))
            }
            Err(_) => {
                self.state = CaptureState::Error;
                self.stop_flag.store(true, Ordering::SeqCst);
                task.abort();
                let _ = task.await;
                Err(CaptureError::Portal(
                    "Timed out waiting for the first real PipeWire frame".to_string(),
                ))
            }
        }
    }

    async fn stop(&mut self) -> Result<(), CaptureError> {
        self.stop_flag.store(true, Ordering::SeqCst);
        if let Some(task) = self.capture_task.take() {
            let _ = task.await;
        }
        self.state = CaptureState::Stopped;
        Ok(())
    }

    async fn pause(&mut self) -> Result<(), CaptureError> {
        if self.state != CaptureState::Capturing {
            return Err(CaptureError::Wayland("Not capturing".to_string()));
        }
        self.stop_flag.store(true, Ordering::SeqCst);
        self.state = CaptureState::Paused;
        Ok(())
    }

    async fn resume(&mut self) -> Result<(), CaptureError> {
        if self.state != CaptureState::Paused {
            return Err(CaptureError::Wayland("Not paused".to_string()));
        }
        self.state = CaptureState::Ready;
        let config = self.config.clone().ok_or(CaptureError::NotInitialized)?;
        let _ = self.start(&config).await?;
        Ok(())
    }

    fn state(&self) -> CaptureState {
        self.state
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::Wayland
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wayland_capture_creation() {
        let capture = WaylandCapture::new();
        assert_eq!(capture.state(), CaptureState::Uninitialized);
        assert_eq!(capture.display_server(), DisplayServer::Wayland);
    }

    #[test]
    fn test_crop_frame_rejects_out_of_bounds_origin() {
        let frame = CapturedFrame {
            width: 4,
            height: 4,
            format: PixelFormat::Bgra8888,
            data: vec![0; 4 * 4 * 4],
            timestamp: 0,
            frame_number: 1,
            capture_latency_us: 0,
        };
        let result = crop_frame(
            frame,
            CaptureRegion {
                x: 10,
                y: 10,
                width: 1,
                height: 1,
            },
        );
        assert!(result.is_err());
    }
}
