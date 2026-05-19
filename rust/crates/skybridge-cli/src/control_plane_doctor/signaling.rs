use anyhow::Result;

use crate::DoctorCheck;

use super::checks::{
    check_build_fingerprint, check_probe_reachable, check_readyz, check_route_present,
    check_state_backend, first_bool, first_string, probe_body, route_present,
};
use super::{control_plane_report, signal_server_client};

pub(crate) async fn build_signaling_doctor_report(
    base_url: Option<String>,
    expected_backend: Option<&str>,
) -> Result<crate::DoctorProbeReport> {
    let signal_server = signal_server_client(base_url)?;
    let target = signal_server.base_url.clone();
    let root = signal_server.probe_json_endpoint("/").await;
    let health = signal_server.probe_json_endpoint("/health").await;
    let ready = signal_server.probe_json_endpoint("/readyz").await;
    let turn_credentials = signal_server
        .probe_json_endpoint("/api/turn/credentials")
        .await;
    let media_lease_route = signal_server.probe_media_lease_without_token().await;
    let mut checks = vec![
        check_probe_reachable("root", &root, "/"),
        check_probe_reachable("health", &health, "/health"),
        check_readyz(&ready),
        check_route_present(
            "turn_credentials_route",
            &turn_credentials,
            "/api/turn/credentials",
        ),
        check_route_present("media_lease_route", &media_lease_route, "/api/media/lease"),
    ];

    let build = first_string(
        &[probe_body(&health), probe_body(&ready), probe_body(&root)],
        "serverBuildFingerprint",
    );
    checks.push(check_build_fingerprint(build.clone()));

    let state_backend = first_string(
        &[probe_body(&health), probe_body(&ready), probe_body(&root)],
        "stateBackend",
    );
    checks.push(check_state_backend(state_backend.clone(), expected_backend));

    let supports_media = first_bool(
        &[probe_body(&health), probe_body(&ready), probe_body(&root)],
        "supportsMediaAdmissionRefresh",
    );
    let media_route_present = route_present(&media_lease_route);
    let media_ok = supports_media == Some(true) && media_route_present;
    checks.push(DoctorCheck {
        name: "media_diagnostics_supported",
        ok: media_ok,
        severity: if media_ok { "info" } else { "error" },
        detail: if media_ok {
            "health advertises media admission refresh and /api/media/lease is routable".to_owned()
        } else if supports_media != Some(true) {
            "server did not advertise media admission diagnostics support".to_owned()
        } else {
            "/api/media/lease is missing or hidden behind a bad gateway".to_owned()
        },
        server_build_fingerprint: build,
        state_backend,
        reject_reason: None,
    });

    Ok(control_plane_report(target, checks))
}
