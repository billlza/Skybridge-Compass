use crate::handshake_commands::safe;
use anyhow::{Result, bail};
use skybridge_crossnet_client::LocalApproval;
use std::io::{self, IsTerminal, Write};

pub(crate) async fn command(args: crate::CrossnetApprovalArgs) -> Result<()> {
    let (result, json) = match args.command {
        crate::CrossnetApprovalSubcommand::Pending(output) => (
            skybridge_crossnet_client::local_approvals().await?,
            output.json,
        ),
        crate::CrossnetApprovalSubcommand::Decide(args) => (
            skybridge_crossnet_client::decide_local_approval(
                &args.approval_id,
                &args.decision,
                args.verification_code.as_deref(),
            )
            .await?,
            args.output.json,
        ),
    };
    if json {
        println!("{}", serde_json::to_string_pretty(&result)?);
    } else if result.decision_submitted {
        println!("决定已提交；后续操作仍须等待最终回执。");
    } else {
        for prompt in result.pending {
            println!(
                "{} · {} · {} · 验证码 {}",
                prompt.id,
                safe(&prompt.kind),
                safe(&prompt.name),
                safe(prompt.verification_code.as_deref().unwrap_or("不适用"))
            );
        }
    }
    Ok(())
}

fn input(prompt: &str) -> Result<String> {
    print!("{prompt}");
    io::stdout().flush()?;
    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    Ok(line.trim().to_owned())
}
async fn decide(prompt: &LocalApproval) -> Result<()> {
    println!(
        "本机待确认：{} · {}\n身份：{}\n指纹：{}",
        safe(&prompt.kind),
        safe(&prompt.name),
        safe(&prompt.peer_id),
        safe(prompt.fingerprint.as_deref().unwrap_or("未提供"))
    );
    if !prompt.can_decide {
        println!("已有决定正在提交；不能重复覆盖。");
        return Ok(());
    }
    let verification = if prompt.kind == "pairing" {
        println!(
            "本机验证码：{}。必须与线另一端的设备一致。",
            safe(prompt.verification_code.as_deref().unwrap_or("尚未生成"))
        );
        Some(input("输入对端显示的验证码；回车将拒绝：")?)
    } else {
        None
    };
    let decision = if verification.as_ref().is_some_and(|code| code.is_empty()) {
        "reject"
    } else {
        let question = if prompt.kind == "file_delegation" {
            "1 允许 10 分钟；2 始终允许此身份；回车或 3 拒绝："
        } else {
            "1 仅本次；2 始终允许此身份；回车或 3 拒绝："
        };
        match input(question)?.as_str() {
            "1" => "allow_once",
            "2" => "always_allow",
            _ => "reject",
        }
    };
    skybridge_crossnet_client::decide_local_approval(&prompt.id, decision, verification.as_deref())
        .await?;
    println!("决定已提交；连接和持久授权是否完成仍以各自回执为准。");
    Ok(())
}
pub(crate) async fn menu() -> Result<()> {
    let result = skybridge_crossnet_client::local_approvals().await?;
    if result.pending.is_empty() {
        println!("本机当前没有待确认的配对或授权请求。");
    }
    for prompt in result.pending {
        decide(&prompt).await?;
    }
    Ok(())
}

/// The current USB peer alone may interrupt its connection flow with a prompt.
/// A request for another identity stays in /permission for an explicit choice.
pub(crate) async fn during_usb_connection<T>(
    operation: impl std::future::Future<Output = Result<T>>,
    peer: &str,
    fingerprint: &str,
) -> Result<T> {
    if !io::stdin().is_terminal() {
        return operation.await;
    }
    let hello = skybridge_crossnet_client::hello().await?;
    let supported = hello
        .enabled_mutation_methods
        .as_ref()
        .is_some_and(|m| m.iter().any(|s| s == "crossnet.approval.pending"));
    if !supported {
        return operation.await;
    }
    tokio::pin!(operation);
    let mut seen = std::collections::HashSet::new();
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(400));
    loop {
        tokio::select! {
            result = &mut operation => return result,
            _ = interval.tick() => {
                let pending = skybridge_crossnet_client::local_approvals().await?;
                for prompt in pending.pending {
                    if !prompt.peer_id.trim_start_matches("id:").eq_ignore_ascii_case(peer) || !prompt.can_decide || seen.contains(&prompt.id) { continue; }
                    if prompt.fingerprint.as_deref() != Some(fingerprint) { bail!("USB approval identity changed; no decision was sent"); }
                    seen.insert(prompt.id.clone());
                    decide(&prompt).await?;
                }
            }
        }
    }
}
