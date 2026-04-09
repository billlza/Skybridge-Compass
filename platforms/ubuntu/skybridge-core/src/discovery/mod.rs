//! Device Discovery Module
//!
//! Provides mDNS-based device discovery compatible with macOS/Android.
//! Future support planned for Bluetooth LE and Wi-Fi Direct.

#![allow(missing_docs)]

mod manager;
mod mdns;
mod types;

pub use manager::{DeviceDiscoveryManager, DiscoveryConfig};
pub use mdns::SERVICE_TYPE;
pub use types::{DeviceCapability, DiscoveredDevice, Platform};
