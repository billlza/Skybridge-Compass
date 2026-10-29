use super::*;

#[test]
fn memory_check_requires_exactly_one_target() {
    let no_target = MemoryCheckArgs {
        pid: None,
        executable: None,
        executable_args: Vec::new(),
        leaks_tool: PathBuf::from("leaks"),
        timeout_seconds: 60,
        quiet: true,
        output: OutputOptions { json: false },
    };
    assert!(build_memory_check_report(&no_target).is_err());

    let both_targets = MemoryCheckArgs {
        pid: Some(123),
        executable: Some(PathBuf::from("/usr/bin/true")),
        executable_args: Vec::new(),
        leaks_tool: PathBuf::from("leaks"),
        timeout_seconds: 60,
        quiet: true,
        output: OutputOptions { json: false },
    };
    assert!(build_memory_check_report(&both_targets).is_err());
}

#[test]
fn memory_check_formats_pid_and_launch_scans() {
    let pid_scan = MemoryCheckArgs {
        pid: Some(123),
        executable: None,
        executable_args: Vec::new(),
        leaks_tool: PathBuf::from("/usr/bin/leaks"),
        timeout_seconds: 60,
        quiet: true,
        output: OutputOptions { json: false },
    };
    assert_eq!(
        format_memory_leaks_command(&pid_scan),
        "/usr/bin/leaks --quiet 123"
    );

    let launch_scan = MemoryCheckArgs {
        pid: None,
        executable: Some(PathBuf::from("/usr/bin/true")),
        executable_args: vec!["--flag with space".to_owned()],
        leaks_tool: PathBuf::from("/usr/bin/leaks"),
        timeout_seconds: 60,
        quiet: true,
        output: OutputOptions { json: false },
    };
    assert_eq!(
        format_memory_leaks_command(&launch_scan),
        "/usr/bin/leaks --quiet --atExit -- /usr/bin/true '--flag with space'"
    );
}
