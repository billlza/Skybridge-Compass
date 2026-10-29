use std::io::Read;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::MemoryCheckArgs;
use crate::cli_text::shell_quote;

pub(super) fn format_memory_leaks_command(args: &MemoryCheckArgs) -> String {
    let mut parts = Vec::new();
    parts.push(args.leaks_tool.display().to_string());
    if args.quiet {
        parts.push("--quiet".to_owned());
    }
    if let Some(pid) = args.pid {
        parts.push(pid.to_string());
    } else {
        parts.push("--atExit".to_owned());
        parts.push("--".to_owned());
        let executable = args.executable.as_ref().expect("checked by caller");
        parts.push(shell_quote(&executable.display().to_string()));
        parts.extend(args.executable_args.iter().map(|arg| shell_quote(arg)));
    }
    parts.join(" ")
}

pub(super) fn summarize_inline(value: &str) -> String {
    let compact = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        "(empty)".to_owned()
    } else {
        compact
    }
}

#[derive(Debug)]
pub(super) struct TimedCommandOutput {
    pub(super) status: Option<ExitStatus>,
    pub(super) stdout: Vec<u8>,
    pub(super) stderr: Vec<u8>,
    pub(super) timed_out: bool,
}

pub(super) fn run_command_with_timeout(
    command: &mut Command,
    timeout: Duration,
) -> std::io::Result<TimedCommandOutput> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    configure_child_process_group(command);
    let mut child = command.spawn()?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_reader = stdout.map(|mut stream| {
        thread::spawn(move || {
            let mut output = Vec::new();
            let _ = stream.read_to_end(&mut output);
            output
        })
    });
    let stderr_reader = stderr.map(|mut stream| {
        thread::spawn(move || {
            let mut output = Vec::new();
            let _ = stream.read_to_end(&mut output);
            output
        })
    });

    let started_at = Instant::now();
    let (status, timed_out) = loop {
        if let Some(status) = child.try_wait()? {
            break (Some(status), false);
        }
        if started_at.elapsed() >= timeout {
            terminate_timed_out_child(&mut child);
            let status = child.wait().ok();
            break (status, true);
        }
        thread::sleep(Duration::from_millis(50));
    };

    let stdout = stdout_reader
        .map(|handle| handle.join().unwrap_or_default())
        .unwrap_or_default();
    let stderr = stderr_reader
        .map(|handle| handle.join().unwrap_or_default())
        .unwrap_or_default();

    Ok(TimedCommandOutput {
        status,
        stdout,
        stderr,
        timed_out,
    })
}

#[cfg(unix)]
fn configure_child_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;

    command.process_group(0);
}

#[cfg(not(unix))]
fn configure_child_process_group(_command: &mut Command) {}

#[cfg(unix)]
fn terminate_timed_out_child(child: &mut Child) {
    // "--" ends option parsing so the negative process-group argument can
    // never be misread as an option or signal spec by any kill(1) flavor.
    let process_group = format!("-{}", child.id());
    let _ = Command::new("kill")
        .arg("-TERM")
        .arg("--")
        .arg(&process_group)
        .status();
    thread::sleep(Duration::from_millis(100));
    if child.try_wait().ok().flatten().is_none() {
        let _ = Command::new("kill")
            .arg("-KILL")
            .arg("--")
            .arg(&process_group)
            .status();
        let _ = child.kill();
    }
}

#[cfg(not(unix))]
fn terminate_timed_out_child(child: &mut Child) {
    let _ = child.kill();
}
