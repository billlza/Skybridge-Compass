//! UI Pages

mod dashboard;
mod devices;
mod login;
mod monitor;
mod remote;
mod settings;
mod transfers;
mod usb;

pub use dashboard::{
    AmbientSnapshot, ConnectionPhase, ConnectionUpdate, DashboardPage, DashboardStats,
    StreamingStatus,
};
pub use devices::DevicesPage;
pub use login::LoginPage;
pub use monitor::{MonitorPage, MonitorSnapshot};
pub use remote::{RemotePage, RemoteSessionSummary, RemoteSnapshot};
pub use settings::SettingsPage;
pub use transfers::TransfersPage;
pub use usb::{UsbDeviceKind, UsbDeviceSummary, UsbPage};
