use crate::{CrossnetHandshakeArgs, CrossnetHandshakeSubcommand};
use anyhow::{Result, bail};
use skybridge_crossnet_client::{HandshakeProfile, HandshakeResult, NearbyDevice};
use std::io::{self, Write};

pub(crate) async fn command(args: CrossnetHandshakeArgs) -> Result<()> {
    let (operation, scope, target, profile, reconnect, json) = match args.command {
        CrossnetHandshakeSubcommand::List(o) => ("list", "local", None, None, false, o.json),
        CrossnetHandshakeSubcommand::Status(a) => {
            let json = a.output.json;
            ("status", "local", Some(a), None, false, json)
        }
        CrossnetHandshakeSubcommand::Revoke(a) => {
            let json = a.output.json;
            ("revoke", "local", Some(a), None, false, json)
        }
        CrossnetHandshakeSubcommand::Set(a) => {
            let json = a.target.output.json;
            (
                "set",
                a.scope.wire(),
                Some(a.target),
                Some(a.profile.into()),
                a.reconnect,
                json,
            )
        }
    };
    let result = if let Some(target) = &target
        && let Some(udid) = &target.usb
    {
        let usb = skybridge_crossnet_client::HandshakeUSBTarget {
            udid: udid.clone(),
            peer_id: target
                .peer_id
                .clone()
                .ok_or_else(|| anyhow::anyhow!("missing USB peer ID"))?,
            expected_fingerprint: target
                .expected_fingerprint
                .clone()
                .ok_or_else(|| anyhow::anyhow!("missing USB fingerprint"))?,
        };
        skybridge_crossnet_client::handshake_usb(operation, scope, &usb, profile, reconnect).await?
    } else {
        skybridge_crossnet_client::handshake(
            operation,
            scope,
            target.as_ref().and_then(|t| t.to.as_deref()),
            profile,
            reconnect,
        )
        .await?
    };
    if !result.success {
        if json {
            crate::cli_output::write_json_failure(&serde_json::json!({
                "schema_version":1, "success":false, "status":if result.partial { "partial" } else { "failed" },
                "error":{"code":"handshake_configuration_incomplete","message":"Read both device results before another operation; no retry or fallback was performed.","retryable":false},
                "report":result
            }))?;
        } else {
            print_result(&result, false)?;
        }
        bail!("握手配置操作未完成；请查看各端结果，未自动重试或回退");
    }
    print_result(&result, json)
}

pub(crate) fn safe(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(512).collect()
}
pub(crate) fn print_result(result: &HandshakeResult, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(result)?);
        return Ok(());
    }
    println!(
        "本机配置：{} · Provider：{}",
        result.local.configured_profile.title(),
        safe(result.local.provider_suite.as_deref().unwrap_or("未就绪"))
    );
    if let Some(remote) = &result.remote {
        println!(
            "对端配置：{} · Provider：{}",
            remote.configured_profile.title(),
            safe(remote.provider_suite.as_deref().unwrap_or("未就绪"))
        );
    }
    println!(
        "当前会话：{}{}",
        safe(result.negotiated_suite.as_deref().unwrap_or("未建立")),
        result
            .session_transport
            .as_ref()
            .map(|v| format!(" · {}", safe(v)))
            .unwrap_or_default()
    );
    if result.session_matches_configuration == Some(false) {
        println!("配置已与当前会话不同；新配置在下一次连接生效。");
    }
    if result.operation == "list" {
        for option in &result.local.options {
            println!(
                "  {}  {}{}",
                option.profile.title(),
                if option.selectable {
                    "可选"
                } else {
                    "禁用"
                },
                option
                    .reason
                    .as_ref()
                    .map(|s| format!(" · {}", safe(s)))
                    .unwrap_or_default()
            );
        }
    }
    if result.operation == "set" {
        println!(
            "本机应用：{} · 对端应用：{} · 重连：{}",
            result.local_applied, result.remote_applied, result.reconnected
        );
        if result.partial {
            println!("部分成功：两端未完成一致切换。已成功的一端保持其读回状态。");
        } else if result.success {
            println!(
                "✓ 配置应用并读回成功{}",
                if result.reconnected {
                    "，已验证新连接套件。"
                } else {
                    "；后续连接使用新配置。"
                }
            );
        }
    }
    if result.operation == "revoke" && result.success {
        println!("✓ 对端已撤销此 Mac 的持久管理授权。");
    }
    for (side, error) in [
        ("本机", &result.local_error),
        ("对端", &result.remote_error),
        ("重连", &result.reconnect_error),
    ] {
        if let Some(error) = error {
            println!("{side}失败：{}", safe(error));
        }
    }
    Ok(())
}

fn input(prompt: &str) -> Result<Option<String>> {
    print!("{prompt}");
    io::stdout().flush()?;
    let mut value = String::new();
    if io::stdin().read_line(&mut value)? == 0 {
        return Ok(None);
    }
    Ok(Some(value.trim().to_owned()))
}

pub(crate) async fn menu(target: Option<&NearbyDevice>) -> Result<()> {
    let target_ref = target.map(|d| d.device_ref.as_str());
    let state =
        skybridge_crossnet_client::handshake("status", "local", target_ref, None, false).await?;
    print_result(&state, false)?;
    let scope = if target.is_some() {
        match input("应用范围：1 双端，2 仅本机（回车取消）：")?.as_deref() {
            Some("1") => "both",
            Some("2") => "local",
            Some("") | None => return Ok(()),
            _ => bail!("范围编号无效"),
        }
    } else {
        "local"
    };
    if scope == "both" && (!state.success || state.remote.is_none()) {
        bail!("对端配置状态未验证，无法执行双端切换");
    }
    let profiles = [
        HandshakeProfile::Qperiapt,
        HandshakeProfile::Xwing,
        HandshakeProfile::Mlkem,
        HandshakeProfile::Classic,
    ];
    for (i, profile) in profiles.iter().enumerate() {
        let local = state.local.options.iter().find(|o| o.profile == *profile);
        let remote = state
            .remote
            .as_ref()
            .and_then(|s| s.options.iter().find(|o| o.profile == *profile));
        let available = local.is_some_and(|o| o.selectable)
            && (scope == "local" || remote.is_some_and(|o| o.selectable));
        let reason = local
            .filter(|o| !o.selectable)
            .or(remote.filter(|o| scope == "both" && !o.selectable))
            .and_then(|o| o.reason.as_deref());
        println!(
            "{}. {} {}{}",
            i + 1,
            profile.title(),
            if available { "" } else { "[禁用]" },
            reason
                .map(|r| format!(" · {}", safe(r)))
                .unwrap_or_default()
        );
    }
    let Some(choice) = input("选择套件编号（回车取消）：")? else {
        return Ok(());
    };
    if choice.is_empty() {
        return Ok(());
    }
    let index: usize = choice.parse()?;
    let profile = *profiles
        .get(
            index
                .checked_sub(1)
                .ok_or_else(|| anyhow::anyhow!("套件编号无效"))?,
        )
        .ok_or_else(|| anyhow::anyhow!("套件编号无效"))?;
    if !state
        .local
        .options
        .iter()
        .any(|o| o.profile == profile && o.selectable)
        || (scope == "both"
            && !state.remote.as_ref().is_some_and(|s| {
                s.options
                    .iter()
                    .any(|o| o.profile == profile && o.selectable)
            }))
    {
        bail!("所选套件当前不可用；未修改配置");
    }
    let reconnect = if target.is_some() {
        match input("连接处理：1 下次连接生效，2 立即重连（回车取消）：")?.as_deref()
        {
            Some("1") => false,
            Some("2") => true,
            Some("") | None => return Ok(()),
            _ => bail!("连接处理编号无效"),
        }
    } else {
        false
    };
    println!(
        "正在应用 {} · {}{}",
        profile.title(),
        if scope == "both" {
            "双端"
        } else {
            "仅本机"
        },
        if scope == "both" {
            "；首次管理请在对端确认授权"
        } else {
            ""
        }
    );
    let result =
        skybridge_crossnet_client::handshake("set", scope, target_ref, Some(profile), reconnect)
            .await?;
    print_result(&result, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;
    #[test]
    fn direct_usb_requires_complete_identity_and_excludes_discovery_ref() {
        assert!(
            crate::Cli::try_parse_from([
                "skybridge",
                "crossnet",
                "handshake",
                "status",
                "--usb",
                "00008140-000E788401C0801C"
            ])
            .is_err()
        );
        let fingerprint = "ab".repeat(32);
        let id = "00000000-0000-0000-0000-000000000001";
        let args = [
            "skybridge",
            "crossnet",
            "handshake",
            "set",
            "xwing",
            "--scope",
            "both",
            "--usb",
            "00008140-000E788401C0801C",
            "--peer-id",
            id,
            "--expected-fingerprint",
            &fingerprint,
            "--json",
        ];
        let cli = crate::Cli::try_parse_from(args).unwrap();
        assert!(cli.json_output_requested());
        let mut conflicting = args.to_vec();
        conflicting.extend(["--to", id]);
        assert!(crate::Cli::try_parse_from(conflicting).is_err());
    }
    #[test]
    fn profile_aliases_cannot_select_unknown_backend() {
        assert!(
            crate::Cli::try_parse_from([
                "skybridge",
                "crossnet",
                "handshake",
                "set",
                "xwing",
                "--scope",
                "both"
            ])
            .is_err()
        );
        assert!(
            crate::Cli::try_parse_from(["skybridge", "crossnet", "handshake", "revoke"]).is_err()
        );
        assert!(
            crate::Cli::try_parse_from(["skybridge", "crossnet", "handshake", "set", "unknown"])
                .is_err()
        );
        assert!(crate::Cli::try_parse_from(["skybridge", "tui"]).is_ok());
    }
    #[test]
    fn peer_labels_cannot_emit_terminal_control_sequences() {
        let rendered = safe("phone\u{1b}[2J\n\r\u{7}");
        assert!(!rendered.chars().any(char::is_control));
    }
}
