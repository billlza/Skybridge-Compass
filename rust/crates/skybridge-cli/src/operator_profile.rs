use serde::Serialize;

/// Additive identity contract, distinct from each command's result schema.
/// Describes compiled behavior; it does not attest to a running app or peer.
#[derive(Serialize)]
pub(crate) struct OperatorProfile {
    schema_version: u32,
    implementation_id: &'static str,
    role: &'static str,
    host_platform: &'static str,
    app_runtime_control: &'static str,
    file_send: FileSendProfile,
}

#[derive(Serialize)]
struct FileSendProfile {
    default_completion: &'static str,
    default_implemented: bool,
    detached_completion: &'static str,
}

pub(crate) const fn operator_profile() -> OperatorProfile {
    OperatorProfile {
        schema_version: 1,
        implementation_id: "skybridge-cli",
        role: "product_operator",
        host_platform: std::env::consts::OS,
        app_runtime_control: if cfg!(target_os = "macos") {
            "mac_app_runtime"
        } else if cfg!(windows) {
            "windows_app_runtime"
        } else {
            "unsupported"
        },
        file_send: FileSendProfile {
            default_completion: "verified_receipt",
            default_implemented: true,
            detached_completion: "request_registered",
        },
    }
}
