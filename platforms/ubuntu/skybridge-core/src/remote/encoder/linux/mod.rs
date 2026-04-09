//! Linux-specific video encoder implementations
//!
//! Provides OpenH264 software encoder and VAAPI hardware encoder.

mod openh264;
mod vaapi;

pub use openh264::OpenH264Encoder;
pub use vaapi::VaapiEncoder;

// SoftwareEncoder is an alias for OpenH264Encoder
pub type SoftwareEncoder = OpenH264Encoder;
