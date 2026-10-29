use crate::{CrossnetFileApprovalArgs, FileApprovalAction, FileApprovalMode, FileDecision};
use anyhow::{Result, bail};
use skybridge_crossnet_client::{FileApprovalPrompt, FileApprovalResult};
use std::io::{self, IsTerminal, Write};

fn safe(value: &str) -> String {
    value
        .chars()
        .filter(|c| !c.is_control())
        .take(1024)
        .collect()
}
fn input(message: &str) -> Result<String> {
    eprint!("{message}");
    io::stderr().flush()?;
    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    Ok(line.trim().to_owned())
}
fn show(result: &FileApprovalResult) {
    println!(
        "CLI 文件审批：{} · {}",
        match result.authorized {
            Some(true) => "已授权",
            Some(false) => "尚未授权",
            None => "授权状态未读取",
        },
        result.transport.as_deref().unwrap_or("连接未确认")
    );
    for p in &result.pending {
        println!(
            "{}  {}  {} B\n  SHA-256: {}",
            p.id,
            safe(&p.binding.file_name),
            p.binding.file_size,
            p.binding.file_sha256
        );
    }
    if let Some(id) = &result.decided_id {
        println!(
            "对端已确认{}：{}；传输成功仍需接收回执。",
            if result.allowed == Some(true) {
                "允许"
            } else {
                "拒绝"
            },
            id
        );
    }
}
pub(crate) async fn command(args: CrossnetFileApprovalArgs) -> Result<()> {
    let action = match args.action {
        FileApprovalAction::Status => "status",
        FileApprovalAction::Authorize => "authorize",
        FileApprovalAction::Decide => "decide",
        FileApprovalAction::Revoke => "revoke",
    };
    let decision = match (&args.approval_id, args.decision) {
        (Some(id), Some(choice)) => Some((id.as_str(), matches!(choice, FileDecision::Allow))),
        (None, None) => None,
        _ => bail!("decide requires --approval-id and --decision allow|deny"),
    };
    if action == "authorize" && !args.output.json {
        eprintln!("正在请求文件审批权限；首次需在接收设备确认，可选择持续授权。等待结果…");
    }
    let result = skybridge_crossnet_client::file_approval(action, &args.to, decision).await?;
    if args.output.json {
        if result.success {
            println!("{}", serde_json::to_string_pretty(&result)?);
        } else {
            crate::cli_output::write_json_failure(&result)?;
        }
    } else {
        show(&result);
    }
    result.require_success()
}

pub(crate) async fn ensure_permission(
    target: &str,
    mode: FileApprovalMode,
    json: bool,
) -> Result<()> {
    if mode == FileApprovalMode::Device {
        return Ok(());
    }
    if mode == FileApprovalMode::Prompt && (json || !io::stdin().is_terminal()) {
        return Err(FileApprovalInputRequired.into());
    }
    let status = skybridge_crossnet_client::file_approval("status", target, None).await?;
    if !status.success && json {
        crate::cli_output::write_json_failure(&status)?;
    }
    status.require_success()?;
    if status.authorized == Some(true) {
        return Ok(());
    }
    if mode != FileApprovalMode::Prompt {
        if json {
            crate::cli_output::write_json_failure(
                &serde_json::json!({"schema_version":1,"success":false,
            "status":"authorization_required","error":{"code":"file_approval_not_authorized",
            "message":"Run crossnet file approval authorize for this receiver before sending.","retryable":false}}),
            )?;
        }
        bail!(
            "file_approval_not_authorized: run crossnet file approval authorize --to {target} first"
        );
    }
    eprintln!("接收设备尚未授予 CLI 文件审批权限。此权限独立于握手配置，仍需逐文件选择。");
    if input("1 请求授权；回车取消：")? != "1" {
        bail!("file approval authorization cancelled; no file was sent");
    }
    eprintln!("请在接收设备确认首次授权；选择持续授权后可在终端逐文件处理。等待结果…");
    let response = skybridge_crossnet_client::file_approval("authorize", target, None).await?;
    response.require_success()?;
    if response.authorized != Some(true) {
        bail!("file_approval_not_authorized");
    }
    Ok(())
}

pub(crate) async fn decide(
    target: &str,
    prompt: &FileApprovalPrompt,
    mode: FileApprovalMode,
) -> Result<bool> {
    let allow = match mode {
        FileApprovalMode::Allow => true,
        FileApprovalMode::Deny => false,
        FileApprovalMode::Device => bail!("device approval mode cannot decide from CLI"),
        FileApprovalMode::Prompt => {
            eprintln!("接收设备：{target}");
            eprintln!(
                "\n待接收：{} · {} B\nSHA-256: {}\n请求：{}（超时或断线后失效）",
                safe(&prompt.binding.file_name),
                prompt.binding.file_size,
                prompt.binding.file_sha256,
                prompt.id
            );
            input("1 允许接收；2 拒绝（回车拒绝）：")? == "1"
        }
    };
    let result =
        skybridge_crossnet_client::file_approval("decide", target, Some((&prompt.id, allow)))
            .await?;
    result.require_success()?;
    Ok(allow)
}

pub(crate) async fn menu(target: &str) -> Result<()> {
    ensure_permission(target, FileApprovalMode::Prompt, false).await?;
    let state = skybridge_crossnet_client::file_approval("status", target, None).await?;
    state.require_success()?;
    show(&state);
    if state.pending.is_empty() {
        println!("当前没有待审批文件。");
        return Ok(());
    }
    for prompt in &state.pending {
        decide(target, prompt, FileApprovalMode::Prompt).await?;
    }
    Ok(())
}

#[derive(Debug)]
pub(crate) struct FileApprovalInputRequired;
impl std::fmt::Display for FileApprovalInputRequired {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CLI approval needs a terminal. Use --approval allow|deny for an explicit decision, or --approval device. No file was sent.")
    }
}
impl std::error::Error for FileApprovalInputRequired {}
