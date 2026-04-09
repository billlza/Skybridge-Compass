//! Linux-specific screen capture implementations
//!
//! Provides X11 capture via MIT-SHM and Wayland capture via xdg-desktop-portal.

mod wayland;
mod x11;

pub use wayland::WaylandCapture;
pub use x11::X11Capture;
