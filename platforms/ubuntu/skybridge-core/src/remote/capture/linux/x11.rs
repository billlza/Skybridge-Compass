//! X11 Screen Capture Implementation
//!
//! Uses MIT-SHM extension for efficient screen capture on X11.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use x11rb::connection::Connection;
use x11rb::protocol::randr::{self, ConnectionExt as RandrExt};
use x11rb::protocol::shm::{self, ConnectionExt as ShmExt};
use x11rb::protocol::xproto::{ImageFormat, Screen};
use x11rb::rust_connection::RustConnection;

use crate::remote::capture::{
    CaptureBackend, CaptureConfig, CaptureError, CaptureRegion, CaptureState, CapturedFrame,
    DisplayServer, PixelFormat, ScreenInfo,
};

/// Shared memory segment for X11 capture
struct ShmSegment {
    /// Segment ID
    seg_id: shm::Seg,
    /// Pointer to shared memory
    addr: *mut libc::c_void,
    /// Size of segment
    size: usize,
}

impl ShmSegment {
    /// Create a new shared memory segment
    fn new(conn: &RustConnection, size: usize) -> Result<Self, CaptureError> {
        unsafe {
            // Create shared memory segment
            let shm_id = libc::shmget(libc::IPC_PRIVATE, size, libc::IPC_CREAT | 0o600);
            if shm_id < 0 {
                return Err(CaptureError::X11(format!(
                    "shmget failed: {}",
                    std::io::Error::last_os_error()
                )));
            }

            // Attach to shared memory
            let addr = libc::shmat(shm_id, std::ptr::null(), 0);
            if addr == libc::MAP_FAILED {
                libc::shmctl(shm_id, libc::IPC_RMID, std::ptr::null_mut());
                return Err(CaptureError::X11(format!(
                    "shmat failed: {}",
                    std::io::Error::last_os_error()
                )));
            }

            // Create X11 SHM segment
            let seg_id = conn
                .generate_id()
                .map_err(|e| CaptureError::X11(e.to_string()))?;
            conn.shm_attach(seg_id, shm_id as u32, false)
                .map_err(|e| CaptureError::X11(e.to_string()))?;

            // Mark for deletion when all processes detach
            libc::shmctl(shm_id, libc::IPC_RMID, std::ptr::null_mut());

            Ok(Self { seg_id, addr, size })
        }
    }

    /// Get data as slice
    fn as_slice(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.addr as *const u8, self.size) }
    }
}

impl Drop for ShmSegment {
    fn drop(&mut self) {
        unsafe {
            libc::shmdt(self.addr);
        }
    }
}

// SAFETY: ShmSegment only contains raw pointers that are valid for the lifetime
// of the segment, and the segment is only accessed from one thread at a time.
unsafe impl Send for ShmSegment {}
unsafe impl Sync for ShmSegment {}

/// X11 screen capture backend using MIT-SHM
pub struct X11Capture {
    state: CaptureState,
    config: Option<CaptureConfig>,
    connection: Option<Arc<RustConnection>>,
    screen_num: usize,
    root_window: u32,
    shm_segment: Option<ShmSegment>,
    frame_sender: Option<mpsc::Sender<CapturedFrame>>,
    stop_flag: Arc<AtomicBool>,
    capture_task: Option<tokio::task::JoinHandle<()>>,
    width: u32,
    height: u32,
    depth: u8,
}

impl X11Capture {
    /// Create a new X11 capture backend
    pub fn new() -> Self {
        Self {
            state: CaptureState::Uninitialized,
            config: None,
            connection: None,
            screen_num: 0,
            root_window: 0,
            shm_segment: None,
            frame_sender: None,
            stop_flag: Arc::new(AtomicBool::new(false)),
            capture_task: None,
            width: 0,
            height: 0,
            depth: 0,
        }
    }

    /// Get screen info from X11
    fn get_screen_info_internal(
        conn: &RustConnection,
        screen: &Screen,
    ) -> Result<Vec<ScreenInfo>, CaptureError> {
        let mut screens = Vec::new();

        // Try RandR first for multi-monitor support
        if let Ok(randr_version) = conn.randr_query_version(1, 5)
            && let Ok(version) = randr_version.reply()
            && version.major_version >= 1
            && version.minor_version >= 2
            && let Ok(resources) = conn.randr_get_screen_resources(screen.root)
            && let Ok(res) = resources.reply()
        {
            for (idx, output) in res.outputs.iter().enumerate() {
                let Ok(output_info) = conn.randr_get_output_info(*output, res.config_timestamp)
                else {
                    continue;
                };
                let Ok(info) = output_info.reply() else {
                    continue;
                };
                if info.connection != randr::Connection::CONNECTED || info.crtc == 0 {
                    continue;
                }
                let Ok(crtc_info) = conn.randr_get_crtc_info(info.crtc, res.config_timestamp)
                else {
                    continue;
                };
                let Ok(crtc) = crtc_info.reply() else {
                    continue;
                };

                let name = String::from_utf8_lossy(&info.name).to_string();
                let refresh_rate = res
                    .modes
                    .iter()
                    .find(|m| crtc.mode != 0 && m.id == crtc.mode)
                    .map(|m| {
                        if m.htotal > 0 && m.vtotal > 0 {
                            m.dot_clock as f32 / (m.htotal as f32 * m.vtotal as f32)
                        } else {
                            60.0
                        }
                    })
                    .unwrap_or(60.0);

                screens.push(ScreenInfo {
                    id: idx as u32,
                    name,
                    width: crtc.width as u32,
                    height: crtc.height as u32,
                    x: crtc.x as i32,
                    y: crtc.y as i32,
                    refresh_rate,
                    scale: 1.0,
                    is_primary: idx == 0,
                });
            }
        }

        // Fallback to basic screen info
        if screens.is_empty() {
            screens.push(ScreenInfo {
                id: 0,
                name: "X11 Display".to_string(),
                width: screen.width_in_pixels as u32,
                height: screen.height_in_pixels as u32,
                x: 0,
                y: 0,
                refresh_rate: 60.0,
                scale: 1.0,
                is_primary: true,
            });
        }

        Ok(screens)
    }

    /// Capture a single frame using SHM
    fn capture_frame_shm(
        conn: &RustConnection,
        root: u32,
        segment: &ShmSegment,
        region: Option<CaptureRegion>,
        screen_size: (u32, u32),
        depth: u8,
        frame_number: u64,
    ) -> Result<CapturedFrame, CaptureError> {
        let start = Instant::now();
        let (width, height) = screen_size;

        let (x, y, w, h) = match region {
            Some(r) => (r.x as i16, r.y as i16, r.width as u16, r.height as u16),
            None => (0, 0, width as u16, height as u16),
        };

        // Use SHM GetImage for efficient capture
        let cookie = conn
            .shm_get_image(
                root,
                x,
                y,
                w,
                h,
                !0, // plane_mask: all planes
                ImageFormat::Z_PIXMAP.into(),
                segment.seg_id,
                0, // offset
            )
            .map_err(|e| CaptureError::X11(e.to_string()))?;

        cookie
            .reply()
            .map_err(|e| CaptureError::X11(e.to_string()))?;

        let capture_latency = start.elapsed().as_micros() as u64;

        // Copy data from shared memory
        let bytes_per_pixel = if depth > 24 {
            4
        } else if depth > 16 {
            3
        } else {
            2
        };
        let data_size = w as usize * h as usize * bytes_per_pixel;
        let data = segment.as_slice()[..data_size].to_vec();

        let format = PixelFormat::Bgra8888;

        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;

        Ok(CapturedFrame {
            width: w as u32,
            height: h as u32,
            format,
            data,
            timestamp,
            frame_number,
            capture_latency_us: capture_latency,
        })
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
        // Check DISPLAY environment variable
        if std::env::var("DISPLAY").is_err() {
            return Err(CaptureError::X11("DISPLAY not set".to_string()));
        }

        // Connect to X11 server
        let (conn, screen_num) =
            RustConnection::connect(None).map_err(|e| CaptureError::X11(e.to_string()))?;

        let conn = Arc::new(conn);

        // Get screen info
        let setup = conn.setup();
        let screen = &setup.roots[screen_num];

        // Check for SHM extension
        let shm_query = conn
            .shm_query_version()
            .map_err(|e| CaptureError::X11(e.to_string()))?;
        let shm_version = shm_query
            .reply()
            .map_err(|e| CaptureError::X11(e.to_string()))?;

        if !shm_version.shared_pixmaps {
            tracing::warn!("X11 SHM shared pixmaps not available, performance may be reduced");
        }

        self.root_window = screen.root;
        self.width = screen.width_in_pixels as u32;
        self.height = screen.height_in_pixels as u32;
        self.depth = screen.root_depth;
        self.screen_num = screen_num;
        self.connection = Some(conn);
        self.state = CaptureState::Ready;

        tracing::info!(
            "X11 capture initialized: {}x{} depth={} with MIT-SHM",
            self.width,
            self.height,
            self.depth
        );
        Ok(())
    }

    async fn get_screens(&self) -> Result<Vec<ScreenInfo>, CaptureError> {
        if self.state == CaptureState::Uninitialized {
            return Err(CaptureError::NotInitialized);
        }

        let conn = self
            .connection
            .as_ref()
            .ok_or(CaptureError::NotInitialized)?;

        let setup = conn.setup();
        let screen = &setup.roots[self.screen_num];

        Self::get_screen_info_internal(conn, screen)
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

        self.config = Some(config.clone());

        let conn = self
            .connection
            .as_ref()
            .ok_or(CaptureError::NotInitialized)?
            .clone();

        // Calculate buffer size
        let (width, height) = match config.region {
            Some(ref r) => (r.width, r.height),
            None => (self.width, self.height),
        };
        let bytes_per_pixel = if self.depth > 24 {
            4
        } else if self.depth > 16 {
            3
        } else {
            2
        };
        let buffer_size = width as usize * height as usize * bytes_per_pixel;

        // Create SHM segment
        let shm_segment = ShmSegment::new(&conn, buffer_size)?;
        self.shm_segment = Some(shm_segment);

        let (tx, rx) = mpsc::channel(config.target_fps as usize * 2);
        self.frame_sender = Some(tx.clone());
        self.stop_flag.store(false, Ordering::SeqCst);
        self.state = CaptureState::Capturing;

        // Start capture loop in background
        let stop_flag = self.stop_flag.clone();
        let frame_interval = Duration::from_secs_f64(1.0 / config.target_fps as f64);
        let root = self.root_window;
        let region = config.region;
        let capture_width = self.width;
        let capture_height = self.height;
        let depth = self.depth;

        // We need to move the SHM segment to the task
        // For now, create a new segment in the task
        let task = tokio::task::spawn_blocking(move || {
            let (conn, _) = match RustConnection::connect(None) {
                Ok(c) => c,
                Err(e) => {
                    tracing::error!("Failed to connect to X11: {}", e);
                    return;
                }
            };

            let buffer_size =
                capture_width as usize * capture_height as usize * if depth > 24 { 4 } else { 3 };
            let segment = match ShmSegment::new(&conn, buffer_size) {
                Ok(s) => s,
                Err(e) => {
                    tracing::error!("Failed to create SHM segment: {}", e);
                    return;
                }
            };

            let mut frame_number = 0u64;
            let mut next_frame = Instant::now();

            while !stop_flag.load(Ordering::SeqCst) {
                let now = Instant::now();
                if now < next_frame {
                    std::thread::sleep(next_frame - now);
                }
                next_frame = Instant::now() + frame_interval;

                match Self::capture_frame_shm(
                    &conn,
                    root,
                    &segment,
                    region,
                    (capture_width, capture_height),
                    depth,
                    frame_number,
                ) {
                    Ok(frame) => {
                        if tx.blocking_send(frame).is_err() {
                            break;
                        }
                        frame_number += 1;
                    }
                    Err(e) => {
                        tracing::warn!("Frame capture failed: {}", e);
                    }
                }
            }

            // Cleanup: detach SHM
            let _ = conn.shm_detach(segment.seg_id);
        });

        self.capture_task = Some(task);

        tracing::info!("X11 screen capture started at {}fps", config.target_fps);
        Ok(rx)
    }

    async fn stop(&mut self) -> Result<(), CaptureError> {
        self.stop_flag.store(true, Ordering::SeqCst);

        if let Some(task) = self.capture_task.take() {
            let _ = task.await;
        }

        self.state = CaptureState::Stopped;
        self.frame_sender = None;

        // Cleanup SHM segment
        if let (Some(conn), Some(segment)) = (&self.connection, &self.shm_segment) {
            let _ = conn.shm_detach(segment.seg_id);
        }
        self.shm_segment = None;

        tracing::info!("X11 screen capture stopped");
        Ok(())
    }

    async fn pause(&mut self) -> Result<(), CaptureError> {
        if self.state != CaptureState::Capturing {
            return Err(CaptureError::X11("Not capturing".to_string()));
        }
        self.stop_flag.store(true, Ordering::SeqCst);
        self.state = CaptureState::Paused;
        Ok(())
    }

    async fn resume(&mut self) -> Result<(), CaptureError> {
        if self.state != CaptureState::Paused {
            return Err(CaptureError::X11("Not paused".to_string()));
        }

        if let Some(config) = self.config.clone() {
            self.state = CaptureState::Ready;
            self.start(&config).await?;
        }
        Ok(())
    }

    fn state(&self) -> CaptureState {
        self.state
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::X11
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_x11_capture_creation() {
        let capture = X11Capture::new();
        assert_eq!(capture.state(), CaptureState::Uninitialized);
        assert_eq!(capture.display_server(), DisplayServer::X11);
    }
}
