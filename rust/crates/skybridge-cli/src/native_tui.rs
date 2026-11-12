//! Linux terminal presentation over the public native CLI. Each action uses
//! the same dispatcher and state directory, with literal arguments and no shell.
//! This layer owns neither credentials nor transport/session state.
use std::io::{self, BufRead, IsTerminal, Read, Write};
use std::path::PathBuf;

use anyhow::{Result, bail};
use clap::Parser;

use crate::Cli;

const MAX_INPUT_BYTES: u64 = 4096;
const MENU: &str = "\nSkyBridge · Linux\n\
  1  运行代理（前台；Ctrl+C 停止）\n\
  2  代理状态\n\
  3  扫描附近设备\n\
  4  本机与账户状态\n\
  5  登录（在浏览器授权后粘贴回调）\n\
  6  创建连接码\n\
  7  使用连接码连接\n\
  8  会话列表\n\
  9  查看指定会话\n\
 10  断开指定会话\n\
 11  发送文件（等待验证回执）\n\
 12  查看待接收文件\n\
 13  接受文件\n\
 14  拒绝文件\n\
 15  文件传输历史\n\
 16  连接与账户诊断\n\
 17  运行指标\n\
 18  最近日志\n\
 19  当前平台功能\n\
 20  退出账户\n\
 21  停止代理（等待进程退出）\n\
  q  退出菜单\n\n\
附近发现仅提供候选设备；连接仍须完成身份验证与授权。\n";

pub(crate) async fn run(state_dir: Option<PathBuf>) -> Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        bail!(
            "Linux guided menus require an interactive terminal; use --help for scriptable commands"
        );
    }
    // Preserve the selected root's spelling: the existing runtime lease binds
    // state_dir verbatim, including relative paths. The dispatcher does not
    // change the process working directory between menu actions.
    let paths = skybridge_agent::resolve_paths(state_dir)?;
    let state_dir = paths.root;
    loop {
        print!("{MENU}");
        let Some(selection) = read_value(&mut io::stdin().lock(), &mut io::stdout(), "选择: ")?
        else {
            return Ok(());
        };
        if matches!(selection.as_str(), "q" | "/quit" | "exit") {
            return Ok(());
        }
        if selection.is_empty() {
            continue;
        }
        if !selection
            .parse::<u8>()
            .is_ok_and(|value| (1..=21).contains(&value))
        {
            eprintln!("请输入 1–21 或 q");
            continue;
        }
        let Some(arguments) =
            command_arguments(&selection, &mut io::stdin().lock(), &mut io::stdout())?
        else {
            continue;
        };
        // Reuse Clap's actual contracts before any effect. No command shell is
        // involved. Boxing breaks the dispatch -> menu -> dispatch future cycle;
        // the menu only constructs terminal commands, never another menu.
        let mut command = Cli::try_parse_from(
            std::iter::once("skybridge").chain(arguments.iter().map(String::as_str)),
        )?;
        command.state_dir = Some(state_dir.clone());
        if let Err(error) = Box::pin(crate::cli_dispatch::dispatch(command)).await {
            let detail: String = format!("{error:#}")
                .chars()
                .filter(|value| !value.is_control())
                .collect();
            eprintln!("操作未完成：{detail}；未自动重试。");
        }
    }
}

fn read_value(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    prompt: &str,
) -> Result<Option<String>> {
    write!(writer, "{prompt}")?;
    writer.flush()?;
    let mut line = String::new();
    let count = reader.take(MAX_INPUT_BYTES + 1).read_line(&mut line)?;
    if count == 0 {
        return Ok(None);
    }
    if count as u64 > MAX_INPUT_BYTES {
        bail!("input exceeds the 4096-byte limit");
    }
    let value = line.trim_end_matches(['\r', '\n']);
    if value.chars().any(char::is_control) {
        bail!("input contains terminal control characters");
    }
    Ok(Some(value.to_owned()))
}

fn required_value(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    prompt: &str,
) -> Result<Option<String>> {
    Ok(read_value(reader, writer, prompt)?.filter(|value| !value.trim().is_empty()))
}

fn command_arguments(
    selection: &str,
    reader: &mut impl BufRead,
    writer: &mut impl Write,
) -> Result<Option<Vec<String>>> {
    let mut args: Vec<String> = match selection {
        "1" => vec!["agent", "run"],
        "2" => vec!["agent", "status"],
        "3" => vec!["device", "discover", "--nearby", "--scan"],
        "4" => vec!["device", "status"],
        "5" => vec!["login", "--no-open"],
        "6" => vec!["code", "create"],
        "7" => vec!["connect"],
        "8" => vec!["session", "ls"],
        "9" => vec!["session", "inspect"],
        "10" => vec!["disconnect"],
        "11" => vec!["file", "send"],
        "12" => vec!["file", "receive", "--list"],
        "13" | "14" => vec!["file", "receive"],
        "15" => vec!["file", "history"],
        "16" => vec!["doctor"],
        "17" => vec!["metrics"],
        "18" => vec!["logs", "tail"],
        "19" => vec!["capabilities"],
        "20" => vec!["logout"],
        "21" => vec!["agent", "stop"],
        _ => bail!("请输入 1–21 或 q"),
    }
    .into_iter()
    .map(str::to_owned)
    .collect();
    match selection {
        "7" | "9" | "10" => {
            let prompt = if selection == "7" {
                "连接码（留空取消）: "
            } else {
                "完整会话 ID（留空取消）: "
            };
            let Some(value) = required_value(reader, writer, prompt)? else {
                return Ok(None);
            };
            args.extend(["--".to_owned(), value]);
        }
        "11" => {
            let Some(path) = required_value(reader, writer, "文件路径（留空取消）: ")?
            else {
                return Ok(None);
            };
            let Some(peer) = required_value(reader, writer, "已认证对端 ID（留空取消）: ")?
            else {
                return Ok(None);
            };
            let Some(session) = required_value(reader, writer, "完整会话 ID（留空取消）: ")?
            else {
                return Ok(None);
            };
            args.extend([
                "--to".into(),
                peer,
                "--session-id".into(),
                session,
                "--".into(),
                path,
            ]);
        }
        "13" | "14" => {
            let Some(session) = required_value(reader, writer, "完整会话 ID（留空取消）: ")?
            else {
                return Ok(None);
            };
            let Some(transfer) = required_value(reader, writer, "待接收文件 UUID（留空取消）: ")?
            else {
                return Ok(None);
            };
            args.extend([
                "--session-id".into(),
                session,
                if selection == "13" {
                    "--accept".into()
                } else {
                    "--reject".into()
                },
                transfer,
            ]);
        }
        _ => {}
    }
    if matches!(
        selection,
        "1" | "5" | "6" | "7" | "10" | "11" | "13" | "14" | "20" | "21"
    ) {
        writeln!(
            writer,
            "即将执行 {}。",
            args.iter()
                .map(|arg| crate::cli_text::shell_quote(arg))
                .collect::<Vec<_>>()
                .join(" ")
        )?;
        if read_value(reader, writer, "输入 yes 确认，其余输入取消: ")?.as_deref() != Some("yes")
        {
            return Ok(None);
        }
    }
    Ok(Some(args))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn native_menu_actions_use_the_real_parser_and_literal_paths() -> Result<()> {
        for (selection, input) in [
            ("1", "yes\n"),
            ("2", ""),
            ("3", ""),
            ("4", ""),
            ("5", "yes\n"),
            ("6", "yes\n"),
            ("7", "ABCDEFGH\nyes\n"),
            ("8", ""),
            ("9", "session\n"),
            ("10", "session\nyes\n"),
            (
                "11",
                "-file $(touch never); with spaces\npeer\nsession\nyes\n",
            ),
            ("12", ""),
            ("13", "session\n018fa320-1234-7890-abcd-123456789abc\nyes\n"),
            ("14", "session\n018fa320-1234-7890-abcd-123456789abc\nyes\n"),
            ("15", ""),
            ("16", ""),
            ("17", ""),
            ("18", ""),
            ("19", ""),
            ("20", "yes\n"),
            ("21", "yes\n"),
        ] {
            let args = command_arguments(selection, &mut Cursor::new(input), &mut Vec::new())?
                .expect("menu action");
            let parsed = Cli::try_parse_from(
                std::iter::once("skybridge").chain(args.iter().map(String::as_str)),
            )?;
            if selection == "11" {
                let crate::Commands::File(crate::FileCommand {
                    command: crate::FileSubcommand::Send(send),
                }) = parsed.command
                else {
                    panic!("file send action");
                };
                assert_eq!(
                    send.path,
                    PathBuf::from("-file $(touch never); with spaces")
                );
                assert!(!send.detach, "menu send must wait for a verified receipt");
            }
        }
        Ok(())
    }

    #[test]
    fn native_menu_cancellation_and_bad_input_never_dispatch() -> Result<()> {
        for input in ["", "\n", "session\n", "session\nno\n"] {
            assert!(command_arguments("10", &mut Cursor::new(input), &mut Vec::new())?.is_none());
        }
        assert!(command_arguments("999", &mut Cursor::new(""), &mut Vec::new()).is_err());
        for input in ["bad\x1b[2J\n".to_owned(), "x".repeat(4097)] {
            assert!(read_value(&mut Cursor::new(input), &mut Vec::new(), "").is_err());
        }
        Ok(())
    }
}
