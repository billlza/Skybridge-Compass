use serde::Serialize;
use serde_json::{Value, json};

use crate::app_control_client::{
    AppControlError, AppResult, AppTransport, HostSnapshot, HostState, SettingMutation,
    decode_result, encode_result, parse_interfaces, parse_settings, parse_status, validate_host,
};
use crate::cli_args::{AppRemoteDesktopSubcommand, AppSettingsSubcommand, AppSubcommand};

#[derive(Debug, Serialize)]
pub(crate) struct CommandResult {
    method: &'static str,
    control_effect: &'static str,
    result: Value,
}

fn readback_failed() -> AppControlError {
    let mut error = AppControlError::new(
        "app_mutation_unconfirmed",
        "The running app did not independently confirm the requested change",
    );
    error.mutation_unconfirmed = true;
    error
}

pub(crate) async fn execute_target<T: AppTransport>(
    command: AppSubcommand,
    pid: u32,
    transport: &mut T,
) -> AppResult<CommandResult> {
    let (method, control_effect, result) = match command {
        AppSubcommand::Instances => {
            return Err(AppControlError::new(
                "invalid_arguments",
                "instances is a process discovery command",
            ));
        }
        AppSubcommand::Status => {
            let method = "app.status";
            let result = parse_status(transport.call(method, json!({})).await?, pid)?;
            (method, "read_only", encode_result(&result)?)
        }
        AppSubcommand::Settings(settings) => match settings.command {
            None => {
                let method = "app.settings";
                let result = parse_settings(transport.call(method, json!({})).await?)?;
                (method, "read_only", encode_result(&result)?)
            }
            Some(AppSettingsSubcommand::Set(args)) => {
                let method = "app.settings.set";
                require_method(transport, pid, method).await?;
                let result: SettingMutation = decode_result(
                    transport
                        .call(method, json!({"id": args.id, "value": args.value}))
                        .await?,
                )?;
                if result.setting_id != args.id
                    || result.requested_value != args.value
                    || result.observed_value != args.value
                    || !result.persisted
                    || result.effect != "live_app_theme"
                {
                    return Err(readback_failed());
                }
                let observed = parse_settings(transport.call("app.settings", json!({})).await?)?;
                let confirmed = observed.settings.get(&args.id).is_some_and(|setting| {
                    setting.value == args.value && setting.observed_value == args.value
                });
                if !confirmed {
                    return Err(readback_failed());
                }
                (method, "live_app_theme", encode_result(&result)?)
            }
        },
        AppSubcommand::RemoteDesktop(remote) => match remote.command {
            AppRemoteDesktopSubcommand::Interfaces => {
                let method = "app.remote_desktop.interfaces";
                let result = parse_interfaces(transport.call(method, json!({})).await?)?;
                (method, "read_only", encode_result(&result)?)
            }
            AppRemoteDesktopSubcommand::Start { interface_ref } => {
                let method = "app.remote_desktop.start";
                require_method(transport, pid, method).await?;
                let host: HostSnapshot = decode_result(
                    transport
                        .call(method, json!({"interface_ref": interface_ref}))
                        .await?,
                )?;
                validate_host(&host)?;
                if !host.enabled || !host.state.is_running() {
                    return Err(readback_failed());
                }
                confirm_host(transport, pid, &host).await?;
                (
                    method,
                    "host_listener_enabled",
                    json!({"host": host, "proof_scope": "listener_state", "peer_or_frame_proof": false}),
                )
            }
            AppRemoteDesktopSubcommand::Stop { generation } => {
                let method = "app.remote_desktop.stop";
                require_method(transport, pid, method).await?;
                let host: HostSnapshot = decode_result(
                    transport
                        .call(method, json!({"generation": generation}))
                        .await?,
                )?;
                validate_host(&host)?;
                if host.enabled || host.generation != generation || host.state != HostState::Stopped
                {
                    return Err(readback_failed());
                }
                confirm_host(transport, pid, &host).await?;
                (
                    method,
                    "host_listener_stopped",
                    json!({"host": host, "proof_scope": "listener_state", "peer_or_frame_proof": false}),
                )
            }
        },
    };
    Ok(CommandResult {
        method,
        control_effect,
        result,
    })
}

async fn require_method<T: AppTransport>(
    transport: &mut T,
    pid: u32,
    method: &str,
) -> AppResult<()> {
    let status = parse_status(transport.call("app.status", json!({})).await?, pid)?;
    if !status
        .capabilities
        .iter()
        .any(|advertised| advertised == method)
    {
        return Err(AppControlError::new(
            "app_method_unavailable",
            "The selected app did not advertise the requested operation",
        ));
    }
    Ok(())
}

async fn confirm_host<T: AppTransport>(
    transport: &mut T,
    pid: u32,
    host: &HostSnapshot,
) -> AppResult<()> {
    let observed = parse_status(transport.call("app.status", json!({})).await?, pid)?;
    if observed.host.generation != host.generation
        || observed.host.enabled != host.enabled
        || (host.enabled && !observed.host.state.is_running())
        || (!host.enabled && observed.host.state != HostState::Stopped)
    {
        return Err(readback_failed());
    }
    Ok(())
}

#[cfg(windows)]
pub(crate) async fn run(command: crate::AppCommand) -> anyhow::Result<()> {
    use crate::app_control_client::{AppClient, list_instances, select_pid};
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    use std::time::Duration;

    let as_json = command.json;
    let mutation_attempted = Arc::new(AtomicBool::new(false));
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        let instances = list_instances()?;
        if matches!(command.command, AppSubcommand::Instances) {
            if command.pid.is_some() { return Err(AppControlError::new("invalid_arguments", "app instances does not accept --pid")); }
            return Ok(json!({"schema_version": 1, "success": true, "runtime_target": "windows_app_runtime", "instances": instances.into_iter().map(|pid| json!({"pid": pid})).collect::<Vec<_>>(), "pipe_readiness_observed": false}));
        }
        let pid = select_pid(&instances, command.pid)?;
        // The external marker survives cancellation after a request may have been written.
        let mut client = AppClient::new(pid, Arc::clone(&mutation_attempted));
        let outcome = execute_target(command.command, pid, &mut client).await;
        let outcome = outcome?;
        Ok(json!({"schema_version": 1, "success": true, "runtime_target": "windows_app_runtime", "app_pid": pid, "operation": outcome}))
    }).await;
    let report = match result {
        Ok(Ok(report)) => report,
        Ok(Err(mut error)) => {
            error.mutation_unconfirmed |= mutation_attempted.load(Ordering::Acquire);
            if as_json {
                crate::cli_output::write_json_failure(
                    &json!({"schema_version": 1,"success":false,"status":"failed","error":error}),
                )?;
            }
            return Err(error.into());
        }
        Err(_) => {
            let mut error = AppControlError::new(
                "app_command_deadline",
                "The app command exceeded its 30 second deadline; no written request will be retried",
            );
            error.mutation_unconfirmed = mutation_attempted.load(Ordering::Acquire);
            if as_json {
                crate::cli_output::write_json_failure(
                    &json!({"schema_version":1,"success":false,"status":"unconfirmed","error":error}),
                )?;
            }
            return Err(error.into());
        }
    };
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}

#[cfg(test)]
mod tests;
