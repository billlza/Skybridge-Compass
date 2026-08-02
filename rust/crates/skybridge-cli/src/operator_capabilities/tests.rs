use super::*;

#[test]
fn operator_capability_contract_covers_requested_surface_without_fake_success() {
    let capabilities = operator_capabilities();
    let ids = capabilities
        .iter()
        .map(|capability| capability.id)
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(ids.len(), capabilities.len());

    for required in [
        "crossnet.preflight",
        "crossnet.status.snapshot",
        "crossnet.settings.snapshot",
        "device.discovery.nearby",
        "remote_desktop.contract",
        "remote_desktop.status",
        "remote_desktop.resolution_contract",
        "remote_desktop.resolutions.list",
        "remote_desktop.media.doctor",
    ] {
        let capability = capabilities
            .iter()
            .find(|capability| capability.id == required)
            .expect("requested read-only capability must be declared");
        assert_eq!(capability.status, OperatorCapabilityStatus::ReadOnly);
        assert!(
            !capability.authority_boundary.trim().is_empty(),
            "{required} must declare its authority boundary"
        );
        assert!(
            !capability.verification_gate.trim().is_empty(),
            "{required} must declare its verification gate"
        );
    }

    let preflight = capabilities
        .iter()
        .find(|capability| capability.id == "crossnet.preflight")
        .expect("crossnet preflight capability must be declared");
    assert_eq!(preflight.status, OperatorCapabilityStatus::ReadOnly);
    assert_eq!(
        preflight.runtime_target,
        OperatorRuntimeTarget::MacAppRuntime
    );
    assert_eq!(preflight.control_effect, OperatorControlEffect::ReadOnly);
    assert!(preflight.command.contains("crossnet preflight"));
    assert!(
        preflight.authority_boundary.contains("Mac app")
            && preflight.authority_boundary.contains("does not")
            && preflight.authority_boundary.contains("iOS runtime"),
        "crossnet.preflight must stay Mac-only and read-only"
    );

    let status_snapshot = capabilities
        .iter()
        .find(|capability| capability.id == "crossnet.status.snapshot")
        .expect("crossnet status snapshot capability must be declared");
    assert_eq!(status_snapshot.status, OperatorCapabilityStatus::ReadOnly);
    assert_eq!(
        status_snapshot.runtime_target,
        OperatorRuntimeTarget::MacAppRuntime
    );
    assert_eq!(
        status_snapshot.control_effect,
        OperatorControlEffect::ReadOnly
    );
    assert!(
        status_snapshot
            .authority_boundary
            .contains("redacted session_ref")
            && status_snapshot.authority_boundary.contains("does not")
            && status_snapshot.authority_boundary.contains("iOS runtime"),
        "crossnet.status.snapshot must stay Mac-only, read-only, and redacted"
    );

    let settings_snapshot = capabilities
        .iter()
        .find(|capability| capability.id == "crossnet.settings.snapshot")
        .expect("crossnet settings snapshot capability must be declared");
    assert_eq!(settings_snapshot.status, OperatorCapabilityStatus::ReadOnly);
    assert_eq!(
        settings_snapshot.runtime_target,
        OperatorRuntimeTarget::MacAppRuntime
    );
    assert_eq!(
        settings_snapshot.control_effect,
        OperatorControlEffect::ReadOnly
    );
    assert!(
        settings_snapshot.authority_boundary.contains("allowlisted")
            && settings_snapshot.authority_boundary.contains("non-secret")
            && settings_snapshot
                .authority_boundary
                .contains("does not write UserDefaults")
            && settings_snapshot.authority_boundary.contains("iOS runtime"),
        "crossnet.settings.snapshot must stay allowlisted, read-only, and Mac-only"
    );

    let settings_set = capabilities
        .iter()
        .find(|capability| capability.id == "crossnet.settings.set")
        .expect("crossnet settings set capability must be declared");
    // The handler is implemented and enabled, so `planned` would deny a live
    // code path; but no live signed-app socket smoke has been captured, so
    // `available` would claim absent proof. Both directions stay guarded.
    assert_eq!(
        settings_set.status,
        OperatorCapabilityStatus::PendingLiveProof
    );
    assert_eq!(
        settings_set.runtime_target,
        OperatorRuntimeTarget::MacAppRuntime
    );
    assert_eq!(
        settings_set.control_effect,
        OperatorControlEffect::MacRuntimeMutation
    );
    assert!(
        settings_set.authority_boundary.contains("typed allowlist")
            && settings_set
                .authority_boundary
                .contains("setting_runtime_apply_failed")
            && settings_set.authority_boundary.contains("fails closed")
            && settings_set.authority_boundary.contains("pqc.*")
            && settings_set
                .authority_boundary
                .contains("live signed-app socket smoke"),
        "crossnet.settings.set must declare its allowlist, read-back failure mode, pqc exclusion, and missing live proof"
    );
    assert!(
        !settings_set.command.contains("planned/"),
        "crossnet.settings.set is implemented, so its command must not be labelled planned"
    );

    let status_watch = capabilities
        .iter()
        .find(|capability| capability.id == "crossnet.status.watch")
        .expect("crossnet status watch capability must be declared");
    assert_eq!(status_watch.status, OperatorCapabilityStatus::Planned);
    assert_eq!(
        status_watch.runtime_target,
        OperatorRuntimeTarget::MacAppRuntime
    );
    assert_eq!(
        status_watch.control_effect,
        OperatorControlEffect::PlannedFailClosed
    );
    assert!(
        status_watch
            .authority_boundary
            .contains("watch_not_supported")
            && status_watch.authority_boundary.contains("fail-closed"),
        "crossnet.status.watch must keep the fail-closed stream gate visible"
    );

    for required in ["crossnet.host", "crossnet.connect", "crossnet.disconnect"] {
        let capability = capabilities
            .iter()
            .find(|capability| capability.id == required)
            .expect("app-bound crossnet capability must be declared");
        assert_eq!(capability.status, OperatorCapabilityStatus::Planned);
        assert_eq!(
            capability.runtime_target,
            OperatorRuntimeTarget::MacAppRuntime
        );
        assert_eq!(
            capability.control_effect,
            OperatorControlEffect::MacMutationNotEnabled
        );
        assert!(
            capability.command.contains("app-bound"),
            "{required} must advertise the Mac app authority boundary"
        );
        assert!(
            capability.authority_boundary.contains("Mac-only")
                && capability.authority_boundary.contains("signed Mac app")
                && capability.authority_boundary.contains("live socket smoke"),
            "{required} must keep the Mac-only signed-app smoke gate visible"
        );
    }

    let navigation = capabilities
        .iter()
        .find(|capability| capability.id == "crossnet.navigation")
        .expect("Mac navigation boundary must be declared");
    assert_eq!(navigation.status, OperatorCapabilityStatus::Planned);
    assert_eq!(
        navigation.control_effect,
        OperatorControlEffect::MacMutationNotEnabled
    );
    assert!(navigation.command.contains("<dashboard|settings>"));
    assert!(
        navigation
            .authority_boundary
            .contains("injected navigation coordinator")
            && navigation
                .authority_boundary
                .contains("global notifications")
            && navigation
                .authority_boundary
                .contains("direct view-state writes")
    );

    let code_create = capabilities
        .iter()
        .find(|capability| capability.id == "native.code.create")
        .expect("native code creation capability must be declared");
    assert_eq!(code_create.status, OperatorCapabilityStatus::Available);
    assert_eq!(
        code_create.runtime_target,
        OperatorRuntimeTarget::NativeHeadlessStateDir
    );
    assert_eq!(
        code_create.control_effect,
        OperatorControlEffect::NativeMutation
    );
    assert!(code_create.authority_boundary.contains("does not"));

    let native_connect = capabilities
        .iter()
        .find(|capability| capability.id == "native.connect")
        .expect("native connect capability must be declared");
    assert_eq!(
        native_connect.status,
        OperatorCapabilityStatus::PendingLiveProof
    );
    assert_eq!(
        native_connect.runtime_target,
        OperatorRuntimeTarget::AgentOwnedRegistry
    );
    assert_eq!(
        native_connect.control_effect,
        OperatorControlEffect::NativeMutation
    );
    assert!(
        native_connect
            .authority_boundary
            .contains("active runtime lock")
            && native_connect
                .authority_boundary
                .contains("identity-bound HandshakeComplete")
            && native_connect.authority_boundary.contains("IP")
            && native_connect.authority_boundary.contains("features")
            && native_connect
                .authority_boundary
                .contains("authenticated SBWC")
            && native_connect.authority_boundary.contains("selected ICE")
            && native_connect
                .authority_boundary
                .contains("fresh authenticated SBWC")
            && native_connect
                .authority_boundary
                .contains("direct-or-relay IP semantics")
            && native_connect.authority_boundary.contains("does not")
            && native_connect
                .authority_boundary
                .contains("real-device cross-platform handshake")
    );

    let active_scan = capabilities
        .iter()
        .find(|capability| capability.id == "device.discovery.active_scan")
        .expect("active nearby scan capability must be declared");
    assert_eq!(active_scan.status, OperatorCapabilityStatus::ReadOnly);
    assert_eq!(
        active_scan.runtime_target,
        OperatorRuntimeTarget::NativeHeadlessStateDir
    );
    assert!(
        active_scan
            .command
            .contains("device discover --nearby --scan")
            && active_scan.command.contains("--show-addresses")
            && active_scan
                .authority_boundary
                .contains("bounded foreground mDNS scan")
            && active_scan
                .authority_boundary
                .contains("advertised_unverified")
            && active_scan.authority_boundary.contains("persisted=false")
    );

    let send = capabilities
        .iter()
        .find(|capability| capability.id == "file.transfer.send")
        .expect("file send capability must be declared");
    assert_eq!(send.status, OperatorCapabilityStatus::PendingLiveProof);
    assert_eq!(send.control_effect, OperatorControlEffect::NativeMutation);
    assert!(send.command.contains("--session-id"));
    assert!(send.command.contains("--detach"));
    assert!(
        send.owner_module
            .contains("FileTransferControlRequestRegistry")
    );
    assert!(
        send.authority_boundary.contains("TransferCompleted")
            && send
                .authority_boundary
                .contains("verified matching SHA-256 receipt")
            && send.authority_boundary.contains("request registration")
            && send.authority_boundary.contains("never agent observation")
            && send.authority_boundary.contains("never transfer success")
            && send
                .authority_boundary
                .contains("real-device cross-platform file-transfer")
    );

    let receive = capabilities
        .iter()
        .find(|capability| capability.id == "file.transfer.receive")
        .expect("file receive capability must be declared");
    assert_eq!(receive.status, OperatorCapabilityStatus::PendingLiveProof);
    assert_eq!(
        receive.control_effect,
        OperatorControlEffect::NativeMutation
    );
    assert!(
        receive.command.contains("--list")
            && receive.command.contains("--accept")
            && receive.command.contains("--reject")
    );
    assert!(
        receive.authority_boundary.contains("applied=false")
            && receive
                .authority_boundary
                .contains("stable authenticated peer device id")
            && receive
                .authority_boundary
                .contains("allocates staging/storage only after approval")
            && receive
                .authority_boundary
                .contains("real-device cross-platform inbound transfer")
    );

    for required in [
        "remote_desktop.start",
        "remote_desktop.stop",
        "remote_desktop.resolution.set",
        "remote_desktop.fps.set",
    ] {
        let capability = capabilities
            .iter()
            .find(|capability| capability.id == required)
            .expect("unavailable capability must be declared");
        assert_eq!(capability.status, OperatorCapabilityStatus::Unavailable);
        assert_eq!(
            capability.control_effect,
            OperatorControlEffect::UnavailableFailClosed
        );
        assert!(
            capability.command.contains("unavailable/fail-closed"),
            "{required} must not imply live application"
        );
        assert!(
            !capability.authority_boundary.trim().is_empty(),
            "{required} must declare its authority boundary"
        );
        assert!(
            !capability.verification_gate.trim().is_empty(),
            "{required} must declare its verification gate"
        );
    }
}

#[test]
fn operator_capability_matrix_keeps_ios_out_of_rust_runtime_control() {
    for capability in operator_capabilities() {
        for field in [
            capability.id,
            capability.command,
            capability.owner_module,
            capability.authority_boundary,
            capability.verification_gate,
        ] {
            assert!(
                !field.contains("ios_app_runtime"),
                "{} must not introduce an iOS Rust CLI runtime target",
                capability.id
            );
        }

        if capability.runtime_target == OperatorRuntimeTarget::MacAppRuntime {
            assert!(
                capability
                    .owner_module
                    .contains("Mac OperatorControlServer"),
                "{} must keep Mac GUI authority behind the app-owned OperatorControl server",
                capability.id
            );
        }

        if capability.control_effect == OperatorControlEffect::MacMutationNotEnabled {
            assert_eq!(
                capability.status,
                OperatorCapabilityStatus::Planned,
                "{} must not claim an enabled Mac GUI mutation before signed-app runtime proof",
                capability.id
            );
        }

        // A verb that really mutates the Mac runtime may only be reported as
        // proven (`available`) or explicitly unproven (`pending_live_proof`).
        if capability.control_effect == OperatorControlEffect::MacRuntimeMutation {
            assert!(
                matches!(
                    capability.status,
                    OperatorCapabilityStatus::Available
                        | OperatorCapabilityStatus::PendingLiveProof
                ),
                "{} performs a live Mac runtime mutation, so it must be available or pending_live_proof",
                capability.id
            );
            assert!(
                capability
                    .verification_gate
                    .contains("live signed-app socket smoke"),
                "{} must keep a live signed-app socket smoke gate",
                capability.id
            );
        }

        // `pending_live_proof` is only honest while the proof is genuinely
        // outstanding, so it must name the live evidence it still needs.
        if capability.status == OperatorCapabilityStatus::PendingLiveProof {
            assert!(
                capability
                    .authority_boundary
                    .contains("live signed-app socket smoke")
                    || capability
                        .authority_boundary
                        .contains("real-device cross-platform"),
                "{} must state which live evidence is still missing",
                capability.id
            );
        }
    }
}

#[test]
fn operator_capability_contract_renders_text_and_json() -> Result<()> {
    print_operator_capabilities(false)?;
    print_operator_capabilities(true)
}
