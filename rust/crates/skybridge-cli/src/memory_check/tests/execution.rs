#[cfg(unix)]
use std::time::{Duration, Instant};

use super::*;

// The fake leaks tools are shell scripts and the timeout paths exercise
// unix process-group semantics; neither exists on Windows.
#[cfg(unix)]
#[test]
fn memory_check_times_out_and_fails_without_fake_no_leaks() -> Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    let dir = make_test_dir("memory-timeout")?;
    let tool = dir.join("fake-leaks-sleeps.sh");
    std::fs::write(&tool, "#!/bin/sh\nsleep 2\n")?;
    #[cfg(unix)]
    {
        let mut permissions = std::fs::metadata(&tool)?.permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&tool, permissions)?;
    }

    let args = MemoryCheckArgs {
        pid: Some(123),
        executable: None,
        executable_args: Vec::new(),
        leaks_tool: tool,
        timeout_seconds: 1,
        quiet: false,
        output: OutputOptions { json: false },
    };
    let report = build_memory_check_report(&args)?;

    let scan = doctor_check(&report, "memory_leak_scan_completed");
    assert!(!scan.ok, "{}", scan.detail);
    assert!(scan.detail.contains("timedOut=true"), "{}", scan.detail);
    let no_leaks = doctor_check(&report, "memory_no_leaks");
    assert!(!no_leaks.ok, "{}", no_leaks.detail);
    assert!(no_leaks.detail.contains("no leak verdict"));
    Ok(())
}

// The fake leaks tools are shell scripts and the timeout paths exercise
// unix process-group semantics; neither exists on Windows.
#[cfg(unix)]
#[test]
fn memory_check_timeout_kills_grandchild_pipe_holders() -> Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    let dir = make_test_dir("memory-timeout-grandchild")?;
    let tool = dir.join("fake-leaks-grandchild.sh");
    std::fs::write(&tool, "#!/bin/sh\n(sleep 30) &\nwait\n")?;
    #[cfg(unix)]
    {
        let mut permissions = std::fs::metadata(&tool)?.permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&tool, permissions)?;
    }

    let args = MemoryCheckArgs {
        pid: Some(123),
        executable: None,
        executable_args: Vec::new(),
        leaks_tool: tool,
        timeout_seconds: 1,
        quiet: false,
        output: OutputOptions { json: false },
    };
    let started = Instant::now();
    let report = build_memory_check_report(&args)?;

    assert!(
        started.elapsed() < Duration::from_secs(5),
        "timeout should not wait for a grandchild that inherited stdio"
    );
    let scan = doctor_check(&report, "memory_leak_scan_completed");
    assert!(!scan.ok, "{}", scan.detail);
    assert!(scan.detail.contains("timedOut=true"), "{}", scan.detail);
    Ok(())
}

// The fake leaks tools are shell scripts and the timeout paths exercise
// unix process-group semantics; neither exists on Windows.
#[cfg(unix)]
#[test]
fn memory_check_launch_scan_success_reports_no_leaks() -> Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    let dir = make_test_dir("memory-launch-success")?;
    let tool = dir.join("fake-leaks-success.sh");
    std::fs::write(&tool, "#!/bin/sh\necho 'Process 123: 0 leaks'\nexit 0\n")?;
    #[cfg(unix)]
    {
        let mut permissions = std::fs::metadata(&tool)?.permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&tool, permissions)?;
    }

    let args = MemoryCheckArgs {
        pid: None,
        executable: Some(PathBuf::from("/usr/bin/true")),
        executable_args: vec!["--probe".to_owned()],
        leaks_tool: tool,
        timeout_seconds: 5,
        quiet: true,
        output: OutputOptions { json: false },
    };
    let report = build_memory_check_report(&args)?;

    assert!(report.target.contains("executable=/usr/bin/true"));
    assert!(doctor_check(&report, "memory_leak_scan_completed").ok);
    assert!(doctor_check(&report, "memory_no_leaks").ok);
    Ok(())
}

#[test]
fn memory_check_missing_leaks_tool_reports_execution_failure() -> Result<()> {
    let args = MemoryCheckArgs {
        pid: Some(123),
        executable: None,
        executable_args: Vec::new(),
        leaks_tool: PathBuf::from("/tmp/skybridge-missing-leaks-tool"),
        timeout_seconds: 5,
        quiet: false,
        output: OutputOptions { json: false },
    };
    let report = build_memory_check_report(&args)?;

    let tool = doctor_check(&report, "memory_leaks_tool");
    assert!(!tool.ok, "{}", tool.detail);
    assert!(tool.detail.contains("failed to execute"));
    assert!(!doctor_check(&report, "memory_leak_scan_completed").ok);
    assert!(!doctor_check(&report, "memory_no_leaks").ok);
    Ok(())
}

// The fake leaks tools are shell scripts and the timeout paths exercise
// unix process-group semantics; neither exists on Windows.
#[cfg(unix)]
#[test]
fn memory_check_failed_leaks_exit_fails_without_fake_no_leaks() -> Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    let dir = make_test_dir("memory-failed-exit")?;
    let tool = dir.join("fake-leaks-fails.sh");
    std::fs::write(
        &tool,
        "#!/bin/sh\necho 'Process has leaked memory' >&2\nexit 1\n",
    )?;
    #[cfg(unix)]
    {
        let mut permissions = std::fs::metadata(&tool)?.permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&tool, permissions)?;
    }

    let args = MemoryCheckArgs {
        pid: Some(123),
        executable: None,
        executable_args: Vec::new(),
        leaks_tool: tool,
        timeout_seconds: 5,
        quiet: false,
        output: OutputOptions { json: false },
    };
    let report = build_memory_check_report(&args)?;

    let scan = doctor_check(&report, "memory_leak_scan_completed");
    assert!(!scan.ok, "{}", scan.detail);
    assert!(scan.detail.contains("leaks exit=1"), "{}", scan.detail);
    let no_leaks = doctor_check(&report, "memory_no_leaks");
    assert!(!no_leaks.ok, "{}", no_leaks.detail);
    assert!(
        no_leaks.detail.contains("leaks returned failure"),
        "{}",
        no_leaks.detail
    );
    Ok(())
}
