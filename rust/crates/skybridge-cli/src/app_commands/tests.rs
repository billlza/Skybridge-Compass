use super::*;
use crate::app_control_client::AppearanceMode;
use crate::cli_args::{AppRemoteDesktopArgs, AppSettingSetArgs, AppSettingsArgs};
use std::collections::VecDeque;

struct Scripted {
    replies: VecDeque<(&'static str, AppResult<Value>)>,
    calls: Vec<(&'static str, Value)>,
}
impl Scripted {
    fn new(replies: Vec<(&'static str, AppResult<Value>)>) -> Self {
        Self {
            replies: replies.into(),
            calls: vec![],
        }
    }
}
impl AppTransport for Scripted {
    async fn call(&mut self, method: &'static str, params: Value) -> AppResult<Value> {
        self.calls.push((method, params));
        let (expected, response) = self
            .replies
            .pop_front()
            .expect("unexpected extra request or retry");
        assert_eq!(method, expected);
        response
    }
}
fn settings(mode: &str) -> Value {
    json!({"settings":{"appearance.mode":{"value":mode,"observed_value":mode}},"persistence":"persisted"})
}
fn host(generation: u64, enabled: bool) -> Value {
    json!({"generation":generation,"enabled":enabled,"state":if enabled {"listening"}else{"stopped"},"session_count":0,"frames_sent":0})
}
fn status(generation: u64, enabled: bool, capabilities: &[&str]) -> Value {
    json!({"app_pid":42,"runtime_id":"windows_app_runtime","host":host(generation,enabled),"settings":settings("dark")["settings"],"capabilities":capabilities})
}
fn setting_command() -> AppSubcommand {
    AppSubcommand::Settings(AppSettingsArgs {
        command: Some(AppSettingsSubcommand::Set(AppSettingSetArgs {
            id: "appearance.mode".into(),
            value: AppearanceMode::Dark,
        })),
    })
}
fn mutation() -> Value {
    json!({"setting_id":"appearance.mode","requested_value":"dark","observed_value":"dark","persisted":true,"effect":"live_app_theme"})
}
fn remote(command: AppRemoteDesktopSubcommand) -> AppSubcommand {
    AppSubcommand::RemoteDesktop(AppRemoteDesktopArgs { command })
}

#[tokio::test]
async fn settings_success_requires_advertisement_and_independent_persisted_live_readback() {
    let preflight = status(
        0,
        false,
        &["app.status", "app.settings", "app.settings.set"],
    );
    let mut correct = Scripted::new(vec![
        ("app.status", Ok(preflight.clone())),
        ("app.settings.set", Ok(mutation())),
        ("app.settings", Ok(settings("dark"))),
    ]);
    let result = execute_target(setting_command(), 42, &mut correct)
        .await
        .unwrap();
    assert_eq!(result.control_effect, "live_app_theme");
    assert_eq!(correct.calls.len(), 3);
    assert_eq!(
        correct.calls[1].1,
        json!({"id":"appearance.mode","value":"dark"})
    );
    for result in [
        Ok(settings("light")),
        Err(AppControlError::new(
            "app_response_unconfirmed",
            "readback connection closed",
        )),
    ] {
        let mut stale = Scripted::new(vec![
            ("app.status", Ok(preflight.clone())),
            ("app.settings.set", Ok(mutation())),
            ("app.settings", result),
        ]);
        assert!(
            execute_target(setting_command(), 42, &mut stale)
                .await
                .is_err()
        );
        assert_eq!(stale.calls.len(), 3);
    }
    let mut missing_persistence = mutation();
    missing_persistence["persisted"] = false.into();
    let mut rejected = Scripted::new(vec![
        ("app.status", Ok(preflight)),
        ("app.settings.set", Ok(missing_persistence)),
    ]);
    assert!(
        execute_target(setting_command(), 42, &mut rejected)
            .await
            .is_err()
    );
    assert_eq!(rejected.calls.len(), 2);
}

#[tokio::test]
async fn host_mutations_require_advertisement_exact_generation_and_independent_status() {
    let start_preflight = status(0, false, &["app.status", "app.remote_desktop.start"]);
    let mut started = Scripted::new(vec![
        ("app.status", Ok(start_preflight.clone())),
        ("app.remote_desktop.start", Ok(host(7, true))),
        ("app.status", Ok(status(7, true, &["app.status"]))),
    ]);
    let result = execute_target(
        remote(AppRemoteDesktopSubcommand::Start {
            interface_ref: "interface-1".into(),
        }),
        42,
        &mut started,
    )
    .await
    .unwrap();
    assert_eq!(result.control_effect, "host_listener_enabled");
    assert_eq!(result.result["peer_or_frame_proof"], false);
    let mut failed = status(7, true, &["app.status"]);
    failed["host"]["state"] = "failed".into();
    for observed in [
        status(8, true, &["app.status"]),
        status(7, false, &["app.status"]),
        failed,
    ] {
        let mut changed = Scripted::new(vec![
            ("app.status", Ok(start_preflight.clone())),
            ("app.remote_desktop.start", Ok(host(7, true))),
            ("app.status", Ok(observed)),
        ]);
        assert!(
            execute_target(
                remote(AppRemoteDesktopSubcommand::Start {
                    interface_ref: "interface-1".into()
                }),
                42,
                &mut changed
            )
            .await
            .is_err()
        );
        assert_eq!(changed.calls.len(), 3);
    }
    for state in ["failed", "request_registered"] {
        let mut ack = host(7, true);
        ack["state"] = state.into();
        let mut wrong = Scripted::new(vec![
            ("app.status", Ok(start_preflight.clone())),
            ("app.remote_desktop.start", Ok(ack)),
        ]);
        assert!(
            execute_target(
                remote(AppRemoteDesktopSubcommand::Start {
                    interface_ref: "interface-1".into()
                }),
                42,
                &mut wrong
            )
            .await
            .is_err()
        );
        assert_eq!(wrong.calls.len(), 2);
    }
    let stop_preflight = status(7, true, &["app.status", "app.remote_desktop.stop"]);
    let mut stopped = Scripted::new(vec![
        ("app.status", Ok(stop_preflight.clone())),
        ("app.remote_desktop.stop", Ok(host(7, false))),
        ("app.status", Ok(status(7, false, &["app.status"]))),
    ]);
    assert_eq!(
        execute_target(
            remote(AppRemoteDesktopSubcommand::Stop { generation: 7 }),
            42,
            &mut stopped
        )
        .await
        .unwrap()
        .control_effect,
        "host_listener_stopped"
    );
    let mut wrong = Scripted::new(vec![
        ("app.status", Ok(stop_preflight)),
        ("app.remote_desktop.stop", Ok(host(8, false))),
    ]);
    assert!(
        execute_target(
            remote(AppRemoteDesktopSubcommand::Stop { generation: 7 }),
            42,
            &mut wrong
        )
        .await
        .is_err()
    );
}

#[tokio::test]
async fn missing_or_empty_capabilities_never_send_a_mutation() {
    for capabilities in [vec![], vec!["app.status"]] {
        for command in [
            setting_command(),
            remote(AppRemoteDesktopSubcommand::Start {
                interface_ref: "if-1".into(),
            }),
            remote(AppRemoteDesktopSubcommand::Stop { generation: 7 }),
        ] {
            let mut transport =
                Scripted::new(vec![("app.status", Ok(status(7, false, &capabilities)))]);
            assert_eq!(
                execute_target(command, 42, &mut transport)
                    .await
                    .unwrap_err()
                    .code,
                "app_method_unavailable"
            );
            assert_eq!(transport.calls.len(), 1);
        }
    }
}

#[tokio::test]
async fn read_commands_validate_app_identity_and_explicit_result_shapes() {
    let mut read = Scripted::new(vec![("app.status", Ok(status(0, false, &["app.status"])))]);
    assert_eq!(
        execute_target(AppSubcommand::Status, 42, &mut read)
            .await
            .unwrap()
            .control_effect,
        "read_only"
    );
    let mut wrong = Scripted::new(vec![("app.status", Ok(status(0, false, &["app.status"])))]);
    assert!(
        execute_target(AppSubcommand::Status, 43, &mut wrong)
            .await
            .is_err()
    );
    let mut read = Scripted::new(vec![("app.settings", Ok(settings("system")))]);
    execute_target(
        AppSubcommand::Settings(AppSettingsArgs { command: None }),
        42,
        &mut read,
    )
    .await
    .unwrap();
    let mut interfaces = Scripted::new(vec![(
        "app.remote_desktop.interfaces",
        Ok(json!({"interfaces":[{"interface_ref":"if-1","name":"Wi-Fi"}]})),
    )]);
    execute_target(
        remote(AppRemoteDesktopSubcommand::Interfaces),
        42,
        &mut interfaces,
    )
    .await
    .unwrap();
    assert!(
        execute_target(AppSubcommand::Instances, 42, &mut Scripted::new(vec![]))
            .await
            .is_err()
    );
}
