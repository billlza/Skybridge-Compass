use crate::handshake_commands::safe;
use crate::{CrossnetDesktopArgs, CrossnetDesktopSubcommand};
use anyhow::{Result, anyhow, bail};
use skybridge_crossnet_client::{DesktopResult, NearbyDevice};
use std::io::{self, Write};
use std::time::Duration;

pub(crate) async fn command(args: CrossnetDesktopArgs) -> Result<()> {
    match args.command {
        CrossnetDesktopSubcommand::Devices(output) => show(
            &skybridge_crossnet_client::desktop("devices", None).await?,
            output.json,
        ),
        CrossnetDesktopSubcommand::Status(args) => show(
            &skybridge_crossnet_client::desktop("status", args.session_ref.as_deref()).await?,
            args.output.json,
        ),
        CrossnetDesktopSubcommand::Stop(args) => stop(&args.session_ref, args.output.json).await,
        CrossnetDesktopSubcommand::Start(args) => {
            start(
                &args.device_ref,
                args.host.zip(args.port),
                args.detach,
                args.output.json,
            )
            .await
        }
    }
}

fn show(result: &DesktopResult, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(result)?);
        return Ok(());
    }
    for device in &result.devices {
        println!(
            "{}  {} · {}",
            device.device_ref,
            safe(&device.name),
            if device.available {
                "可请求画面与输入权限"
            } else {
                "未自动发现画面服务，可用 IP／端口连接已配对主机"
            }
        );
    }
    for session in &result.sessions {
        let state = match session.phase.as_str() {
            "connecting" => "建立安全会话／等待对端授权",
            "waiting_frame" => "已建立会话，等待实际首帧",
            "ready" => "画面流已就绪",
            "stopping" => "正在结束会话",
            "closed" => "会话已结束",
            "failed" => "会话失败",
            _ => "未知状态",
        };
        println!(
            "{} · {} · {}",
            safe(&session.name),
            state,
            session.session_ref
        );
        println!(
            "  窗口：{} · 首帧：{} · 键鼠：{}",
            session.window_visible,
            session.frame_presented,
            if session.input_ready {
                "可用"
            } else if session.input_authorized {
                "已授权，等待当前窗口与焦点"
            } else {
                "尚未获准"
            }
        );
        if let Some(error) = &session.error_code {
            println!("  原因：{}", safe(error));
        }
    }
    if result.operation == "status" && result.sessions.is_empty() {
        println!("当前没有由 CLI 管理的远程桌面会话。");
    }
    Ok(())
}

async fn stop(reference: &str, json: bool) -> Result<()> {
    let result = skybridge_crossnet_client::desktop("stop", Some(reference)).await?;
    show(&result, json)?;
    if result.sessions.first().is_none_or(|s| s.phase != "closed") {
        bail!("desktop_stop_not_confirmed");
    }
    Ok(())
}

async fn start(
    target: &str,
    endpoint: Option<(std::net::Ipv4Addr, u16)>,
    detach: bool,
    json: bool,
) -> Result<()> {
    let mut result = if let Some((host, port)) = endpoint {
        skybridge_crossnet_client::desktop_start_at(target, host, port).await?
    } else {
        skybridge_crossnet_client::desktop("start", Some(target)).await?
    };
    let reference = result
        .sessions
        .first()
        .ok_or_else(|| anyhow!("desktop_session_missing"))?
        .session_ref
        .clone();
    if detach {
        return show(&result, json);
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(150);
    let mut previous = None;
    loop {
        let session = result
            .sessions
            .first()
            .ok_or_else(|| anyhow!("desktop_session_missing"))?;
        let state = (
            session.phase.clone(),
            session.input_authorized,
            session.input_ready,
        );
        if !json && previous.as_ref() != Some(&state) {
            show(&result, false)?;
        }
        previous = Some(state);
        if session.phase == "ready" && session.window_visible {
            if json {
                show(&result, true)?;
            }
            if !json && !session.input_ready {
                println!("当前为观看模式；键鼠是否可用以对端授权和平台能力为准。");
            }
            return Ok(());
        }
        if session.phase == "failed" || session.phase == "closed" {
            if json {
                crate::cli_output::write_json_failure(
                    &serde_json::json!({"schema_version":1,"success":false,"status":"failed","report":result}),
                )?;
            }
            bail!("desktop_start_not_ready");
        }
        tokio::select! {
            signal = tokio::signal::ctrl_c() => {
                signal?;
                stop(&reference, json).await?;
                bail!("desktop_start_cancelled");
            }
            _ = tokio::time::sleep_until(deadline) => {
                stop(&reference, json).await?;
                bail!("desktop_start_timeout; exact session stopped");
            }
            _ = tokio::time::sleep(Duration::from_millis(400)) => {}
        }
        result = skybridge_crossnet_client::desktop("status", Some(&reference)).await?;
    }
}

fn input(prompt: &str) -> Result<String> {
    print!("{prompt}");
    io::stdout().flush()?;
    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    Ok(line.trim().to_owned())
}

pub(crate) async fn menu(target: Option<&NearbyDevice>) -> Result<()> {
    println!(
        "远程桌面：1 自动发现连接；2 会话状态；3 结束会话；4 用 IP／端口连接已配对主机（回车返回）"
    );
    match input("选择：")?.as_str() {
        "1" => {
            let result = skybridge_crossnet_client::desktop("devices", None).await?;
            let mut choices = Vec::new();
            for device in &result.devices {
                if !device.available {
                    println!("{} · 当前设备未提供被控主机能力", safe(&device.name));
                    continue;
                }
                choices.push(device);
                println!(
                    "{}. {}{}",
                    choices.len(),
                    safe(&device.name),
                    if target.is_some_and(|t| t.device_ref == device.device_ref) {
                        "（当前所选）"
                    } else {
                        ""
                    }
                );
            }
            if choices.is_empty() {
                println!(
                    "未发现可提供远程画面的 SkyBridge 主机。iPhone／iPad 当前作为观看端使用。"
                );
                return Ok(());
            }
            let value = input("选择设备（回车返回）：")?;
            if value.is_empty() {
                return Ok(());
            }
            let choice = value
                .parse::<usize>()?
                .checked_sub(1)
                .and_then(|i| choices.get(i))
                .ok_or_else(|| anyhow!("设备编号无效"))?;
            start(&choice.device_ref, None, false, false).await
        }
        "4" => {
            let result = skybridge_crossnet_client::desktop("devices", None).await?;
            let choices: Vec<_> = result
                .devices
                .iter()
                .filter(|d| matches!(d.platform.as_deref(), Some("macos" | "windows" | "linux")))
                .collect();
            for (index, device) in choices.iter().enumerate() {
                println!("{}. {}", index + 1, safe(&device.name));
            }
            if choices.is_empty() {
                println!("未发现电脑身份，请先通过 /device 发现并配对。");
                return Ok(());
            }
            let selected = input("选择已配对电脑（回车返回）：")?;
            if selected.is_empty() {
                return Ok(());
            }
            let choice = selected
                .parse::<usize>()?
                .checked_sub(1)
                .and_then(|i| choices.get(i))
                .ok_or_else(|| anyhow!("设备编号无效"))?;
            let host = input("电脑 IPv4 地址：")?.parse::<std::net::Ipv4Addr>()?;
            let port = input("SkyBridge 画面服务端口：")?.parse::<u16>()?;
            start(&choice.device_ref, Some((host, port)), false, false).await
        }
        "2" => show(
            &skybridge_crossnet_client::desktop("status", None).await?,
            false,
        ),
        "3" => {
            let result = skybridge_crossnet_client::desktop("status", None).await?;
            let choices: Vec<_> = result
                .sessions
                .iter()
                .filter(|s| s.phase != "closed" && s.phase != "failed")
                .collect();
            for (i, session) in choices.iter().enumerate() {
                println!(
                    "{}. {} · {}",
                    i + 1,
                    safe(&session.name),
                    session.session_ref
                );
            }
            if choices.is_empty() {
                println!("没有可结束的会话。");
                return Ok(());
            }
            let value = input("选择要结束的会话（回车返回）：")?;
            if value.is_empty() {
                return Ok(());
            }
            let choice = value
                .parse::<usize>()?
                .checked_sub(1)
                .and_then(|i| choices.get(i))
                .ok_or_else(|| anyhow!("会话编号无效"))?;
            stop(&choice.session_ref, false).await
        }
        "" => Ok(()),
        _ => bail!("操作编号无效"),
    }
}
