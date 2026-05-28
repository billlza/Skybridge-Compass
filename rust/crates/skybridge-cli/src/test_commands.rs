use std::process::Command;

use anyhow::{Result, bail};
use serde::Serialize;

use crate::cli_text::{shell_quote, tail_lossy};
use crate::repo_paths::{resolve_repo_root, swift_test_cache_env};
use crate::{SwiftTestArgs, TestCommand, TestSubcommand};

#[derive(Debug, Serialize)]
struct TestEnvJson {
    name: String,
    value: String,
}

#[derive(Debug, Serialize)]
struct SwiftTestPlanJson {
    schema_version: u8,
    dry_run: bool,
    cwd: String,
    command: Vec<String>,
    env: Vec<TestEnvJson>,
}

#[derive(Debug, Serialize)]
struct SwiftTestOutcomeJson {
    schema_version: u8,
    dry_run: bool,
    cwd: String,
    command: Vec<String>,
    env: Vec<TestEnvJson>,
    success: bool,
    exit_code: Option<i32>,
    stdout_tail: String,
    stderr_tail: String,
}

pub(crate) async fn run_test_command(command: TestCommand) -> Result<()> {
    match command.command {
        TestSubcommand::Swift(args) => run_swift_tests(args),
    }
}

pub(crate) fn run_swift_tests(args: SwiftTestArgs) -> Result<()> {
    let root = resolve_repo_root()?;
    let command = swift_test_command_vector(args.filter.as_deref());
    let env = swift_test_cache_env(&root);

    if args.dry_run {
        let plan = SwiftTestPlanJson {
            schema_version: 1,
            dry_run: true,
            cwd: root.display().to_string(),
            command,
            env: env_to_json(&env),
        };
        if args.output.json {
            println!("{}", serde_json::to_string_pretty(&plan)?);
        } else {
            print_swift_test_plan_text(&plan);
        }
        return Ok(());
    }

    let mut process = Command::new(&command[0]);
    process.args(&command[1..]).current_dir(&root);
    for (name, value) in &env {
        process.env(name, value);
    }

    if args.output.json {
        let output = process.output()?;
        let report = SwiftTestOutcomeJson {
            schema_version: 1,
            dry_run: false,
            cwd: root.display().to_string(),
            command,
            env: env_to_json(&env),
            success: output.status.success(),
            exit_code: output.status.code(),
            stdout_tail: tail_lossy(&output.stdout, 8_000),
            stderr_tail: tail_lossy(&output.stderr, 8_000),
        };
        println!("{}", serde_json::to_string_pretty(&report)?);
        if !report.success {
            bail!("swift test failed");
        }
        return Ok(());
    }

    let status = process.status()?;
    if !status.success() {
        bail!("swift test failed with status {status}");
    }
    Ok(())
}

pub(crate) fn swift_test_command_vector(filter: Option<&str>) -> Vec<String> {
    let mut command = vec!["swift".to_owned(), "test".to_owned()];
    if let Some(filter) = filter {
        command.push("--filter".to_owned());
        command.push(filter.to_owned());
    }
    command
}

fn env_to_json(env: &[(String, String)]) -> Vec<TestEnvJson> {
    env.iter()
        .map(|(name, value)| TestEnvJson {
            name: name.clone(),
            value: value.clone(),
        })
        .collect()
}

fn print_swift_test_plan_text(plan: &SwiftTestPlanJson) {
    let env = plan
        .env
        .iter()
        .map(|entry| format!("{}={}", entry.name, shell_quote(&entry.value)))
        .collect::<Vec<_>>()
        .join(" ");
    let command = plan
        .command
        .iter()
        .map(|part| shell_quote(part))
        .collect::<Vec<_>>()
        .join(" ");
    let prefix = if env.is_empty() {
        String::new()
    } else {
        format!("{env} ")
    };
    println!("swift test plan");
    println!("cwd: {}", plan.cwd);
    println!("cmd: {prefix}{command}");
}

#[cfg(test)]
mod tests {
    use super::swift_test_command_vector;

    #[test]
    fn swift_test_command_vector_uses_direct_args() {
        assert_eq!(
            swift_test_command_vector(None),
            vec!["swift".to_owned(), "test".to_owned()]
        );
        assert_eq!(
            swift_test_command_vector(Some("RemoteControlSecurityNoticeTests")),
            vec![
                "swift".to_owned(),
                "test".to_owned(),
                "--filter".to_owned(),
                "RemoteControlSecurityNoticeTests".to_owned()
            ]
        );
    }
}
