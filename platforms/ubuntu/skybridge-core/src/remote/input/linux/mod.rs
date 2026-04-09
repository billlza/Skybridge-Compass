//! Linux-specific input implementations
//!
//! Provides X11 input via XTest and Wayland input via RemoteDesktop portal.

mod wayland;
mod x11;

pub use wayland::WaylandInputHandler;
pub use x11::X11InputHandler;
